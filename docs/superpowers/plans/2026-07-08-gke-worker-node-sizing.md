# dev GKE Worker Node 크기 조정 계획

## 이슈

Closes #41.

## 범위

- dev GKE worker node machine type을 `e2-small`에서 `e2-standard-4`로 변경합니다.
- GKE control plane은 GKE가 관리하므로 크기 조정 범위에서 제외합니다.
- node autoscaling min/max, disk, IAM, network, Workload Identity는 변경하지
  않습니다.
- 새 기준이 보이도록 현재 운영 문서와 과거 #5 기록을 갱신합니다.

## 구현

- `terraform/envs/dev/variables.tf`
  - `gke_machine_type` 기본값을 `e2-standard-4`로 변경합니다.
  - 변수 설명에 4 vCPU / 16 GB 목표를 문서화합니다.
- `terraform/envs/dev/terraform.tfvars.example`
  - 예시 값을 `e2-standard-4`로 변경합니다.
- 로컬 전용: `terraform/envs/dev/terraform.tfvars`
  - plan/apply 검증을 위해 ignore된 로컬 값을 `e2-standard-4`로 변경합니다.
- 문서
  - `docs/TERRAFORM_DEV.md`를 갱신합니다.
  - 이 계획과 대응 설계 spec을 추가합니다.
  - 과거 #5 GKE design/plan에서 machine sizing 부분이 대체되었음을 표시합니다.

## 검증 체크리스트

- [x] `terraform -chdir=terraform/envs/dev fmt -check -recursive -no-color` 통과
- [x] `terraform -chdir=terraform/envs/dev validate -no-color` 통과
- [x] `terraform -chdir=terraform/envs/dev plan -no-color -input=false`에서 node
      pool replacement 또는 update 영향을 검토
- [x] `git diff --check` 통과
- [x] secret, state, plan, service account key, 실제 tfvars 값 커밋 없음

## Apply 메모

node pool machine type 변경은 실행 중인 workload를 중단시킬 수 있으므로, 사용자와
plan output을 검토한 뒤에만 apply합니다.

마지막으로 검토한 plan:

- `0 to add`, `1 to change`, `0 to destroy`
- 이미 적용된 remote `dev-default` node pool state를 refresh했습니다.
- `google_container_node_pool.dev`는 Terraform 리소스 수준에서 in-place update됩니다.
- `node_config.machine_type`: `e2-small` -> `e2-standard-4`

운영 영향:

- Terraform이 node pool 리소스 destroy를 보고하지 않더라도 GKE는 실제 node VM을
  재생성하거나 rolling할 수 있습니다.
- 단일 node pool과 min 1 node 구조에서는 Pod가 evict 후 reschedule될 수 있습니다.
  적합한 node가 일시적으로 없으면 Pod가 Pending으로 남거나 unavailable 상태가 될 수
  있습니다.
- 가능하면 Airflow 설치 전에 apply합니다. 이미 cluster에서 workload가 실행 중이면
  변경 전에 maintenance window를 조율하거나 여유 capacity를 추가합니다.
