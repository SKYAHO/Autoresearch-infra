# v0.9.0 학습 executor 활성화 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or **superpowers:executing-plans** to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** dev launcher가 v0.9.0 executor에 학습 snapshot 좌표와 필수 timeout을 전달하도록 immutable image digest와 CronJob 계약을 활성화합니다.

**Architecture:** `deploy/agent-orchestration/launcher-cronjob.yaml`을 GitOps 정본으로 유지하고, launcher image 및 executor Job image를 v0.9.0 digest로 교체합니다. 같은 파일의 launcher container에 학습 URI와 세 timeout을 literal env로 주입하며, `scripts/check-experiment-launcher-manifest-contract.rb`와 self-test가 digest·필수 env·구식 PATH 재유입을 정적으로 검증합니다.

**Tech Stack:** Kubernetes YAML, Ruby manifest contract checker, GitHub/ArgoCD GitOps, Markdown 운영 문서.

## Global Constraints

- 대상 환경은 dev이며 Artifact Registry repository는 `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/`입니다.
- launcher 신규 digest는 `sha256:24bf725cab23ff2b1e54086a5366538f23aea408aae7f6e12073e19454e6b04e`입니다.
- executor 신규 digest는 `sha256:a3ee4aff0266ee2781608b2172c78f9def70ff7aa73c657df97c361566075808`입니다.
- `ORCH_TRAINING_DATASET_URI`는 `gs://autoresearch-503903-autoresearch-dev-experiment-results/training-snapshots/by-hash/d3d273e66324042cd8e547068c194231cf1812d53cb68236edba56b067055293/`입니다.
- timeout은 `ORCH_TRAINING_TIMEOUT_SEC=1800`, `ORCH_TRAINING_DOWNLOAD_TIMEOUT_SEC=600`, `ORCH_UV_SYNC_TIMEOUT_SEC=900`입니다.
- `ORCH_TRAINING_DATASET_PATH`는 허용하지 않으며 manifest에 있으면 제거하고 contract checker가 거부합니다.
- API/UI/runner image, resource request/limit, CronJob suspend, IAM, Terraform/GCP resource는 변경하지 않습니다.
- 실제 ArgoCD sync, CronJob suspend=false 전환, 실험 발행과 ROC-AUC 검증은 이 작업에서 수행하지 않습니다.
- launcher/executor release rollback은 직전 digest와 학습 env를 Git revert로 되돌리며 snapshot bucket IAM은 변경하지 않습니다.

---

### Task 1: 학습 release 계약의 실패 테스트 작성

**Files:**

- Modify: `scripts/test-check-experiment-launcher-manifest-contract.rb`
- Test: `scripts/test-check-experiment-launcher-manifest-contract.rb`

**Interfaces:**

- Consumes: `ExperimentLauncherManifestContract::MANIFEST_PATH`와 기존 YAML fixture 복사/검증 helper.
- Produces: 신규 launcher/executor digest와 네 학습 env가 manifest에 없을 때 실패하는 self-test.

- [x] **Step 1: v0.9.0 manifest assertion을 test 파일에 먼저 추가한다**

기존 `run!`의 `ExperimentLauncherManifestContract.check!` 호출 뒤에
`check_v09_training_release!`를 호출하고, 아래와 같이 실제 CronJob의 launcher image,
`ORCH_EXECUTOR_IMAGE`, 네 학습 env를 exact match로 검사합니다. test 파일에 아래
`expect_equal` helper도 추가합니다.

