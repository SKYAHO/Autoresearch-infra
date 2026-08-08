# Executor MLflow Tracking 주입 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** experiment executor의 학습이 in-cluster MLflow tracking server에 run을
남기도록 launcher env(`ORCH_MLFLOW_TRACKING_URI`)와 executor egress
NetworkPolicy(`TCP/5000`)를 **같은 PR로** 반영하고, 조용한 회귀를 계약 검사로 막는다.

**Architecture:** 기존 `experiment-jobs-executor-egress`에 세 번째 egress 규칙을
추가하고, `launcher-cronjob.yaml`의 launcher env에 tracking 좌표를 추가한다. 전달
코드는 애플리케이션 저장소가 이미 소유한다(`SKYAHO/Autoresearch#626`). Ruby 계약
검사와 mutation self-test가 env 누락·값 변경을 거부한다.

**Tech Stack:** Kubernetes NetworkPolicy(Terraform `kubernetes_network_policy_v1`),
CronJob YAML, Ruby YAML contract tests, Docker `ruby:3.4-alpine`.

## Global Constraints

- 대상은 `autoresearch-experiments/experiment-jobs-executor-egress`와
  `autoresearch/agent-orchestration-launcher` 둘이다.
- tracking 좌표는 `http://mlflow.mlflow.svc.cluster.local:5000` 하나다.
- egress 목적지는 `TCP/5000` 하나이며, 두 selector는 같은 `to` peer 안에 있어야 한다.
- executor egress 규칙은 총 3개, 기존 두 규칙(공개 443, API 8000)은 유지한다.
- **image digest는 변경하지 않는다.** executor는 `#598`이 v0.9.3으로 정본화했고,
  launcher·API digest는 자동 승격 영역이다.
- IAM, Cloud SQL 경로, `experiment_jobs_egress` 기본 경계는 변경하지 않는다.
- `deploy/agent-orchestration/network-policy.yaml`은 건드리지 않는다(`#596` 소유).

## 순서 제약 (어기면 사유 없이 먹통)

- env와 egress는 **같은 PR**로 나간다.
- 부득이 나눈다면 **egress를 먼저** 넣는다. egress만 있는 상태는 현행 동작과 같아
  무해하지만, env만 있는 상태는 학습이 `ORCH_TRAINING_TIMEOUT_SEC`(1800초)까지
  매달리고 사유는 `executor job failed: <job명>`만 남는다.

---

### Task 1: tracking 좌표와 egress를 함께 추가하고 계약으로 고정한다

**Files:**

- Modify: `deploy/agent-orchestration/launcher-cronjob.yaml`
- Modify: `terraform/admin/autoresearch-k8s/locals.tf`
- Modify: `terraform/admin/autoresearch-k8s/experiment_executor.tf`
- Modify: `scripts/check-experiment-launcher-manifest-contract.rb`
- Modify: `scripts/test-check-experiment-launcher-manifest-contract.rb`

**Step 1: 좌표 확인**

- [x] mlflow Service·Pod 좌표를 Git 선언과 라이브 양쪽에서 대조한다
      (`deploy/mlflow/service.yaml` `port: 5000`/`targetPort: http`,
      `deploy/mlflow/deployment.yaml` `containerPort: 5000`,
      live endpoints `:5000`, ns/Pod label `app.kubernetes.io/name=mlflow`)
- [x] NetworkPolicy가 보는 것은 Service 포트가 아니라 **Pod 포트**임을 확인한다

**Step 2: env 추가**

- [x] `launcher-cronjob.yaml`의 학습 env 블록 끝에 `ORCH_MLFLOW_TRACKING_URI`를 넣는다
- [x] digest 줄(launcher image, `ORCH_EXECUTOR_IMAGE`)은 건드리지 않는다

**Step 3: egress 추가**

- [x] `locals.tf`에 mlflow namespace·selector·port를 기존 API 좌표 관례대로 넣는다
- [x] `experiment_executor.tf`에 세 번째 `egress` 블록을 추가하고, 두 selector를
      같은 `to` 안에 둔다
- [x] 파일 머리 주석의 "두 목적지"를 "세 목적지"로 고치고 규칙 3의 근거를 남긴다

