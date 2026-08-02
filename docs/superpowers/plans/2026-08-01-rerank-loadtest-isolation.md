# 리랭킹 GKE 부하테스트 격리 구현계획

## Goal

Autoresearch 애플리케이션 저장소의 이슈 #455에서 사용하는 `rerank-loadtest.yml`을
dev GKE에서 실행할 수 있도록 전용 Kubernetes 경계와 GitHub Actions 인증 경계를
구축한다. 부하테스트가 `autoresearch` 운영 namespace, Redis/Cloud SQL, 외부 공개
경로에 영향을 주지 않으면서 실제 `autoresearch-serving` Service의 TCP 8000만
호출하도록 한다.

이 변경은 애플리케이션 부하테스트 코드의 구현이 아니라 Infra 계약을 제공한다.
`terraform apply`, namespace 생성, IAM 변경, Job 실행, 파드 종료는 이 계획과 PR의
검토·승인 뒤 별도로 수행한다.

## Architecture and ownership

- `terraform/admin/autoresearch-k8s`: GKE namespace, KSA, Pod Security label,
  Role/RoleBinding, NetworkPolicy를 관리한다. 이 root는 GKE API에 직접 접근하는
  별도 state를 유지한다.
- `terraform/envs/dev`: GitHub Actions용 GSA, WIF `roles/iam.workloadIdentityUser`,
  필요한 최소 GCP project IAM(`roles/container.clusterViewer`)을 관리한다.
- `deploy/monitoring/dashboards`: Prometheus/Grafana 대시보드 JSON을 관리한다.
  `grafana-dashboards.yaml`의 sidecar가 해당 JSON을 ConfigMap으로 자동 로드한다.
- `docs/TEAM_OPERATIONS_RUNBOOK.md`: 실행 전제, 비용 상한, 권한, 검증, 롤백을
  운영자가 재현할 수 있는 명령과 함께 기록한다.
- 애플리케이션 저장소의 workflow가 사용하는 계약은 정확히 다음과 같다.
  - namespace: `loadtest`
  - runner KSA: `rerank-loadtest`
  - snapshot-reader: GitHub Actions WIF GSA(파드 KSA가 아님)
  - serving Service: `autoresearch/autoresearch-serving:8000`
  - Prometheus Service proxy: `monitoring/kube-prometheus-stack-prometheus:9090`

## Global constraints

- 모든 issue, commit, PR, 운영 문서는 저장소 규칙에 따라 한국어 존댓말로 작성한다.
- `loadtest` namespace의 기본 ServiceAccount는 사용하지 않는다. Job은
  `rerank-loadtest` KSA를 명시적으로 선택하고 `automountServiceAccountToken: false`
  로 실행한다. Prometheus snapshot은 별도 GitHub Actions job이 GSA로 GKE API를
  호출하므로 snapshot-reader KSA를 만들지 않는다.
- runner egress는 DNS(UDP/TCP 53)와 serving Service(ClusterIP 및 실제 Pod로
  DNAT되는 경로의 TCP 8000)만 허용한다. `0.0.0.0/0`, GKE metadata,
  Prometheus, Redis, Cloud SQL, public ingress, 다른 namespace 통신은 허용하지
  않는다. NetworkPolicy가 service VIP 이전/이후 어느 dataplane에서 평가되는지
  live cluster에서 확인할 때까지 apply하지 않는다.
- runner RBAC는 `loadtest` namespace의 ConfigMap(Job 결과/불변 설정), Job/Pod와
  로그 조회·생성에 한정한다. `delete`, `pods/exec`, `pods/portforward`, Secret,
  Deployment, Service, Prometheus API 접근 권한은 부여하지 않는다.
- snapshot-reader RBAC는 monitoring namespace의
  `services/proxy`에 대해 `get`만 허용하고 resource name을
  `http:kube-prometheus-stack-prometheus:9090`으로 고정한다. 이는
  `kubectl get --raw`가 Service proxy 요청에 사용하는 `http:<service>:<port>`
  형식이다. 이 Service와 포트 9090이 live cluster에 실제로 존재하는지
  apply 전 확인한다.
- WIF는 `SKYAHO/Autoresearch/.github/workflows/rerank-loadtest.yml@refs/heads/main`
  workflow ref만 허용한다. 다른 repository, branch, workflow의 토큰은 두 GSA를
  가장할 수 없어야 한다. GitHub Environment 승인 게이트는 앱 저장소 workflow의
  별도 정책이며 이 Infra 변경이 존재하지 않는 `environment` claim을 가장하지
  않는다. 두 GSA에는 `roles/container.clusterViewer` 이외의 GCP data-plane 권한을
  추가하지 않는다.
- Job 실행 상한은 `activeDeadlineSeconds = 600`, 완료 후 `ttlSecondsAfterFinished = 86400`이다.
  결과 ConfigMap은 실행 Job UID를 ownerReference로 가져 하루 후 함께 회수한다.
