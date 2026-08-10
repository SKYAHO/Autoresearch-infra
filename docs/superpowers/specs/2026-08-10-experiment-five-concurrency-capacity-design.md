# 실험 5건 동시 실행 용량 상향 설계

> Issue: #624
> 작성일: 2026-08-10 (2026-08-11 비용 절충안 반영)
> 대상 환경: GCP project `autoresearch-503903`, dev (`asia-northeast3-a`)
> 상태: 구현 승인

## 1. 목적

데모 촬영에서 실험 5건을 동시에 제출하고, executor Pod 5개가 모두 실행되며
Streamlit 워크벤치에 상태·로그·이벤트가 갱신되는 장면을 만든다. 이를 위해
`autoresearch-experiments` namespace의 동시 실행 상한을 2건에서 5건으로,
실험당 자원을 requests `1 CPU/2Gi`, limits `4 CPU/8Gi`로 올린다. request는
스케줄링과 quota 예약값이고, limit은 개별 container의 cgroup 상한이다. 둘을
분리해 5건을 한 노드에 수용하면서도 개별 실험은 필요할 때 4 CPU/8Gi까지 버스트할
수 있게 한다.

변경은 단순한 숫자 교체가 아니다. GKE node pool, Kubernetes
LimitRange·ResourceQuota, 애플리케이션 Job spec, launcher 동시 실행 상한이 서로
다른 배포 경로를 사용한다. 순서를 어기면 launcher가 DB 상태를 `RUNNING`으로 먼저
바꾼 뒤 Job 생성이 quota 403 또는 LimitRange `FailedCreate`로 거부된다. 따라서
각 단계는 이전 단계의 live 검증을 통과해야만 다음 단계로 진행한다.

## 2. 현재 확인된 전제

2026-08-10 기준 다음 사항을 확인했다.

- 애플리케이션 #665 수정은 실제 dev에서 동작한다. executor Job에 `valueFrom`이
  없고 admission 422 없이 생성된다.
- #658의 자원 예산 배선은 `codex-worker`까지 도달한다. 메모리 값
  `2147483648`은 `_container_resources()`의 `2Gi`와 정확히 일치한다.
- executor는 Codex에 전달하는 `AGENTS.md`에 현재 예산인
  `메모리: container당 2.0 GiB`와 `학습 시간: seed 하나당 1,800초`를 렌더한다.
- infra `main`에는 애플리케이션 source `d36aed8ab8b3`의 Agent Orchestration
  digest가 자동 승격돼 있다.
- #672는 2Gi 상한에서 예산 고지의 효과를 관측하는 실험이다. 이 실험이 terminal
  상태가 되고 관련 Pod·Job이 정리되기 전에는 `batch-od` node pool 교체를 시작하지
  않는다.
- 애플리케이션 #669는 원래 실험 Job의 requests를 `2 CPU/4Gi`, limits를
  `4 CPU/8Gi`로 올렸으나, #624 비용 검토에서 requests는 `1 CPU/2Gi`로 조정하기로
  결정했다. 메모리 실측 피크 1.22Gi는 2Gi request 안에 들어가며, limit
  `4 CPU/8Gi`와 #665의 리터럴 예산 전달 계약은 보존한다. 수정된 #669는 이 설계의
  인프라 용량 적용이 완료되기 전에는 배포하지 않는다.

## 3. 선택한 접근

변경을 두 개의 infra PR과 두 번의 Terraform apply 사이에 애플리케이션 canary를
두는 단계적 배포로 수행한다.

1. **용량 PR**: node pool, LimitRange, ResourceQuota와 관련 문서만 변경한다.
   launcher 동시 실행 상한은 2로 유지한다.
2. **인프라 적용**: dev root를 먼저 apply해 node pool 교체를 완료한 뒤 admin
   root를 apply해 LimitRange·ResourceQuota를 올린다.
3. **애플리케이션 canary**: #669가 #665 계약을 보존한 상태로 배포된 뒤 동시 실행
   상한 2에서 새 자원값을 쓰는 실험 2건을 검증한다.
4. **동시성 PR**: canary가 통과한 뒤 launcher 환경 변수만 5로 올리고 운영 문서를
   최종값으로 맞춘다.
5. **최종 smoke**: 실험 5건을 동시에 제출해 Pod와 워크벤치 상태를 검증한다.

