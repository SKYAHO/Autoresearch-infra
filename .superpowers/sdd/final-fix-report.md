# #373 최종 리뷰 수정 보고서

## 수정 범위

- `docs/superpowers/plans/2026-07-27-gke-vpa-observation.md`의 provider 7.39.0 VPA
  경로를 실제 최상위 `google_container_cluster.dev.vertical_pod_autoscaling`으로
  정정했다.
- `docs/TERRAFORM_DEV.md`에 `dev-apply` Environment reviewer 승인 경로를 기본 dev
  root apply 절차로, 로컬 `terraform.tfvars` apply를 break-glass 절차로 명시했다.
- VPA plan 검토 기준을 cluster의 in-place VPA 변경만 허용하고 destroy/replace, IAM,
  node pool, network, Secret 변경을 거부하도록 정렬했다.
- `docs/TEAM_OPERATIONS_RUNBOOK.md`에 CRD Established 대기와 served VPA API discovery
  확인을 추가했다. 기존 전체 namespace pod 목록은 managed addon의 내부 Pod 이름이나
  label을 고정하지 않는 진단용 명령으로 유지했다.

## 선언형 Red/Green 검증

- Red: 수정 전 문서에는 잘못된 `addons_config.vertical_pod_autoscaling` 경로가 있었고,
  runbook에는 CRD Established 대기와 served VPA API 확인 명령이 없었다. 해당 정적
  계약 검사는 실패했다.
- Green: 수정 후 정적 검사는 실제 `gke.tf`의 최상위 VPA block, `dev-apply.yml`의
  `environment: dev-apply`, required CRD/API discovery 명령, VPA plan 변경 제한을 모두
  확인한다.

## 적용 증적 상태

실제 Terraform plan/apply, kubectl live 명령, 원격 변경은 수행하지 않았다. 따라서
Terraform plan 증적과 VPA API/controller readiness 증적은 apply 전 pending 상태이며,
계획 문서의 적용 체크리스트는 완료로 변경하지 않았다.

## 우려

GKE managed addon의 실제 component Pod 구성은 관리형 구현 세부사항이므로 readiness
판정에 Pod 이름이나 label을 사용하지 않는다. apply 전에는 `dev-apply` workflow의 상세
plan에서 허용된 cluster in-place VPA 변경만 있는지 다시 확인해야 한다.

## 재검토 수정 (2026-07-27)

### 수정 범위

- `docs/TEAM_OPERATIONS_RUNBOOK.md`와 계획 Tasks 2-3의 VPA readiness를 CRD Established
  확인 뒤 `verticalpodautoscalers` served API discovery를 최대 120초 polling하는 동일한
  명령 계약으로 정렬했다. timeout은 명시적으로 실패하며, 진단 pod 조회는 전체 namespace
  목록만 출력한다.
- Task 3의 기본 적용 경로를 PR `terraform-plan` 검토 → merge → 사용자 명시 요청의
  `dev-apply` workflow-dispatch → `dev-apply` Environment reviewer 승인으로 변경했다.
  로컬 `terraform.tfvars` apply는 break-glass 절차로만 제한했다.
- PR plan 검토 기준을 `google_container_cluster.dev` 단일 resource address의 in-place
  `vertical_pod_autoscaling` addon 변경으로 한정했다.

### 검증

- 실제 Terraform plan/apply, kubectl live 명령, GitHub workflow dispatch는 수행하지 않았다.
- Markdown command structure red/green 검사 완료:
  - Red: 직전 커밋의 runbook에는 120초 discovery polling이 없고 pod 이름 필터가 있었으며,
    Task 3은 로컬 `terraform.tfvars` apply를 기본 명령으로 제시함을 확인했다.
  - Green: 두 문서의 CRD Established/served API polling/timeout/전체 pod 목록 계약과 Task
    3의 PR plan 검토, 단일 resource address, `dev-apply` dispatch, Environment 승인,
    break-glass 제한을 확인했다. Markdown의 Bash polling snippet도 `bash -n`을 통과했다.
- `git diff --check` 통과.

### 우려

GKE managed addon의 control-plane 구현과 served API discovery 반영 시간은 관리형 동작이다.
120초 timeout이 발생하면 Pod 이름이나 label로 readiness를 추정하지 말고, 전체 pod 목록과
GKE 상태를 별도로 진단해야 한다.

## 최종 재검토 수정 (2026-07-27)

### 수정 범위

- `docs/TEAM_OPERATIONS_RUNBOOK.md`와 계획 Tasks 2-3의 served VPA API polling
  `kubectl api-resources` 호출에 `--request-timeout=5s`를 추가했다. 기존 120초 loop와
  timeout 실패 동작은 유지하며, API server 또는 네트워크 hang이 전체 deadline을 무한히
  초과하지 않게 한다.

### 검증

- 실제 `kubectl` 명령이나 원격 Kubernetes API 호출은 수행하지 않았다.
- Red: 두 문서에 `--request-timeout=5s`가 없음을 정적 검사로 확인했다.
- Green: 두 문서의 모든 served VPA API polling `kubectl api-resources` 호출이
  `--request-timeout=5s`를 포함하고, 기존 120초 deadline, timeout 실패, 전체 pod 목록
  진단 계약을 유지하는지 확인했다. Markdown Bash polling snippet은 `bash -n`으로 검증했다.
- `git diff --check`를 실행했다.

### 우려

5초 요청 제한은 개별 discovery 요청의 무한 대기를 막지만, managed API server의 일시적
지연은 전체 120초 관측 실패로 이어질 수 있다. 이 경우에도 내부 component Pod 이름이나
label로 readiness를 추정하지 않는다.
