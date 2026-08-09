# Stage 1 실험 결과 게시·실행 시간 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stage 1 executor가 GCS에 결과를 write-once로 게시하고, 60000초 Job deadline과 6000초 Codex timeout으로 측정·채점을 완료하게 한다.

**Architecture:** CronJob manifest의 literal env와 Ruby contract를 함께 갱신한다. executor Job 생성을 실제로 허용하는 Kubernetes ValidatingAdmissionPolicy의 deadline upper bound도 60000초로 올리고, Terraform test로 그 연동을 고정한다. TTL 상한, IAM, network egress, image digest는 변경하지 않는다.

**Tech Stack:** Kubernetes YAML, Ruby YAML contract checker, Terraform Kubernetes provider test, ArgoCD GitOps, Markdown runbook.

## Global Constraints

- 결과 root는 `gs://autoresearch-503903-autoresearch-dev-experiment-results`다.
- `ORCH_ACTIVE_DEADLINE_SEC=60000`, `ORCH_CODEX_TIMEOUT_SEC=6000`이며 후자는 전자보다 작아야 한다.
- admission의 `activeDeadlineSeconds` upper bound도 60000초여야 한다.
- `ttlSecondsAfterFinished` upper bound 3600초, GCS IAM, executor egress, MLflow URI, image digest, resource/quota는 유지한다.
- 실제 Terraform apply, ArgoCD sync, CronJob resume, 실험 발행은 수행하지 않는다.

---

### Task 1: launcher 결과 게시·timeout 계약의 RED 테스트 작성

**Files:**

- Modify: `scripts/test-check-experiment-launcher-manifest-contract.rb`
- Test: `scripts/test-check-experiment-launcher-manifest-contract.rb`

**Interfaces:**

- Consumes: `ExperimentLauncherManifestContract.check!`와 CronJob YAML fixture를 복사하는 `mutate_manifest` helper.
- Produces: 결과 root와 두 timeout의 exact-value assertion 및 각 mutation을 거부하는 self-test.

- [x] `check_current_release!`의 `expected` hash에 아래 exact 값을 추가한다.

```ruby
"ORCH_EXPERIMENT_RESULTS_ROOT" => "gs://autoresearch-503903-autoresearch-dev-experiment-results",
"ORCH_ACTIVE_DEADLINE_SEC" => "60000",
"ORCH_CODEX_TIMEOUT_SEC" => "6000"
```

- [x] 결과 root 삭제, deadline을 `"3600"`으로 변경, Codex timeout을 `"60000"`으로 변경하는 세 `expect_failure` mutation을 추가한다.
- [x] `docker run --rm -v "$PWD":/workspace -w /workspace ruby:3.4-alpine ruby scripts/test-check-experiment-launcher-manifest-contract.rb`를 실행해 결과 root assertion이 RED로 실패하는지 확인한다.

### Task 2: CronJob과 Ruby contract를 GREEN으로 만든다

**Files:**

- Modify: `deploy/agent-orchestration/launcher-cronjob.yaml`
- Modify: `scripts/check-experiment-launcher-manifest-contract.rb`
- Test: `scripts/check-experiment-launcher-manifest-contract.rb`

**Interfaces:**

- Consumes: Task 1의 three exact env requirements.
- Produces: launcher가 executor Job template으로 전달하는 Stage 1 env와 fail-closed static contract.

- [x] executor image 인접 env에 아래 결과 root를 추가한다.

```yaml
- name: ORCH_EXPERIMENT_RESULTS_ROOT
  value: gs://autoresearch-503903-autoresearch-dev-experiment-results
```

- [x] `ORCH_ACTIVE_DEADLINE_SEC`과 `ORCH_CODEX_TIMEOUT_SEC`를 각각 `"60000"`, `"6000"`으로 교체하고, 주석의 admission upper bound를 60000초로 맞춘다.
- [x] `check_cron_job!`의 `expected_literals`에 results root와 두 timeout exact 값을 반영한다.
- [x] Ruby contract와 self-test를 Docker Ruby 3.4로 실행해 GREEN을 확인한다.

### Task 3: admission upper bound의 RED/GREEN 검증

**Files:**

- Modify: `terraform/admin/autoresearch-k8s/tests/experiment_jobs_contract.tftest.hcl`
- Modify: `terraform/admin/autoresearch-k8s/experiment_jobs.tf`
- Test: `terraform/admin/autoresearch-k8s/tests/experiment_jobs_contract.tftest.hcl`

**Interfaces:**

- Consumes: `kubernetes_manifest.experiment_job_admission_policy`의 rendered CEL validations.
- Produces: executor가 `activeDeadlineSeconds: 60000`인 Job을 server-side에서 허용하는 constraint.

- [x] 새 `active_deadline_allows_stage1_budget` test run에 `object.spec.activeDeadlineSeconds <= 60000`가 rendered validation에 있어야 한다는 assertion을 넣는다.
- [x] `terraform -chdir=terraform/admin/autoresearch-k8s test`를 실행해 기존 `<= 3600` constraint로 새 assertion만 RED가 되는지 확인한다.
- [x] CEL expression과 message를 아래 값으로 바꾸고, 설명 주석도 60000초로 갱신한다.

```hcl
expression = "has(object.spec.activeDeadlineSeconds) && object.spec.activeDeadlineSeconds > 0 && object.spec.activeDeadlineSeconds <= 60000"
message    = "실험 Job은 activeDeadlineSeconds를 1~60000초로 명시해야 합니다."
```

- [x] Terraform test가 모든 run에 GREEN인지 확인한다. TTL validation은 변경하지 않는다.

### Task 4: 운영 문서와 변경 이력을 갱신한다

**Files:**

- Modify: `docs/runbooks/2026-08-01-auto-research-experiment-job.md`
- Modify: `docs/CHANGE_HISTORY.md`

**Interfaces:**

- Consumes: Tasks 2–3의 exact env와 60000초 admission contract.
- Produces: rollout 후 live 값·결과 객체·rollback을 확인하는 운영 절차.

- [x] runbook의 current admission contract를 60000초 deadline과 3600초 TTL로 분리해 기록하고, 60000 + 3600초 quota/cost 영향을 명시한다.
- [x] live CronJob env grep에 결과 root와 두 timeout을 추가하고, `gcloud storage ls`로 expected experiment prefix의 `metrics.json`을 확인하는 명령을 추가한다.
- [x] admin root apply로 live admission 상한을 먼저 갱신하고, ArgoCD sync 뒤 CronJob env를 확인한 다음 launcher suspend를 해제하는 순서를 runbook에 명시한다. VAP가 3600초인 채 env가 먼저 반영되면 `FailedCreate`가 된다는 실패 모드도 기록한다.
- [x] CHANGE_HISTORY 최상단에 #604의 write-once 결과 게시, 새 IAM 없음, admission 동시 변경, suspend→revert rollback을 기록한다.

### Task 5: 최종 검증·self-review·커밋

**Files:**

- Test: Tasks 1–3 files and docs

- [x] `git diff --check`, scoped diff, Docker Ruby contract/self-test, promotion self-test, admin Terraform test, Kubernetes client dry-run을 실행한다.
- [x] IAM binding·public ingress·image digest·TTL upper bound가 diff에 없는지 self-review한다.
- [x] 아래 하나의 논리적 커밋을 만든다.

```text
fix: Stage 1 결과 게시 시간 설정 수정
```
