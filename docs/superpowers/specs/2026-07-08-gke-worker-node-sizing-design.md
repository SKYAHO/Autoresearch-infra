# dev GKE Worker Node 크기 조정 설계

## 이슈

Closes #41.

## 배경

dev GKE 클러스터는 처음에 최소 비용 기준으로 `e2-small` worker node pool을 사용해
만들었습니다. 다음 인프라 단계에서는 control plane은 GKE 관리형으로 유지하면서,
Kubernetes workload 검증과 향후 Airflow 설치 경계에 필요한 용량을 제공합니다.

요청된 목표:

- "master node": 2 vCPU / 8 GB
- worker node: 4 vCPU / 16 GB

GKE Standard는 control plane CPU나 memory를 선택하는 Terraform 설정을 제공하지
않습니다. GKE control plane은 Google이 관리합니다. 따라서 이 이슈에서는 worker
node machine type만 변경합니다.

## 결정

dev GKE worker node pool에 `e2-standard-4`를 사용합니다.

근거:

- `e2-standard-4`는 요청된 worker 용량 목표인 4 vCPU와 16 GB memory에 맞습니다.
- 기존 node pool, service account, Workload Identity, private node, Cloud NAT,
  disk size, autoscaling 경계는 그대로 유지합니다.
- machine type 변경에는 IAM 확대가 필요하지 않습니다.
- autoscaling을 min 1 / max 2로 유지하면 현재 운영 패턴을 보존하면서 node당 용량만
  늘릴 수 있습니다.

## 영향

- 비용은 `e2-small` 대비 증가합니다. `asia-northeast3`에서 `e2-standard-4`는 할인,
  disk, NAT, 가격 변동을 제외하면 항상 켜진 node 1대 기준 대략 월 USD 95-100
  수준입니다. apply 전 최신 가격을 확인합니다.
- 검토한 Terraform plan은 이미 적용된 remote `dev-default` node pool state를
  기준으로 하며 `0 to add`, `1 to change`, `0 to destroy`를 보고했습니다.
- Terraform 리소스 관점에서는 node pool을 in-place update하지만, GKE는 새 machine
  type을 적용하기 위해 실제 node VM을 재생성하거나 rolling할 수 있습니다.
- dev는 현재 min 1 node인 단일 node pool 구조이므로 업데이트 중 workload가 evict,
  reschedule, 일시 Pending, 일시 unavailable 상태가 될 수 있습니다. Airflow나 다른
  workload가 이미 실행 중이면 apply 전 maintenance window를 잡습니다.
- repository에는 secret, service account key, state 파일, 실제 tfvars 값이 필요하지
  않습니다.

## 롤백

늘어난 크기가 필요하지 않으면 `gke_machine_type`을 `e2-small`로 되돌리고 문서를
갱신한 뒤 plan을 실행합니다. node pool 영향을 확인한 후 apply합니다.
