# batch-od 비-Spot node pool 추가 설계

> 관련 이슈: #297

## 목적

GKE `batch-spot` node pool(#173)의 GCP Spot VM 선점으로 Action Log shard가
동시에 종료되는 장애(#297)를 방지하기 위해, Spot 중단을 흡수할 수 없는 장시간
배치 작업을 위한 비-Spot(on-demand) node pool을 추가한다.

## 배경

`batch-spot` 풀은 #173/#105에서 **"KPO는 재시도 내성이 있어 Spot 중단을
흡수"** 라는 전제로 설계됐다. 그러나 2026-07-20 논리 날짜
`youtube_gcs_action_log_pipeline` 실행 중, 같은 Spot 노드에 있던
`ensure_action_log_shard_002`·`003`이 동시 선점으로 종료됐다. Action Log shard는
수백 checkpoint를 처리하는 장시간 KPO이며 graceful shutdown을 처리하지 않아
재시도 내성이 없다. 설계 전제가 틀렸음이 입증됐다.

## 변경 결정

- Spot 풀(`batch-spot`)은 유지하되, **비-Spot 풀(`batch-od`)을 추가**한다.
- `batch-od`는 `batch-spot`과 동일한 구조(min 0 scale-from-zero, pd-standard
  30GB, e2-standard-2)를 따르되:
  - `spot = false` (on-demand VM)
  - taint `workload=batch-od:NoSchedule` — `batch-spot`의 `workload=batch-spot`과
    분리해 앱이 명시적으로 Spot vs on-demand를 선택한다.
- 앱 쪽 변경(Action Log DAG toleration 이동, topology spread, SIGTERM checkpoint
  flush)은 Autoresearch-airflow 별도 이슈로 분리한다. 이 저장소는 인프라만
  담당한다.
- DaemonSet(filebeat, node-exporter)은 이미 `Exists/NoSchedule` toleration으로
  모든 taint를 허용하므로(#173에서 통일), batch-od 노드에도 자동 수집된다.

## 영향 및 제외 범위

- `batch-od`는 min 0이므로 평시 비용은 0이다. Pod가 스케줄될 때만 on-demand VM이
  생성된다. e2-standard-2 on-demand 월 ~$55(#104 비용 분석)이지만, 실제로는
  작업 실행 시간에 비례한다.
- 기존 `batch-spot` 풀과 그 taint는 변경하지 않는다. 현재 Spot에서 실행 중인
  작업은 그대로 유지된다.
- GKE 클러스터 control plane, 다른 node pool, 네트워크, IAM은 변경하지 않는다.
- 앱 쪽 스케줄링 변경(tolerance, anti-affinity, graceful shutdown)은 이 변경
  범위가 아니다.

## 롤백

`batch-od` node pool 리소스를 Terraform에서 제거하고 `terraform apply`를
수행한다. 해당 풀에 실행 중인 pod가 없는지 확인한 후 롤백한다. node pool 삭제는
다른 풀이나 클러스터에 영향을 주지 않는다.