이 방식은 GCP/Kubernetes 용량 변경과 GitOps launcher 변경을 서로 다른 승인·배포
단위로 분리한다. 한 PR에 모두 넣으면 `main` 병합 직후 ArgoCD가 launcher를 자동
동기화하는 반면 Terraform apply는 Environment 승인 후 수동 실행되므로 launcher가
먼저 5건을 선점할 수 있다.

### 검토했지만 선택하지 않은 접근

- **`e2-standard-16` + 30GB**: 5건의 `2 CPU/4Gi` request를 여유 있게 수용하지만
  서울 공개가격 기준 약 $0.695/시간으로 dev burst workload에 과하다. 30GB 디스크도
  workspace 최악 상한 40Gi보다 작아 선택하지 않는다.
- **`e2-highmem-8` + 100GB**: 메모리 limit 총합 40Gi까지 한 노드에서 흡수하지만
  약 $0.471/시간이라 `e2-standard-8`보다 34% 비싸다. 5건 smoke에서 메모리 압박이
  실제로 관측될 때의 후속 상향 후보로 남긴다.
- **한 PR 병합 후 ArgoCD 수동 정지**: GitOps 외 임시 상태가 생기고 자동 동기화
  재개 누락 위험이 있어 선택하지 않는다.
- **한 PR에서 커밋만 분리**: 병합 시 모든 파일이 동시에 `main`에 들어가므로 배포
  순서를 보장하지 못한다.
- **launcher를 먼저 5로 변경**: 현재 quota에서 세 번째 Job 생성이 403으로
  거부되고, 이미 `RUNNING`으로 커밋된 실험이 Job 없이 남으므로 금지한다.

## 4. 목표 구성

### 4.1 GKE `batch-od` node pool

| 항목 | 현재 | 목표 |
| --- | --- | --- |
| machine type | `e2-standard-2` | `e2-standard-8` |
| boot disk | `pd-standard` 30GB | `pd-standard` 100GB |
| autoscaling min | `0` | `0` 유지 |
| autoscaling max | `2` | `2` 유지 |
| spot 여부 | on-demand | on-demand 유지 |
| taint | `workload=batch-od:NoSchedule` | 유지 |

스케줄러는 limits가 아니라 requests로 배치한다. 목표 requests 합계는
5 × `1 CPU/2Gi` = `5 CPU/10Gi`다. `e2-standard-8` 한 대가 이를 수용해
스케일아웃 대기를 한 번으로 줄인다. max 2는 장애·향후 헤드룸으로 유지하지만
namespace quota가 실험 5건을 넘는 제출을 막는다.

CPU limit 총합 20은 노드 vCPU 8보다 크다. 다섯 container가 동시에 limit까지
사용하려 하면 CPU 부족으로 Pod가 축출되는 것이 아니라 CFS throttling으로 처리되며
학습 시간이 늘어난다. 반면 메모리 limit 총합 40Gi는 노드 메모리 32GB보다 크므로,
여러 container가 동시에 request를 크게 넘으면 MemoryPressure 축출 가능성이 있다.
이는 시간당 비용을 약 $0.695에서 $0.351로 절반 낮추기 위해 수용한 절충이며, 2건
canary와 5건 smoke에서 throttling·MemoryPressure·training timeout을 명시적으로
관측한다.

executor의 disk-backed workspace `emptyDir.sizeLimit`은 Pod당 8Gi다. 다섯 Pod의
최악 상한 40Gi에 노드 이미지, container image layer, 로그, kubelet eviction
headroom이 더해지므로 30GB boot disk로는 안전하지 않다. `pd-standard` 100GB로
올려 DiskPressure를 막고 용량에 비례하는 IOPS도 확보한다. 디스크 추가 70GB의 공개
가격 증가는 노드가 한 달 내내 존재할 때 $3.64이고 min 0이라 유휴 비용은 없다.

machine type·disk 변경은 node pool rolling update를 유발할 수 있다. 적용 전
`batch-od`를 선택한 실행 중 Pod가 없는지 확인하고, Terraform plan에서 교체 범위가
`google_container_node_pool.batch_od` 하나인지 검토한다. pool 이름, taint, disk
type, 노드 SA, Workload Metadata 설정은 바꾸지 않고 disk size만 100GB로 변경한다.

### 4.2 LimitRange

