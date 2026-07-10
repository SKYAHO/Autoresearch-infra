# GKE metadata egress 복구 계획

> Issue: #126
> 대상: `terraform/admin/airflow-k8s`

## 목표

GKE Standard + Calico에서 `airflow` namespace의 Pod가 Workload Identity
Federation용 GKE metadata server에 연결할 수 있도록 NetworkPolicy를 수정한다.
기존 egress 경계와 Dataplane V2용 metadata 경로는 유지한다.

## 변경 범위

1. `airflow-egress`에 `169.254.169.252/32` TCP 987/988 허용을 추가한다.
2. `169.254.169.254/32` TCP 80과 나머지 egress 규칙은 변경하지 않는다.
3. Terraform 운영 문서에 Calico와 Dataplane V2의 metadata 경로 차이,
   검증 순서와 롤백 절차를 기록한다.

IAM, Secret Manager, GKE cluster 설정, 노드풀, 외부 endpoint는 변경하지 않는다.
실제 `terraform apply`와 Kubernetes 변경은 이 PR 범위에서 수행하지 않는다.

## 검증 계획

1. admin root에서 `terraform fmt -check`, `init -backend=false`, `validate`를
   실행한다.
2. 실제 backend와 관리자 인증을 사용할 수 있으면 lock을 잡지 않는 plan으로
   `airflow-egress` 한 개의 in-place 변경만 있는지 확인한다.
3. diff에서 IAM·Secret·비용·공개 endpoint 변경과 add/delete/replace가 없는지
   확인한다.
4. 별도 적용 승인 후 metadata token endpoint의 HTTP 상태만 확인하고, token
   본문은 출력하거나 저장하지 않는다. 이어서 격리된 QA GCS prefix 읽기/쓰기와
   1-micro-work smoke test를 수행한다.

## 적용 및 롤백

승인된 운영자는 admin root plan을 다시 확인한 뒤 한 번만 apply한다. 문제가
발생하면 이 변경에서 추가한 `169.254.169.252/32` egress 블록만 제거하고 같은
root를 apply한다. 두 작업 모두 NetworkPolicy의 in-place 갱신이어야 하며 GKE
노드 재생성을 포함해서는 안 된다.

## 구현 검증 결과

2026-07-10 기준 admin root의 `fmt -check`, `init -backend=false`, `validate`가
통과했다. 실제 GCS backend와 기존 state 입력을 사용한 전체
`plan -refresh=false -lock=false`는 `airflow-egress`만 업데이트하며
`0 to add, 1 to change, 0 to destroy`로 끝났다. refresh를 포함한 plan은 현재
운영자 네트워크에서 GKE public API endpoint에 연결할 수 없어 완료되지 않았다.
따라서 apply 승인 후에는 허용된 관리자 네트워크에서 refresh를 포함한 plan을
다시 실행하고 같은 결과인지 확인해야 한다.
