# batch-od 비-Spot node pool 추가 계획

> 설계: `../specs/2026-07-22-batch-od-node-pool-design.md`
> 관련 이슈: #297

## 구현

1. `terraform/envs/dev/variables.tf`에 `batch_od_gke_node_pool_name`,
   `batch_od_gke_machine_type`, `batch_od_gke_node_count_max` 변수를 추가한다.
   기본값은 `batch-od`, `e2-standard-2`, `2`(`batch_spot` 변수 뒤에 배치).
2. `terraform/envs/dev/gke.tf`에 `google_container_node_pool.batch_od` 리소스를
   추가한다(`batch_spot` 리소스 뒤). 구조는 `batch_spot`과 동일하되 `spot = false`,
   taint `workload=batch-od:NoSchedule`.
3. `docs/TERRAFORM_DEV.md` node pool 테이블에 `batch-spot`(#173에서 누락)과
   `batch-od`를 추가한다.
4. `docs/INFRASTRUCTURE_SUMMARY.md` GKE node pool 행에 같은 내용을 반영한다.

## 사전 검증

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
git diff --check
```

`validate`에서 변수·리소스 선언 오류가 없는지 확인한다. `plan`은 실제
`terraform.tfvars`가 있는 환경에서 별도로 수행한다.

## 적용 및 사후 검증

`terraform apply`는 별도 승인 후 수행한다.

1. `plan`에서 `google_container_node_pool.batch_od` 추가만 확인하고, 기존 node
   pool·클러스터 리소스의 변경·교체가 없는지 검토한다.
2. apply 후 `gcloud container node-pools list`에 `batch-od`가 보이는지 확인한다.
3. `kubectl get nodes -l workload=batch-od`가 평시 0개(min 0)인지 확인한다.
4. filebeat, node-exporter가 batch-od 노드에 스케줄되는지(노드가 생겼을 때)
   확인한다.

## 롤백

문제가 있으면 `batch-od` node pool 리소스를 Terraform에서 제거하고 apply한다.
해당 풀에 실행 중인 pod가 없는지 먼저 확인한다.