**Step 4: 계약 고정**

- [x] `check-...rb`의 `expected_literals`에 `ORCH_MLFLOW_TRACKING_URI`를 추가한다
- [x] `test-...rb`에 mutation 2건을 추가한다(env 삭제, 포트 5000→8080)
- [x] `tests/experiment_jobs_contract.tftest.hcl`의 포트 allowlist에 MLflow 포트를
      추가한다. 이 단언은 fail-closed라 규칙을 추가하는 것만으로 깨진다 —
      `terraform validate`로는 안 잡히고 `terraform test`에서만 드러난다
- [x] 같은 파일에 반대 방향 단언을 추가한다. 규칙이 사라지면 학습은 `exit 0`으로
      성공한 채 로컬 file store에 남으므로 조용히 드러나지 않는다

**Step 5: 검증**

- [x] `docker run --rm -v "$(pwd):/w" -w /w ruby:3.4-alpine ruby scripts/check-experiment-launcher-manifest-contract.rb`
- [x] `docker run --rm -v "$(pwd):/w" -w /w ruby:3.4-alpine ruby scripts/test-check-experiment-launcher-manifest-contract.rb`
- [x] **역검증**: 체커에서 핀을 제거하면 self-test가 실패하는지 확인한다
      (통과만으로는 새 mutation 케이스가 헛돌았을 가능성을 배제하지 못한다)
- [x] `terraform -chdir=terraform/admin/autoresearch-k8s fmt -check -recursive`
- [x] `terraform -chdir=terraform/admin/autoresearch-k8s validate`
- [x] `terraform -chdir=terraform/admin/autoresearch-k8s test` — **필수.**
      `validate`는 계약 단언을 실행하지 않아 egress 규칙 추가가 `.tftest.hcl`을
      깨뜨리는 것을 놓친다. CI `lint`가 이 명령을 돌린다
- [x] **역검증**: mlflow egress 규칙을 제거하면 `terraform test`가 실패하는지 확인한다
- [x] `git diff --check`

**Step 6: 적용 (사용자 승인 후)**

- [ ] `terraform plan`으로 egress 규칙이 3개가 되는지, 다른 리소스에 변경이 없는지
      확인한다
- [ ] `terraform apply`
- [ ] Argo CD sync로 launcher CronJob env 반영
- [ ] 실험 1건을 흘려 `workspace-preparer` 로그에 tracking URI가 찍히고 MLflow
      `ctr-model-experiment`에 run이 남는지 확인한다

## 롤백

- env: `launcher-cronjob.yaml`에서 해당 항목과 계약 핀을 되돌린다. 값이 없으면
  launcher가 아무것도 붙이지 않는 opt-in이라 이전 동작으로 정확히 복귀한다.
- egress: `experiment_executor.tf`의 세 번째 규칙을 제거하고 `terraform apply`.
  규칙 추가만 했으므로 기존 두 경로에 영향이 없다.
- 두 변경은 서로 독립적으로 되돌릴 수 있으나, **env만 남기고 egress를 되돌리면
  1800초 먹통**이 되므로 되돌릴 때는 env를 먼저 뺀다.

## 비용·영향

- 새 GCP 리소스 없음. NetworkPolicy 규칙 1개와 env 1개 추가라 비용 변화가 없다.
- 권한 확대 없음. egress 목적지를 `mlflow` namespace의 mlflow Pod `TCP/5000`
  하나로 좁혔고, 외부 노출 리소스를 만들지 않는다.
- MLflow 서버에 run·artifact가 쌓이므로 backing store 사용량이 는다. 실험 1건당
  seed 3개 × 2조건 = run 6개이며, artifact는 스냅샷 CSV를 포함한다.

## 남는 것 (이 PR 범위 밖)

- run_id를 Experiment API에 보고하는 경로 — `SKYAHO/Autoresearch#623`.
  이것 없이는 run이 살아남아도 어느 실험 것인지 특정할 수 없다.
- executor digest 자동 승격 확장 — `promote-agent-orchestration-digests`가
  API·launcher·runner·UI 4종만 다뤄 executor는 매번 수동 PR이다.