```ruby
def expect_equal(expected, actual, description)
  return if expected == actual

  raise "#{description} 불일치: 기대=#{expected.inspect}, 실제=#{actual.inspect}"
end

def check_v09_training_release!
  documents = YAML.load_stream(File.read(ExperimentLauncherManifestContract::MANIFEST_PATH)).compact
  cron_job = documents.find { |document| document["kind"] == "CronJob" }
  container = cron_job.dig("spec", "jobTemplate", "spec", "template", "spec", "containers", 0)
  environment = container.fetch("env").to_h { |item| [item.fetch("name"), item] }

  expect_equal(
    "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher@sha256:24bf725cab23ff2b1e54086a5366538f23aea408aae7f6e12073e19454e6b04e",
    container.fetch("image"),
    "v0.9.0 launcher image"
  )
  expected = {
    "ORCH_EXECUTOR_IMAGE" => "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:a3ee4aff0266ee2781608b2172c78f9def70ff7aa73c657df97c361566075808",
    "ORCH_TRAINING_DATASET_URI" => "gs://autoresearch-503903-autoresearch-dev-experiment-results/training-snapshots/by-hash/d3d273e66324042cd8e547068c194231cf1812d53cb68236edba56b067055293/",
    "ORCH_TRAINING_TIMEOUT_SEC" => "1800",
    "ORCH_TRAINING_DOWNLOAD_TIMEOUT_SEC" => "600",
    "ORCH_UV_SYNC_TIMEOUT_SEC" => "900"
  }
  expected.each do |name, value|
    expect_equal({ "name" => name, "value" => value }, environment.fetch(name), name)
  end
  raise "구식 ORCH_TRAINING_DATASET_PATH가 남아 있습니다" if environment.key?("ORCH_TRAINING_DATASET_PATH")
end
```

- [x] **Step 2: RED 상태를 확인한다**

Run: `ruby scripts/test-check-experiment-launcher-manifest-contract.rb`

Expected: FAIL. 현재 manifest의 launcher digest가 v0.9.0 기대값과 다르다는 assertion이
발생해야 하며, 테스트 파일 오타나 YAML parse 오류로 실패하면 안 됩니다.

### Task 2: launcher/executor manifest와 정적 contract를 v0.9.0으로 갱신

**Files:**

- Modify: `deploy/agent-orchestration/launcher-cronjob.yaml`
- Modify: `scripts/check-experiment-launcher-manifest-contract.rb`

**Interfaces:**

- Consumes: Task 1의 v0.9.0 exact assertions.
- Produces: ArgoCD가 sync할 launcher/executor image와 executor 전달용 학습 env.

- [x] **Step 1: launcher와 executor image reference를 교체한다**

`launcher-cronjob.yaml`의 launcher container image를 다음 full reference로 교체합니다.

```text
asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher@sha256:24bf725cab23ff2b1e54086a5366538f23aea408aae7f6e12073e19454e6b04e
```

`ORCH_EXECUTOR_IMAGE` env도 다음 full reference로 교체합니다.

```text
asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:a3ee4aff0266ee2781608b2172c78f9def70ff7aa73c657df97c361566075808
```

API bootstrap initContainer, API/UI/runner manifest, suspend, resources는 건드리지 않습니다.

- [x] **Step 2: launcher에 학습 env 네 개를 추가하고 구식 PATH를 제거한다**

launcher container의 기존 executor 설정 env와 timeout env 인접 영역에 아래 항목을
literal `value`로 추가합니다.

```yaml
- name: ORCH_TRAINING_DATASET_URI
  value: gs://autoresearch-503903-autoresearch-dev-experiment-results/training-snapshots/by-hash/d3d273e66324042cd8e547068c194231cf1812d53cb68236edba56b067055293/
- name: ORCH_TRAINING_TIMEOUT_SEC
  value: "1800"
- name: ORCH_TRAINING_DOWNLOAD_TIMEOUT_SEC
  value: "600"
- name: ORCH_UV_SYNC_TIMEOUT_SEC
  value: "900"
```

`ORCH_TRAINING_DATASET_PATH`가 발견되면 해당 env entry를 삭제합니다. URI는 Secret
참조나 ConfigMap 참조로 바꾸지 않고, 이번 dev 고정 snapshot 계약을 manifest에서 직접
보이게 합니다.

- [x] **Step 3: contract checker의 expected contract를 갱신한다**

`scripts/check-experiment-launcher-manifest-contract.rb`의 `check_cron_job!`에서
expected launcher/executor image를 신규 full reference로 교체하고, `expected_literals`에
네 학습 env를 exact `{ "name", "value" }` 항목으로 추가합니다. `environment.key?`로
`ORCH_TRAINING_DATASET_PATH` 존재를 검사해 `ContractError`를 발생시킵니다.