- namespace에는 `count/configmaps=20`, `count/jobs.batch=16`, `pods=16`, CPU·메모리
  ResourceQuota와 Container LimitRange를 둔다. workflow마다 공유 script 1개와
  VU 설정 4개를 만들므로 네 workflow 매트릭스의 최대 17개를 보존하면서 여유분을
  둔다. 기본 container는 `250m/256Mi` request,
  `500m/512Mi` limit을 받고 최대 `1 CPU/1Gi`를 넘을 수 없다. 이 quota는
  candidate 24/200 × baseline/optimized 네 workflow의 4 VU Job을 보존 기간 안에
  기록할 수 있으면서
  임의 Job 생성으로 비용을 무제한 늘리는 것을 막는다.
- `activeDeadlineSeconds=600`과 `ttlSecondsAfterFinished=86400`은 앱 workflow
  manifest의 계약이다. ResourceQuota/LimitRange는 namespace에서 수·자원을
  강제하지만 Job deadline/TTL 자체를 admission 단계에서 검증하지는 않는다. 따라서
  Job 생성 GSA를 정확한 workflow ref에만 WIF로 묶고, hard deadline admission이
  필요하면 별도 ValidatingAdmissionPolicy 이슈로 다룬다.
- Terraform state, `terraform.tfvars`, secret payload, 실제 토큰/피처 ID는 커밋하지
  않는다. 계획 검증은 `plan`/`validate`까지만 수행하고 apply는 하지 않는다.

## Implementation tasks

### Task 1: 격리 namespace와 KSA

1. `terraform/admin/autoresearch-k8s/rerank_loadtest.tf`에 `loadtest` namespace를
   추가하고
   `pod-security.kubernetes.io/enforce=baseline` 및 해당 warn/audit label을
   기존 Feast apply namespace와 같은 기준으로 적용한다.
2. `rerank-loadtest` KSA를 생성한다. 이 KSA에는 GCP annotation을 붙이지 않는다.
   Job은 Kubernetes API나 GCP API를 호출하지 않고, serving Service만 호출한다.
3. `variables.tf`에 namespace/KSA를 명시적인 변수로 추가하고,
   Kubernetes DNS 이름 규칙과 GSA email 형식을 검증한다. 기본값은 위 계약과
   일치시키되 실제 email은 dev root output을 주입한다.
4. 기존 `autoresearch` namespace 정책을 수정하지 않고 별도 리소스 이름을 사용해
   state ownership 충돌을 막는다.

### Task 2: NetworkPolicy와 최소 RBAC

1. `loadtest` namespace 전체 ingress를 deny하고, runner pod에는 DNS와 실제
   `autoresearch-serving` Service의 TCP 8000만 허용하는 egress 정책을 추가한다.
   pre-DNAT dataplane을 위해 `autoresearch-serving`와 `kube-dns` Service를
   read-only data source로 조회해 각각 ClusterIP `/32`를 사용하고, post-DNAT
   dataplane을 위해 `kube-dns` pod label과 `autoresearch` namespace 및 serving
   pod label selector를 함께 사용한다. Service 조회가 불가능하거나 ClusterIP가
   없는 경우는 apply 전 차단한다. 전체 `cluster_services_cidr:8000` aperture와
   `kube-system` 전체 pod의 DNS 포트 허용은 사용하지 않는다.
2. snapshot-reader GitHub Actions GSA가 Prometheus HTTP API를 호출할 수 있도록
   monitoring namespace의 Service `services/proxy` `get`만 허용하는 Role/RoleBinding을
   추가한다. service resource name을 고정하고 wildcard `services/*`나 `pods/*`는
   사용하지 않는다. 이 RoleBinding의 subject는 GSA email이며 KSA subject가 아니다.
3. runner용 Role은 ConfigMap `get/create/update/patch`, Job `get/list/watch/create`,
   Pod `get/list/watch`, Pod log `get`, 진단용 Event `get/list`만 포함한다. 결과
   writer와 snapshot reader의 RoleBinding을 서로 섞지 않는다.
4. `ResourceQuota`와 `LimitRange`로 ConfigMap/Job/pod 수와 container
   CPU·메모리 상한을 namespace에서 강제한다.
5. `kubectl auth can-i` 음성 검증 명령을 README/runbook에 추가한다.

### Task 3: GitHub Actions WIF와 GCP IAM

1. `terraform/envs/dev/github_actions.tf`와 관련 변수/출력에 runner용 GSA와
   snapshot-reader용 GSA를 추가한다. GSA account id는 기존 30자 제한과
   `autoresearch-dev` prefix를 만족하도록 짧게 정한다.
