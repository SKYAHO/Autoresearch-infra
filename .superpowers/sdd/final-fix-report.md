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