- [x] **Step 4: GREEN 상태를 확인한다**

Run:

```bash
ruby scripts/check-experiment-launcher-manifest-contract.rb
ruby scripts/test-check-experiment-launcher-manifest-contract.rb
```

Expected: 두 명령 모두 exit 0이고, self-test가 공개 인터넷 egress·CIDR·digest·API
token·학습 env mutation을 계속 거부합니다.

### Task 3: 운영 문서와 변경 이력 갱신

**Files:**

- Modify: `docs/runbooks/2026-08-01-auto-research-experiment-job.md`
- Modify: `docs/CHANGE_HISTORY.md`

**Interfaces:**

- Consumes: Task 2의 exact manifest contract.
- Produces: v0.9.0 digest, 학습 env, suspend/rollback 운영 안내.

- [x] **Step 1: runbook에 v0.9.0 provenance와 학습 env를 기록한다**

runbook의 최신 release provenance 절에 v0.9.0 표를 추가합니다. launcher/executor 신규
digest, snapshot URI, 네 timeout, API/UI/runner를 이번 변경에서 올리지 않는 범위,
suspend=false 전환은 애플리케이션 담당자가 수행한다는 경계를 기록합니다.

- [x] **Step 2: CHANGE_HISTORY에 #591 결정을 기록한다**

최상단에 #591 항목을 추가해 v0.9.0 digest 교체, opt-in URI와 필수 timeout 네 개의
동시 공급, 구식 PATH 금지, IAM/resource/suspend 미변경, ArgoCD sync 후 담당자 검증과
rollback 절차를 요약합니다.

### Task 4: 최종 검증과 커밋

**Files:**

- Test: `scripts/check-experiment-launcher-manifest-contract.rb`
- Test: `scripts/test-check-experiment-launcher-manifest-contract.rb`
- Test: `scripts/test-promote-agent-orchestration-digests.rb`

- [x] **Step 1: 전체 관련 self-test를 실행한다**

Run:

```bash
ruby scripts/check-experiment-launcher-manifest-contract.rb
ruby scripts/test-check-experiment-launcher-manifest-contract.rb
ruby scripts/test-promote-agent-orchestration-digests.rb
git diff --check
```

Expected: 모든 Ruby contract self-test가 exit 0이며 promotion helper의 기존 API/UI/
runner 보호 계약도 통과합니다.

- [ ] **Step 2: 변경 범위와 금지 항목을 확인한다**

Run:

```bash
git diff --name-only origin/main...HEAD
if rg -n "ORCH_TRAINING_DATASET_PATH" deploy/agent-orchestration/launcher-cronjob.yaml; then exit 1; fi
if rg -n "2818f29a658b36c14199bd7e2d195e56921cf876217b6504af3fbc5634627837|7999677d238f29202fa5720700e86943937bb3d0536cdb3269231c01a14c2475" deploy/agent-orchestration scripts; then exit 1; fi
```

Expected: 위 scan이 출력하지 않아 구식 training PATH가 활성 manifest에, 기존
launcher/executor digest가 manifest·checker에 남지 않습니다. checker/test에는 구식 PATH를
거부하는 literal이 의도적으로 남고, docs에는 rollback 좌표를 설명하는 역사적 문구가
남습니다. 변경 파일은 manifest·checker·runbook·CHANGE_HISTORY·계약 test와 승인된
spec/plan 범위에 있고, API/UI/runner digest와 suspend/resource/IAM 파일은 변경되지
않아야 합니다.

- [x] **Step 3: 커밋한다**

```bash
git add deploy/agent-orchestration/launcher-cronjob.yaml \
  scripts/check-experiment-launcher-manifest-contract.rb \
  scripts/test-check-experiment-launcher-manifest-contract.rb \
  docs/runbooks/2026-08-01-auto-research-experiment-job.md \
  docs/CHANGE_HISTORY.md \
  docs/superpowers/plans/2026-08-08-training-executor-enable.md
git commit -m "feat: v0.9.0 학습 executor 배선 활성화"
```

구현 후 ArgoCD sync와 CronJob resume/실험 검증은 별도 운영 단계이며 이 커밋에서
수행하지 않습니다.