| 항목 | 현재 | 목표 |
| --- | --- | --- |
| Container `max.cpu` | `1` | `4` |
| Container `max.memory` | `2Gi` | `8Gi` |
| Pod `max.cpu` | `1` | `4` |
| Pod `max.memory` | `2Gi` | `8Gi` |

Container와 Pod 상한은 같은 값으로 유지한다. executor는 일반 initContainer 7개와
app container 1개를 순차 실행하고 native sidecar가 없으므로 Pod 실효 자원은
`max(app container 합계, initContainer 최댓값)`이며 한 container 몫이다.
Pod 상한을 더 크게 두지 않아 sidecar 주입을 조용히 허용하지 않는 기존
`헤드룸 0` 불변식을 보존한다.

LimitRange의 `default`와 `default_request`인 `500m/1Gi`는 변경하지 않는다.
Phase 2 executor는 모든 container의 자원을 명시하므로 기본값 경로를 사용하지 않는다.

### 4.3 ResourceQuota

| 항목 | 현재 | 목표 | 산출 |
| --- | --- | --- | --- |
| `count/jobs.batch` | `2` | `5` | 동시 실험 5건 |
| `pods` | `2` | `5` | Job당 Pod 1개 |
| `requests.cpu` | `2` | `5` | 5 × 1 |
| `requests.memory` | `4Gi` | `10Gi` | 5 × 2Gi |
| `limits.cpu` | `2` | `20` | 5 × 4 |
| `limits.memory` | `4Gi` | `40Gi` | 5 × 8Gi |

여유분을 별도로 더하지 않는다. quota는 대량 제출로 on-demand batch 비용이 늘어나는
경로를 차단하는 hard ceiling으로 유지한다. 완료 Job도 TTL 삭제 전까지
`count/jobs.batch`를 점유한다는 기존 동작은 바꾸지 않는다.

### 4.4 launcher

`deploy/agent-orchestration/launcher-cronjob.yaml`의
`ORCH_MAX_CONCURRENT_EXPERIMENTS`는 인프라 적용과 2건 canary가 모두 통과한 후 별도
PR에서 `"2"`에서 `"5"`로 변경한다. 이미지 digest나 다른 환경 변수는 이 PR에서
변경하지 않는다.

## 5. 파일 및 책임 경계

### 용량 PR

- `terraform/envs/dev/variables.tf`: `batch_od_gke_machine_type` 기본값과 설명
- `terraform/envs/dev/gke.tf`: `batch-od` boot disk 100GB
- `terraform/admin/autoresearch-k8s/experiment_jobs.tf`: quota, LimitRange,
  용량 산출 주석
- `terraform/admin/autoresearch-k8s/tests/experiment_jobs_contract.tftest.hcl`:
  목표 quota와 Container/Pod 상한 회귀 검증
- `terraform/admin/autoresearch-k8s/README.md`: namespace 용량 계약 정합화
- `docs/TERRAFORM_DEV.md`: `batch-od` machine type 정합화
- `docs/INFRASTRUCTURE_SUMMARY.md`: node pool 요약 정합화
- `docs/runbooks/2026-08-01-auto-research-experiment-job.md`: 단계적 배포,
  검증, 롤백 절차 추가. 동시 실행 상한 표는 이 단계에서 2로 유지
- 이 설계 문서와 후속 구현 계획

### 동시성 PR

- `deploy/agent-orchestration/launcher-cronjob.yaml`: 동시 실행 상한 5
- `docs/runbooks/2026-08-01-auto-research-experiment-job.md`: 현재 운영값을 5로
  갱신하고 최종 smoke 절차 기록
- `docs/CHANGE_HISTORY.md`: 배포·검증이 완료된 장기 결정만 요약

애플리케이션 #669의 코드는 `SKYAHO/Autoresearch` 소유이므로 별도 저장소의 기존
PR branch에서 requests만 `1 CPU/2Gi`로 수정한다. infra PR은 live 배포값과 #669가
선언하는 자원 계약을 Terraform test와 canary로 교차 검증한다.

## 6. 배포 절차와 게이트

### Gate 0: 기존 실험과 복구 상태

1. #672가 완주 또는 실패로 terminal 상태가 됐는지 확인한다.
2. `autoresearch-experiments`에 active Job/Pod가 없는지 확인한다.
3. launcher 최신 tick이 `Complete`이고 422가 재발하지 않는지 확인한다.
4. `batch-od`를 선택한 다른 namespace의 Pod가 없는지 확인한다.