2. 두 GSA의 Workload Identity User member를 정확한
   `attribute.workflow_ref` principalSet으로 제한한다. 현재 bootstrap provider의
   `workflow_ref` mapping과 허용 repository condition을 교차 확인한다.
3. 두 GSA에 `roles/container.clusterViewer`만 프로젝트 IAM으로 부여한다.
   Kubernetes API write/read 범위는 Task 2의 namespace RoleBinding으로 제어하며,
   storage, Redis, Cloud SQL, Secret Manager, Artifact Registry 역할은 부여하지
   않는다.
4. Terraform output에 workflow가 사용할 두 GSA email과 runner KSA 계약을 노출하되
   secret은 출력하지 않는다.

### Task 4: 단계별 metric 대시보드

1. `deploy/monitoring/dashboards/rerank-loadtest.json`을 추가한다. 기존
   `autoresearch-serving.json`의 datasource/JSON schema 패턴을 따른다.
2. 다음 패널을 PromQL로 제공한다.
   - `rerank_phase_duration_seconds_bucket` 기반 phase별 p50/p95
   - `rerank_outcomes_total` 기반 성공/실패율과 요청률
   - `rerank_in_flight`의 최대값
   - `container_cpu_usage_seconds_total`, RSS, CFS throttling으로 loadtest
     Job/serving pod의 자원 포화 여부
3. metric이 아직 수집되지 않은 시간에는 빈 시계열을 정상으로 표시하고, metric
   이름/label을 앱 저장소 계측 코드와 대조한다. 대시보드 JSON은 `python` 표준
   라이브러리로 parse한다.

### Task 5: 운영 문서와 비용·보안 경계

1. `docs/TEAM_OPERATIONS_RUNBOOK.md`에 #482 절을 추가한다.
2. 실행 순서를 `Terraform plan 확인 → serving/kube-dns Service 존재 확인 →
   workflow ref/branch 정책 확인 → workflow 실행 → ConfigMap/Job/Prometheus
   snapshot 확인 → 결과 보존/회수`로 설명한다.
3. 예상 비용을 “신뢰된 workflow가 만드는 Job은 최대 600초, 실행 이력은
   16개/namespace까지(candidate 24/200 × baseline/optimized 전체 비교), container는
   최대 1 CPU/1Gi, 완료 후 24시간 내 TTL 회수,
   별도 node pool/LB/Ingress를 만들지 않음”으로 계산 가능한 경계로 표현한다.
   deadline/TTL은 현재 admission 정책이 아닌 workflow 계약임을 명시하고, 실제
   비용/처리량은 live 실행 후 측정값으로만 기록한다.
4. 실패 시 workflow 취소, Job 확인, RoleBinding/WIF 제거 plan, dashboard rollback
   절차를 문서화한다. 파드 강제 종료나 `terraform destroy`를 기본 복구책으로
   제시하지 않는다.

### Task 6: 검증과 인수 기준

1. 변경된 Terraform root 각각에 대해 다음을 실행한다.
   - `terraform fmt -check -recursive`
   - `terraform init -backend=false`
   - `terraform validate`
   Terraform CLI가 없는 환경이면 설치를 임의로 진행하지 않고 해당 검증을
   blocked로 기록하며, `git diff --check`와 정적 검증 결과를 분리해 보고한다.
2. 대시보드 JSON parse, YAML/Markdown 구조 확인, `git diff --check`를 실행한다.
3. 가능하면 `kubectl auth can-i`와 `kubectl get service`의 live read-only 검증을
   수행한다. GKE API가 403이면 “검증 미실행”으로 명시하고 추측으로 통과시키지
   않는다.
4. 인수 기준은 다음과 같다.
   - `loadtest` namespace/KSA/NetworkPolicy/RBAC가 기존 namespace 리소스와
     이름·state 충돌 없이 계획에 나타난다.
   - runner는 serving TCP 8000 외 egress와 Pod exec/delete를 거부한다.
   - snapshot-reader는 Prometheus service proxy `get`만 허용한다.
   - workflow ref 외 WIF 가장이 불가능하다.
   - 대시보드가 단계별 metric과 자원 포화 metric을 모두 포함한다.
   - runbook에 비용 상한, 회수, rollback, live verification gate가 있다.

## Verification evidence to record

- `git diff --check` 결과
- 두 Terraform root의 fmt/init/validate 결과 또는 CLI 부재 사유
- 대시보드 JSON parse 결과
- `terraform show`/plan 출력에 secret·tfvars 값이 포함되지 않았다는 확인
- live GKE read-only 명령의 성공/403 여부

## Review boundary

이 계획은 Infra 리소스와 운영 문서만 다룬다. 실제 부하테스트 실행, GKE apply,
모니터링 snapshot의 수치 해석, 애플리케이션 코드 변경은 각각 이슈 #455의 앱 PR과
별도 승인된 운영 실행에서 수행한다.
