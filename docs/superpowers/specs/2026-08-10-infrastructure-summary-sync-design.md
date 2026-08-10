# 인프라 요약 문서 정합화 설계

> 관련 이슈: #615
> 기준 브랜치: `main` (`e5fb4dd1a4e87908475530184062ff93f8fd8fc6`)

## 목적

`docs/INFRASTRUCTURE_SUMMARY.md`를 현재 저장소 코드와 다시 대조하여 운영자가 실제
리소스 소유권, 배포 경로, 실행 상한과 보안 경계를 잘못 해석하지 않도록 합니다.
문서 구조는 유지하되 코드로 확인 가능한 사실과 과거 live 검증 결과를 명확히
분리합니다.

## 정본과 판정 원칙

코드 기반 사실은 다음 순서로 판정합니다.

1. `terraform/envs/dev`, `terraform/admin`, `terraform/bootstrap`의 실제 resource와 변수
2. `deploy/`의 Kubernetes·Helm 매니페스트와 `terraform/admin/argocd-k8s`의 Application
3. `.github/workflows`의 실제 실행 경로
4. 현재 코드와 함께 갱신된 README·runbook·`docs/CHANGE_HISTORY.md`

`apply 완료`, live 리소스 상태, quota 실측, 비용처럼 저장소만으로 확정할 수 없는
정보는 코드 상태로 덮어쓰지 않습니다. 기존 live 검증 날짜를 유지하거나, 현재
코드와 별도인 시점 정보임을 표시합니다.

## 수정 범위

단일 운영 요약 문서인 `docs/INFRASTRUCTURE_SUMMARY.md`를 다음 기준으로 갱신합니다.

- Agent Orchestration launcher CronJob의 저장소 소유권과 ArgoCD 배포 경로를 바로잡습니다.
- Phase 2/Stage 1 executor 배선, GCS 결과·학습 snapshot, MLflow tracking 경로를 반영합니다.
- 실험 Job의 `activeDeadlineSeconds=60000`과 완료 후 `ttlSecondsAfterFinished=3600`을 구분합니다.
- CI apply의 Kubernetes admin root를 8개로 현행화하고 `actions-runner-k8s`를 설명합니다.
- Feast apply의 ARC 셀프 호스티드 러너 주 경로와 기존 WIF/GKE Job 롤백 경로를 구분합니다.
- ArgoCD AppProject destination과 Application 9개, 자동 sync 정책을 반영합니다.
- ResourceQuota·LimitRange가 있는 namespace 전체를 나열합니다.
- HPA 부재와 ARC/CronJob 기반 동적 Pod·Job 수를 구분합니다.
- Grafana as-code dashboard를 7개로 수정합니다.
- Agent Orchestration DB와 MLflow artifact, code artifact, experiment result, ES snapshot GCS
  저장소를 데이터 계층에 반영합니다.
- ARC, Agent Orchestration, 실험 Job의 주요 requests/limits를 리소스 계층에 추가합니다.

## 전체 누락 재검토 방법

기존 발견 사항만 고치는 방식에 그치지 않고 다음 인벤토리를 다시 생성해 문서와
양방향 대조합니다.

- 모든 Terraform root와 `apply.yml`의 `ADMIN_ROOTS`
- 모든 `google_storage_bucket`, `google_sql_database`, GKE node pool
- 모든 Kubernetes namespace, ResourceQuota, LimitRange, ServiceAccount, NetworkPolicy
- 모든 ArgoCD Application과 AppProject destination
- `deploy/`의 Deployment, Job, CronJob, Service 및 ARC scale set
- 모니터링 dashboard와 ServiceMonitor/PodMonitor
- 문서의 숫자, `~만`, `없음`, `전부`, `미적용`, `manual sync` 같은 절대 표현

요약 문서라는 성격상 모든 개별 IAM binding을 열거하지는 않지만, 운영 경계나 비용,
권한, 배포 책임을 바꾸는 리소스는 누락하지 않습니다.

## 검증

- 문서가 가리키는 로컬 경로가 실제로 존재하는지 확인합니다.
- 코드에서 추출한 root/Application/quota/dashboard/DB/bucket 목록과 문서 목록을 대조합니다.
- `git diff --check`로 Markdown 공백 오류를 확인합니다.
- 변경 diff에서 secret 값, Terraform state, `.tfvars` 실값이 포함되지 않았는지 확인합니다.
- 독립 peer reviewer가 이슈 #615의 완료 조건과 현재 코드에 맞춰 diff를 다시 검토합니다.
- peer review의 Critical/Important 항목은 수정 후 동일 검증을 다시 수행합니다.

## 영향과 롤백

Terraform, Kubernetes, GCP, IAM, 비용과 리전 동작은 바뀌지 않습니다. 문서만
변경하므로 롤백은 해당 문서 커밋을 되돌리는 방식입니다.