하나라도 만족하지 않으면 node pool 교체를 시작하지 않는다.

### Gate 1: 용량 PR 검증과 병합

1. Terraform 계약 테스트, `fmt -check`, dev/admin `validate`, 문서 검증을 실행한다.
2. PR Terraform plan에서 dev root는 node pool machine type·disk size 변경만
   발생하는지 확인한다. admin root는 계약 테스트와 validate로
   ResourceQuota·LimitRange 목표값을 검증한다.
3. secret/state/tfvars 노출, IAM 확대, public endpoint 추가가 없음을 diff에서
   확인한다.
4. Draft PR 셀프 리뷰 후 Ready로 전환하고, CI와 2인 승인을 받아 squash merge한다.

첫 PR은 이슈를 닫지 않고 `Refs #624`로 연결한다.

### Gate 2: 실제 Terraform 적용

1. `apply.yml`을 `scope: dev`로 dispatch하고 Environment 승인을 거쳐 적용한다.
2. `batch-od`가 `e2-standard-8`, `pd-standard` 100GB, min 0/max 2인지 live
   GKE에서 확인한다.
3. dev 적용이 성공한 뒤에만 `apply.yml`을 `scope: admin`으로 dispatch한다.
4. `experiment-jobs-limits`의 Container/Pod max가 `4 CPU/8Gi`인지 확인한다.
5. `experiment-jobs-quota`의 hard 6개 항목이 목표 표와 일치하는지 확인한다.
6. canary로 생성된 node의 ephemeral-storage allocatable이 workspace 최악 상한
   40Gi보다 크고 `DiskPressure=False`인지 확인한다.

dev와 admin을 한 번의 `scope: all`로 적용하지 않는다. node pool 교체가 끝난 뒤
Kubernetes 상한을 올렸다는 live 증거를 남기기 위해 dispatch를 분리한다.

### Gate 3: 애플리케이션 #669와 2건 canary

1. #669가 #665 이후 `main`을 반영했고 모든 executor container에 `valueFrom`이
   없음을 확인한다.
2. #669 이미지가 release되고 infra digest 승격과 ArgoCD sync가 끝났는지 확인한다.
3. launcher 상한은 2인 상태에서 실험 2건을 동시에 제출한다.
4. 두 Pod가 requests `1 CPU/2Gi`, limits `4 CPU/8Gi`로 `Running`에 도달하고
   quota 403, LimitRange `FailedCreate`, 장기 `Pending`이 없는지 확인한다.
5. 두 실험의 로그·이벤트·결과가 워크벤치에 갱신되는지 확인한다.

하나라도 실패하면 launcher 상한을 5로 올리지 않는다.

### Gate 4: 동시성 PR과 최종 smoke

1. 최신 `main`에서 이슈 #624에 연결된 두 번째 브랜치를 만든다.
2. launcher 상한과 최종 운영 문서만 변경해 별도 PR로 병합한다.
3. ArgoCD Application이 `Synced/Healthy`이고 PostSync 검증이 성공했는지 확인한다.
4. live CronJob의 `ORCH_MAX_CONCURRENT_EXPERIMENTS`가 `"5"`인지 확인한다.
5. 실험 5건을 동시에 제출해 executor Pod 5개가 모두 `Running`에 도달하는지
   확인한다.
6. quota 403, LimitRange `FailedCreate`, 장기 `Pending`이 없고 워크벤치에 5건의
   상태·로그·이벤트가 갱신되는지 확인한다.
7. 결과를 #624에 기록한 뒤 이슈를 닫는다.

최종 PR도 `Refs #624`로 연결하고 post-merge smoke 성공 전에는 이슈를 자동으로 닫지
않는다.

## 7. 검증 전략

### 정적·로컬 검증

- `terraform test`로 quota 6개 항목과 Container/Pod max를 직접 검증한다.
- dev와 admin root의 `fmt -check`·`validate`를 실행한다.
- `git diff --check`를 실행한다.
- 관련 문서의 옛 값(`e2-standard-2`, 1 CPU/2Gi, quota 2건)이 현재 운영값으로
  잘못 남지 않았는지 검색한다. 완료된 과거 plan/spec의 역사적 값은 바꾸지 않는다.

