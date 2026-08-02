# Auto Research 실험별 Kubernetes Job 실행 경계 설계

## 상태

- 관련 이슈: [#484](https://github.com/SKYAHO/Autoresearch-infra/issues/484)
- 상태: 보수 검토 완료, Terraform 실행 경계 구현 중
- 대상 환경: GCP dev / GKE `autoresearch-dev-gke`
- 작성 언어: 한국어

## 1. 목적

사용자가 제출한 Auto Research 실험 요청을 실험별 Kubernetes Job으로 실행할 수
있는 인프라 경계를 만든다. 한 실험의 프로세스·파일시스템·실행 시간·권한·결과를
다른 실험과 분리하고, 실행 이미지와 입력 버전을 고정해 재현 가능한 실행을
지원한다.

이번 변경은 실험을 실제로 수행하는 애플리케이션 코드가 아니라, 앱 저장소의
실험 요청 API와 에이전트 실행기가 사용할 Kubernetes·GCP 계약을 제공한다.

## 2. 범위와 저장소 책임

### 이번 저장소에서 구현

- `autoresearch-experiments` 전용 Kubernetes namespace
- 실험 Job용 KSA 및 Workload Identity GSA 연결
- Agent Orchestration API가 검증 조건을 통과한 경우에만 Job을 제한적으로 생성·조회할
  수 있는 namespace 범위 RBAC
- 실험 Job의 Pod Security `restricted`, ResourceQuota, LimitRange, NetworkPolicy
- 결과 저장용 GCS 버킷 및 실험 Job GSA의 최소 객체 권한
- immutable image, 실험 ID, 실행 제한, 결과 위치를 포함한 manifest 계약
- 비용·보안·롤백·운영 검증 절차

### 다른 저장소에서 구현

- `SKYAHO/Autoresearch`: 실험 요청 API, Job 생성 코드, 상태 watcher, 에이전트 실행기
- `SKYAHO/Autoresearch-airflow`: 기존 학습·배치 파이프라인과의 연결이 필요한 경우
  별도 이슈로 구현

### 범위에서 제외

- 외부 Ingress, LoadBalancer, 공개 API
- 사용자별 인증·권한 모델
- CronJob 기반 반복 스케줄링
- 실험 Job이 GitHub에 직접 push하거나 PR을 자동 merge하는 기능
- `terraform apply`, GCP 리소스 생성·삭제의 실제 실행
- 기존 `autoresearch` namespace의 앱·Agent Runner 권한 확대

## 3. 선택한 구조

실험 워크로드를 기존 앱 namespace와 분리한다.

```text
autoresearch
├── Agent Orchestration API
└── Codex Runner
    │
    │ namespace-scoped Job RBAC
    ▼
autoresearch-experiments
└── experiment Job (실험 1건당 1개)
    └── Pod 1개
        └── 주 에이전트 컨테이너 1개
```

API는 `autoresearch-experiments` namespace에서 Job의 생성·조회·상태 확인만
수행한다. Job Pod는 API와 다른 KSA를 사용하며, 결과 저장에 필요한 GCS 객체 생성
권한만 갖는다. API에는 실험 결과 버킷 쓰기 권한을 부여하지 않는다. 상태 API는
인증·감사 가능한 응답으로 결과를 조회하기 위한 bucket-scoped 읽기 권한만 갖고,
실행 Job은 새 객체 생성 권한만 갖는다.

Kubernetes RBAC는 Pod 사양의 image·env·volume 내용을 검증하지 않으므로, namespace
분리만으로 충분한 보안 경계로 간주하지 않는다. 다음 방어선을 함께 적용한다.

- namespace Pod Security `restricted` 적용. 실험 이미지가 non-root·seccomp·capability
  제한을 만족하지 못하면 실행하지 않고 이미지를 수정한다.
- ResourceQuota와 LimitRange
- Job 생성 주체의 namespace-scoped 권한
- Job Pod의 별도 KSA. Kubernetes API 서비스 계정 토큰 자동 마운트는 끄며, GKE
  metadata server는 호출 Pod identity, KSA annotation, GSA의 Workload Identity
  member binding을 사용해 GCP access token을 발급한다.
- Secret 접근 권한 미부여
- default-deny NetworkPolicy 후 필요한 목적지만 허용
- Job 템플릿은 앱 저장소의 고정 계약으로 관리하며 임의 사용자 manifest를 그대로
  Kubernetes API에 전달하지 않음
- API의 Job 생성 권한은 고정된 템플릿 검증과 허용된 이미지 digest 검증이 앱
  저장소에 구현되고, 클러스터 admission에서 `restricted`·리소스·위험 필드 검증을
  통과하는 경우에만 활성화한다. 이 조건이 충족되지 않으면 API KSA에는 `create`를
  부여하지 않고, 승인된 Controller 경로를 별도 이슈로 구현한다.

## 4. 실행 계약

API가 생성하는 Job은 아래 계약을 만족해야 한다.

### 식별자

- Job 이름: `experiment-<실험ID>` 형식의 검증된 DNS-1123 이름
- `autoresearch.io/experiment-id`: 외부 입력 원문이 아닌 검증·정규화된 ID
- `autoresearch.io/source-revision`: 실험 코드 Git commit 또는 archive revision
- `autoresearch.io/image-digest`: 실제 실행 이미지 digest
- `autoresearch.io/result-uri`: 결과 저장 위치 식별자

### 실행 제한

- `backoffLimit: 0`: 같은 Job 안에서 자동 재시도하지 않으며, 재실행은 API가 새
  시도 ID를 가진 별도 Job으로 생성
- `activeDeadlineSeconds`: 무제한 실행 금지
- `ttlSecondsAfterFinished`: 종료 Job 자동 정리 기간 설정
- CPU·메모리 requests/limits 필수. 초기 단일 컨테이너 상한은 1 vCPU/2 GiB
- `batch-od` nodeSelector 및 `workload=batch-od:NoSchedule` toleration 필수. 일반
  앱 pool과 컴퓨트 경계를 분리하며, admission 검증이 이를 강제한다. 다만 이 pool은
  #297 Action Log shard KPO와 공유하므로 Job 생성 권한 활성화 전 전용 pool 또는
  capacity·우선순위 경합 계획을 별도 승인한다.
- namespace ResourceQuota로 동시 실행 수·총 CPU·총 메모리 상한 설정

정확한 숫자는 실제 dev GKE quota와 예상 실험 소요량을 확인한 뒤 plan 문서에서
확정한다. 임의로 큰 기본값을 넣지 않는다.

### 입력과 결과

- 요청 본문 전체를 환경변수나 로그에 넣지 않는다.
- 큰 입력은 GCS URI 또는 API가 관리하는 DB 식별자로 전달한다.
- 결과는 실험 ID와 시도 ID가 포함된 GCS prefix에 기록한다. Job GSA의
  `roles/storage.objectCreator`에는 기존 객체를 덮어쓰는 데 필요한 삭제 권한이 없고,
  API는 create-if-absent precondition으로 동일 prefix의 논리적 중복도 거부한다.
- Job은 성공·실패를 Kubernetes Job 상태로 남기고, 애플리케이션 상태 API는
  `Job`/`Pod` 상태와 결과 URI 및 API DB의 요약 metric을 결합해 표시한다. API는
  결과 버킷을 읽을 수 있지만, 사용자 인증·prefix 조건·감사 로그를 거친 응답만
  제공하며 사용자에게 버킷 IAM이나 공개 URL을 부여하지 않는다.
- 결과 파일에는 metric, 평가 기준, 데이터 버전, 실행 이미지 digest, source
  revision을 포함한다.

## 5. 권한 설계

### API KSA

`autoresearch` namespace의 Agent Orchestration API KSA는 기본적으로 읽기 전용으로
두고, 고정 템플릿·허용 digest·admission 검증이 모두 적용된 뒤에만 다음 리소스에
대해 `autoresearch-experiments` namespace 범위로 접근한다.

- `jobs`: `get`, `list`, `watch`, `create` (`create`는 검증 조건 충족 후에만)
- `pods`: `get`, `list`, `watch`
- `pods/log`: `get`
- `events`: `get`, `list`, `watch` (해당 Job/Pod involvedObject만 상태 원인으로 사용)

다음 권한은 부여하지 않는다.

- `secrets`
- `pods/exec`
- `pods/attach`
- `deployments`, `daemonsets`, `statefulsets`
- `roles`, `rolebindings`, `serviceaccounts`
- ClusterRole·ClusterRoleBinding 생성
- 다른 namespace 접근

MVP에서는 API에 Job 삭제 권한을 부여하지 않는다. `ttlSecondsAfterFinished` 누락이나
TTL controller 장애로 quota가 회수되지 않으면 API는 새 제출을 중지하고 운영자에게
escalate한다. 운영자는 결과·감사 메타데이터를 확인한 뒤 break-glass cluster 관리자
권한으로 회수한다. 이 권한은 API KSA나 실험 KSA에 부여하지 않는다.
`enable_experiment_job_creation=false`는 새 Job 제출만
차단하며 이미 실행 중인 Job은 중단하지 않는다. 취소·재시도는 별도 설계에서 권한과
상태 전이를 함께 검토한다. API가 사용자 입력을 그대로 Job 명세로 전달하지 않도록
앱 저장소 구현에서 허용 필드를 고정한다.

### 실험 Job KSA/GSA

- 별도 KSA를 사용한다.
- GSA는 결과 버킷에 필요한 객체 생성 권한만 갖는다.
- Secret Manager accessor, Cloud SQL, Redis, Kubernetes API 권한은 기본적으로
  부여하지 않는다.
- GCS 버킷은 실험 결과 전용으로 분리한다. 기존 공유 버킷 재사용은 이번 구현에서
  허용하지 않는다.

## 6. 네트워크 경계

실험 namespace에는 namespace-wide 기본 격리를 적용한다.

- Ingress: 기본 차단
- Egress: 기본 차단 후 DNS·GKE metadata·Private Google Access의 Google API HTTPS만
  허용
- MLflow·BigQuery·Feast·Redis 접근은 실제 MVP 실행 계약에 포함될 때만 각각
  목적지·포트·GSA IAM을 함께 추가
- 기존 `autoresearch` namespace의 NetworkPolicy를 넓혀 우회하지 않음
- `0.0.0.0/0:443` 외부 인터넷 egress는 허용하지 않는다. OpenAI·GitHub·외부 데이터
  API 등 외부 목적지가 필요하면 별도 보안 검토와 명시적인 목적지 allowlist를 먼저
  추가한다.
- NetworkPolicy CIDR은 Terraform 변수와 manifest가 중복 관리되는 경우 reviewed
  값 대조 절차를 문서화한다. Private Google Access VIP는 현재 dev 정책과 같은
  `199.36.153.8/30` 범위를 기준으로 검토한다.

실험 Job이 private Redis나 Cloud SQL에 접근해야 한다는 요구는 이번 기본 경계에
자동 포함하지 않는다. 해당 접근이 필요하면 별도 설계와 최소 권한 검토가 필요하다.

## 7. 실패·재실행·정리

- 이미지 pull 실패, Pending, OOMKilled, deadline 초과, 애플리케이션 exit code를
  서로 다른 실패 원인으로 관측한다.
- Job 실패를 무조건 자동 재시도하지 않는다. 재시도 시 비용과 동일 실험 중복
  결과를 고려하고 `backoffLimit`으로 상한을 둔다.
- 동일 실험 ID의 중복 제출은 API 계층에서 멱등성을 보장한다.
- 종료 Job은 TTL controller가 삭제할 때까지 `count/jobs.batch` quota를 계속 사용한다.
  API는 이 기간의 quota 초과를 대기열/재시도 가능 상태로 기록하고, TTL controller가
  Job 객체를 삭제한 뒤에만 새 Job을 제출한다. 결과 객체는 live·archived generation
  모두 원래 생성 시점 기준 30일 후 삭제한다.
- 결과 저장 후 Job을 정리해도 메타데이터와 결과 URI는 API DB에 남긴다. 결과
  live generation은 90일, archived generation은 noncurrent 시점부터 30일 보존한다.
- 롤백은 새 Job 생성을 중지하고, 이전 manifest/image digest로 API·실험 실행
  계약을 되돌리는 방식으로 수행한다. 기존 namespace·GSA·버킷을 삭제하는
  방식은 사용하지 않는다.

## 8. 검증 기준

### 정적 검증

- Terraform fmt 및 validate 통과
- Kubernetes YAML 구문·중복 키 검증 통과
- `git diff --check` 통과
- Secret·state·tfvars 실값·서비스 계정 키 미포함
- IAM diff에서 프로젝트 전체 권한과 기존 앱 권한 확대가 없음

### 실행 전 검증

- API KSA가 실험 namespace 밖의 Job을 생성할 수 없는지 확인
- API KSA가 Secret·Pod exec·ClusterRole을 사용할 수 없는지 확인
- Job KSA가 Kubernetes API에 접근하지 못하는지 확인
- Pod Security `restricted`가 `hostNetwork`, `hostPID`, `hostPath`, privileged,
  root 실행, capability 추가 등 위험한 Pod를 거부하는지 server-side dry-run으로
  확인
- ResourceQuota와 LimitRange가 무제한 Job을 거부하거나 제한하는지 확인
- NetworkPolicy가 허용된 DNS/Google API 외 통신을 차단하는지 확인

### 운영 검증

- 고정 digest의 테스트 이미지로 Job 1건을 생성하고 완료 상태를 확인
- 성공 결과가 실험 ID prefix에 저장되는지 확인
- 의도적인 실패 Job에서 실패 상태·로그·결과 미생성이 구분되는지 확인
- Job 종료 후 TTL·메타데이터·결과 URI가 정책대로 남는지 확인

## 9. 비용과 보안 영향

- 실험 Job이 동시에 많이 실행되면 GKE 노드와 GCS 비용이 증가하므로 namespace
  quota와 API 동시 실행 제한을 함께 둔다.
- Spot/preemptible 노드 사용은 실험 재현성과 중단 재시작 정책을 확인한 뒤 별도
  결정한다.
- API에 Kubernetes Job 생성 권한을 부여하는 것은 새로운 권한 확대이므로 namespace
  한정 Role과 허용 리소스 검증을 함께 리뷰한다.
- 공개 endpoint와 사용자 입력 기반 Secret 주입을 만들지 않는다.
- 로그에는 토큰, Secret 값, 원본 요청 본문, 개인 정보가 들어가지 않도록 한다.

Kubernetes의 `restricted` 프로파일은 보안 중심·저신뢰 워크로드를 대상으로 하며
non-root, privilege escalation 차단, hostPath 차단 등을 요구한다. GKE Workload
Identity는 GKE metadata server가 호출 Pod identity, KSA annotation, Workload Identity
member binding을 사용해 단기 Google Cloud 토큰을 발급한다. 따라서 결과 저장 Job은
Kubernetes API 토큰 자동 마운트를 끄고 Kubernetes RBAC 권한도 부여하지 않는다.

## 10. 후속 작업

- 앱 저장소에 고정 Job 템플릿 생성기와 상태 watcher 구현
- 결과 스키마와 metric 계약을 앱·Airflow 담당자와 합의
- 실험 feature 변경을 dev Feature Store에서만 수행하도록 앱 계약 강화
- 장시간 실험·대규모 병렬 실행이 필요할 때 Controller 또는 큐 기반 구조 재검토
- UI·인증·실험 취소·재시도 정책을 별도 이슈로 분리. 특히 취소는 API의 광범위한
  `delete` 권한으로 처리하지 않고 Job 소유권·감사 로그·최소권한을 검증하는 전용
  운영 경로를 설계한 뒤에만 제공

## 11. 검토 근거

- Kubernetes Pod Security Standards: https://kubernetes.io/docs/concepts/security/pod-security-standards/
- GKE Workload Identity Federation: https://cloud.google.com/kubernetes-engine/docs/concepts/workload-identity
