# Executor MLflow tracking 좌표 주입과 egress 허용 설계

## 목표

experiment executor의 학습이 MLflow run을 **in-cluster tracking server에 남기도록**
좌표와 네트워크 경로를 함께 연다. 지금은 좌표가 없어 run이 Pod 로컬 file store에
기록되고 Pod과 함께 사라지며, paired 비교가 내려받을 artifact가 존재하지 않는다.

## 왜 두 변경을 나눌 수 없는가

**둘 중 하나만 넣으면 실패가 사유 없이 드러난다.** 이것이 이 변경에서 가장 중요한
제약이다.

- **env만 넣고 egress를 빠뜨리면**: `mlflow`가 tracking server에 연결하지 못하고
  재시도하다 학습이 `ORCH_TRAINING_TIMEOUT_SEC`(1800초)까지 매달린다. 실패 사유는
  `executor job failed: <job명>`뿐이고 어느 단계에서 왜 막혔는지는 남지 않는다.
- **egress만 열고 env를 빠뜨리면**: 경로만 열리고 학습은 그대로 Pod 로컬 file
  store에 기록한다. **학습은 `exit 0`으로 성공하고** 비교 판정 단계에 가서야 run이
  없다는 것을 안다.

나눠야 한다면 **egress를 먼저** 넣는다. egress만 있는 상태는 현행 동작과 같아
무해하지만, env만 있는 상태는 1800초 먹통을 만든다.

## 변경 범위

### 1. tracking 좌표 (`deploy/agent-orchestration/launcher-cronjob.yaml`)

launcher container env에 `ORCH_MLFLOW_TRACKING_URI`를 추가한다.

    http://mlflow.mlflow.svc.cluster.local:5000

`deploy/serving/deployment.yaml`이 이미 쓰는 것과 같은 좌표다. 값이 비어 있으면
launcher가 아무것도 붙이지 않는 opt-in이므로(애플리케이션 저장소
`launcher/jobs.py`의 `_training_environment()`), 이 값이 실제 배선을 켜는 스위치다.

**이름이 둘로 갈리는 것은 의도다.** launcher가 읽는 이름은 저장소 관례에 따라
`ORCH_MLFLOW_TRACKING_URI`이고, executor container로 **내보내는** 이름은 접두사
없는 `MLFLOW_TRACKING_URI`다. 값을 실제로 읽는 주체가 executor 코드가 아니라
workspace의 `src/pipeline/train.py`이고, 그쪽은 mlflow 표준 변수명을 본다.

전달은 `workspace-preparer`(baseline 학습)와 `candidate-finalizer`(candidate 학습)
두 container에만 붙는다. 나머지 여섯 container는 학습을 돌지 않는다.

### 2. egress NetworkPolicy (`terraform/admin/autoresearch-k8s/experiment_executor.tf`)

`experiment-jobs-executor-egress`에 세 번째 규칙을 추가한다.

- namespace: `app.kubernetes.io/name=mlflow`
- Pod: `app.kubernetes.io/name=mlflow`
- 목적지: `TCP/5000`

기존 두 규칙(공개 443, in-cluster Experiment API 8000)은 그대로 둔다.

**두 selector를 같은 `to` peer 안에 둔다.** Kubernetes NetworkPolicy는 같은 peer
안의 `namespaceSelector`와 `podSelector`를 AND로 평가한다. 블록을 나누면 합집합이
되어 "그 namespace의 모든 Pod"까지 열린다 — `#562`가 Experiment API 규칙에 세운
것과 같은 판단이다.

**포트는 Service 포트가 아니라 Pod 포트다.** `deploy/mlflow/service.yaml`의
`port: 5000`은 `targetPort: http`로 해석되고, `deploy/mlflow/deployment.yaml`의
`containerPort: 5000`이 그 실체다. 둘이 같은 값이라 혼동이 없지만, 이후 mlflow가
container 포트를 바꾸면 Service만 보고 판단하면 안 된다.

별도로 열어야 하는 이유는 기본 경계가 사설 대역을 `except`로 막기 때문이다
(`local.public_egress_private_cidr_exceptions`). ns 공용 `experiment_jobs_egress`가
`172.16.128.0/24`를 여는 것은 **포트 53(DNS) 전용**이라 이름 해석만 된다.

`mlflow` namespace 쪽은 `policyTypes: ["Egress"]`뿐이라 인바운드 제약이 없다.
받는 쪽 변경은 필요하지 않다.

### 3. 계약 검사 (`scripts/check-experiment-launcher-manifest-contract.rb`)

`expected_literals`에 `ORCH_MLFLOW_TRACKING_URI`를 고정한다.

이 값의 실패는 **조용하다.** 빠지거나 틀리면 mlflow가 Pod 로컬 file store로
fallback하고 학습은 `exit 0`으로 끝나므로 사유 코드도 로그도 남지 않는다. 정적으로
잡아야 하는 부류이며, `#575`가 `ORCH_EXECUTOR_API_TOKEN` 참조를 정적으로 잡기로 한
것과 같은 논리다.

mutation self-test는 두 경우를 거부한다.

1. env 삭제
2. 포트 변경(5000 → 8080) — egress가 5000만 여므로 값만 바꾸면 조용히 막힌다

## 변경하지 않는 것

- image digest — executor는 `promote-agent-orchestration-digests` 자동 승격 대상이
  아니라 수동 PR이 유일한 경로이고(`#598`이 v0.9.3으로 정본화 완료), 이 PR의 범위가
  아니다. launcher·API digest는 자동 승격 영역이라 손대면 다음 승격에 덮인다.
- IAM, Cloud SQL 경로, `experiment_jobs_egress`의 기본 경계
- `deploy/agent-orchestration/network-policy.yaml` — executor **ingress**는 `#596`이
  다루는 별건이며 이 PR과 파일이 겹치지 않는다.

## 적용 후 기대 상태

Argo CD sync 뒤 launcher CronJob env에 `ORCH_MLFLOW_TRACKING_URI`가 존재하고,
`terraform apply` 뒤 `experiment-jobs-executor-egress`의 egress 규칙이 3개가 된다.
다음 실험부터 baseline·candidate 학습이 `ctr-model-experiment` MLflow experiment에
run을 남기고, `reproducibility/{snapshot,split,metrics}/` artifact가 그 run에 붙는다.

## 남는 것 (이 PR 범위 밖)

run이 살아남아도 **어느 run이 어느 실험 것인지는 여전히 알 수 없다.** MLflow
좌표에 `experiment_id`가 실리지 않기 때문이다(`src/tracking/namespace.py`의
`EXPERIMENT_EXPERIMENT_NAME`이 상수 하나이고, executor는 `--experiment
{baseline|candidate}`만 넘긴다). 학습 직후 run_id를 붙잡아 Experiment API에 보고하는
경로가 필요하며, 애플리케이션 저장소 `SKYAHO/Autoresearch#623`이 그 범위다.