### PR·live 검증

- PR plan에서 node pool 외 예상치 못한 GCP 리소스 교체·삭제가 없는지 확인한다.
- live quota는 `E2_CPUS`가 아니라 E2/N1 공용 `CPUS`를 확인한다. 2026-08-11
  실측은 13/100이고 batch-od 한 대가 추가되면 21/100, max 두 대면 29/100이다.
- live GKE와 Kubernetes object를 직접 조회해 state와 실제 리소스가 일치하는지
  확인한다.
- 2건 canary와 5건 smoke를 분리해 자원 상향 문제와 동시성 문제를 구분한다.

## 8. 실패 처리와 롤백

- **dev apply 실패**: admin apply를 시작하지 않는다. 기존 launcher 상한 2를 유지하고
  node pool plan/apply 원인을 조사한다.
- **admin apply 실패**: launcher 상한 2를 유지한다. node pool이 커진 상태는 평시
  min 0이라 유휴 비용을 만들지 않으므로, 실패 원인을 고친 뒤 admin apply를 재시도한다.
- **#669 canary 실패**: 동시성 PR을 시작하지 않는다. 애플리케이션 digest를 직전
  정상 버전으로 되돌리고, 인프라 상한은 높게 유지해도 보안·비용 경계가 넓어지지 않는지
  별도로 판단한다. quota 5건 때문에 제출 경계가 넓어졌더라도 launcher가 2로 제한한다.
- **5건 smoke 실패**: launcher를 먼저 `"2"`로 되돌리는 GitOps PR을 병합·동기화해
  새 선점을 막는다. 실행 중 Job이 끝나고 quota 사용량이 내려간 뒤에만 필요 시
  ResourceQuota·LimitRange와 node pool을 이전 값으로 되돌린다.

namespace, Job KSA, 결과 버킷을 롤백 수단으로 삭제하지 않는다. Terraform state를
직접 조작하지 않는다.

## 9. 보안·비용·운영 영향

- IAM, Secret, NetworkPolicy, public IP/LB/Ingress는 변경하지 않는다.
- node pool은 on-demand `e2-standard-8`과 `pd-standard` 100GB지만 min 0이므로
  유휴 VM·boot disk 비용은 0이다. 서울 공개가격 기준 노드 한 대는 약
  $0.351/시간, 30분은 약 $0.175다. max 2는 유지된다.
  계산은 2026-08-10 유효 Cloud Billing 공개 SKU인 E2 core
  `9304-94C4-2117`, E2 RAM `D715-4E57-BAFB`, zonal standard PD
  `0306-B164-A7B7`를 사용한다.
- namespace quota가 동시 5건과 총 requests/limits를 정확히 막아 대량 제출의 비용
  상한을 유지한다.
- CPU는 limits 총합을 노드보다 크게 허용해 CFS throttling이 가능하고, memory도
  limits 총합 40Gi가 노드 32GB보다 커 MemoryPressure 축출 가능성이 있다. 이는
  숨기지 않고 canary/smoke gate의 실패 조건으로 다룬다.
- machine type 교체는 실행 중 Pod를 중단할 수 있으므로 Gate 0의 무부하 확인이 필수다.
- 스케일아웃 시점에는 실험 제출부터 `Running`까지 1~2분이 추가될 수 있다. 촬영 전
  승인된 canary로 노드를 예열할 수 있으나, 불필요하게 유지하기 위한 min 변경은 하지
  않는다.

## 10. 완료 조건

- `batch-od`가 `e2-standard-8`, `pd-standard` 100GB, min 0/max 2로 배포돼 있다.
- LimitRange의 Container/Pod max가 `4 CPU/8Gi`다.
- ResourceQuota hard 6개 항목이 Jobs/Pods 5, requests `5 CPU/10Gi`, limits
  `20 CPU/40Gi`와 일치한다.
- #669 자원값으로 동시 2건 canary가 통과했다.
- launcher CronJob의 동시 실행 상한이 5다.
- 실험 5건이 모두 `Running`에 도달하고 quota/admission/scheduling 오류가 없다.
- Streamlit 워크벤치에 5건의 상태·로그·이벤트가 갱신된다.
- Terraform README, dev 문서, 인프라 요약, 운영 runbook, CHANGE_HISTORY가 최종
  live 상태와 일치한다.
