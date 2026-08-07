# Agent Orchestration API v0.9.0 Promotion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or **superpowers:executing-plans** to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** dev Agent Orchestration의 API image 7개 참조를 v0.9.0 immutable digest로 함께 승격합니다.

**Architecture:** `deploy/agent-orchestration/`의 API Deployment, migration, verifier, runner bootstrap, launcher bootstrap 참조를 동일한 API digest로 교체합니다. 기존 `promote-agent-orchestration-digests.rb`가 파일별 참조 수와 repository 전체 범위를 검증하므로 production checker를 새 규칙으로 복제하지 않고, self-test에 v0.9.0 exact assertion을 추가해 이 release 좌표를 고정합니다. runbook과 CHANGE_HISTORY에는 새 API digest와 7개 참조 rollback 좌표를 기록합니다.

**Tech Stack:** Kubernetes YAML, Ruby digest promotion/contract self-tests, Terraform contract tests, Markdown GitOps runbook.

## Global Constraints

- 대상 환경은 dev이며 Artifact Registry repository는 `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/`입니다.
- 현재 API image digest는 `sha256:e8886396c00a6c919cb28d49c7ad4de836b0de07a685da5db7a166384e72f066`입니다.
- 신규 API image digest는 `sha256:4d7d156cd08d1e5ebfa0c0283026d72ea7504dfaa40aa837edc917627b107c24`입니다.
- API 참조는 `api-deployment.yaml` 2개, `api-migration-job.yaml` 2개, `deployment-verification-job.yaml` 1개, `runner-deployment.yaml` 1개, `launcher-cronjob.yaml` 1개로 총 7개입니다.
- 기존 PR #592의 launcher/executor digest와 학습 환경 변수는 변경하지 않습니다.
- UI image, runner application image, resource request/limit, CronJob `suspend`, IAM/GCP resource, NetworkPolicy는 변경하지 않습니다.
- ArgoCD sync, launcher resume, 실험 발행과 ROC-AUC 검증은 이 작업에서 수행하지 않습니다.
- rollback은 launcher를 먼저 suspend하고 API 7개 참조를 직전 digest로 함께 되돌리며, launcher/executor 학습 배선과 snapshot bucket IAM은 유지합니다.

---

### Task 1: v0.9.0 API digest exact assertion 작성

**Files:**

- Modify: `scripts/test-promote-agent-orchestration-digests.rb`
- Test: `scripts/test-promote-agent-orchestration-digests.rb`

**Interfaces:**

- Consumes: `AgentOrchestrationDigestPromotion::ROOT`, `TARGETS`, `image_references`.
- Produces: 현재 저장소의 API repository 참조 7개가 v0.9.0 full reference인지 검증하는 self-test.

- [x] **Step 1: 실제 manifest의 v0.9.0 API 참조 assertion을 test에 먼저 추가한다**

`expect_equal` helper와 아래 exact constant를 추가하고, 기존 mutation test 실행 전
`check_v09_api_digest!`를 호출합니다. `Dir.glob`은 정렬된 manifest 순서를 사용하고,
API target의 모든 참조를 모아 7개가 동일한 새 full reference인지 검사합니다.

```ruby
V09_API_REF = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-api@sha256:4d7d156cd08d1e5ebfa0c0283026d72ea7504dfaa40aa837edc917627b107c24"

def expect_equal(expected, actual, description)
  return if expected == actual

  raise "#{description} 불일치: 기대=#{expected.inspect}, 실제=#{actual.inspect}"
end

def check_v09_api_digest!
  target = AgentOrchestrationDigestPromotion::TARGETS.fetch(:api)
  directory = File.join(AgentOrchestrationDigestPromotion::ROOT, "deploy/agent-orchestration")
  actual = Dir.glob(File.join(directory, "*.yaml")).sort.flat_map do |path|
    AgentOrchestrationDigestPromotion.image_references(
      File.read(path),
      target.fetch(:repository)
    )
  end
  expect_equal(Array.new(7, V09_API_REF), actual, "v0.9.0 API image references")
end
```

- [x] **Step 2: RED 상태를 확인한다**

Run:

```bash
docker run --rm -v "$PWD":/workspace -w /workspace ruby:3.4-alpine \
  ruby scripts/test-promote-agent-orchestration-digests.rb
```

Expected: 현재 `sha256:e888…` 참조가 v0.9.0 `sha256:4d7d…`와 다르다는 assertion으로
실패합니다. YAML parse 오류나 Ruby syntax 오류가 원인이면 먼저 test를 고칩니다.

### Task 2: API manifest 7개 참조 교체 및 promotion GREEN 확인

**Files:**

- Modify: `deploy/agent-orchestration/api-deployment.yaml`
- Modify: `deploy/agent-orchestration/api-migration-job.yaml`
- Modify: `deploy/agent-orchestration/deployment-verification-job.yaml`
- Modify: `deploy/agent-orchestration/runner-deployment.yaml`
- Modify: `deploy/agent-orchestration/launcher-cronjob.yaml`
- Modify: `scripts/check-experiment-launcher-manifest-contract.rb`
- Test: `scripts/check-agent-orchestration-timeout-contract.rb`
- Test: `scripts/check-agent-orchestration-deployment-verification.rb`

**Interfaces:**

- Consumes: Task 1의 `V09_API_REF` exact assertion과 기존 API repository target contract.
- Produces: API의 모든 runtime/bootstrap/verifier 참조가 신규 digest를 가리키는 manifest.

- [x] **Step 1: API image의 기존 full reference를 7곳에서 신규 full reference로 교체한다**

아래 old/new 문자열만 다섯 manifest에서 교체합니다.

```text
old: asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-api@sha256:e8886396c00a6c919cb28d49c7ad4de836b0de07a685da5db7a166384e72f066
new: asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-api@sha256:4d7d156cd08d1e5ebfa0c0283026d72ea7504dfaa40aa837edc917627b107c24
```

`check-experiment-launcher-manifest-contract.rb`의 launcher bootstrap expected image도
신규 API digest와 일치하도록 갱신합니다. API container command/env, bootstrap image 역할, UI/runner application image, resources,
NetworkPolicy와 launcher의 v0.9.0 학습 env는 수정하지 않습니다.

- [x] **Step 2: 전체 API 참조와 동등성 contract가 GREEN인지 확인한다**

Run:

```bash
docker run --rm -v "$PWD":/workspace -w /workspace ruby:3.4-alpine sh -lc '
  set -eu
  ruby scripts/check-agent-orchestration-timeout-contract.rb
  ruby scripts/check-agent-orchestration-deployment-verification.rb
  ruby scripts/test-promote-agent-orchestration-digests.rb
'
```

Expected: API timeout/deployment verification contract와 digest promotion self-test가
모두 exit 0이며, API 참조 수는 7개이고 모든 참조가 신규 full reference입니다.

### Task 3: 운영 문서와 변경 이력 갱신

**Files:**

- Modify: `docs/runbooks/2026-08-01-auto-research-experiment-job.md`
- Modify: `docs/CHANGE_HISTORY.md`

**Interfaces:**

- Consumes: Task 2의 신규 API digest와 기존 launcher/executor v0.9.0 provenance.
- Produces: API v0.9.0 운영 확인·rollback 좌표와 변경 범위 기록.

- [x] **Step 1: runbook의 v0.9.0 provenance를 API 포함으로 갱신한다**

기존 `Phase 2 학습 배선 v0.9.0 release provenance` 절의 API/UI/runner 범위 문장을
API v0.9.0 승격·UI/runner 유지로 바꾸고, 표에 API 신규 digest와 직전 `e888…`
rollback digest를 추가합니다. API 7개 참조를 함께 rollback하고 ArgoCD sync 뒤 live
Deployment·migration hook·verifier를 확인한다는 절차를 기록합니다.

- [x] **Step 2: CHANGE_HISTORY 최상단에 API 승격 결정을 추가한다**

API v0.9.0 digest, 7개 참조 원자 교체, UI/runner·resource/IAM/suspend 미변경,
launcher suspend 후 API 7개 참조를 함께 revert하는 rollback과 ArgoCD 후속 검증을
요약합니다.

### Task 4: 전체 검증과 커밋

**Files:**

- Test: all Ruby/shell lint workflow contracts
- Test: `terraform/admin/autoresearch-k8s` contract tests
- Test: actionlint

- [x] **Step 1: 전체 저장소 lint workflow 검사를 실행한다**

Run the exact repository lint commands below. Ruby commands run in a Ruby 3.4 container
because this workspace does not have a host Ruby runtime. Expected: all checks exit 0 and
Terraform reports 13 passed, 0 failed.

```bash
docker run --rm -v "$PWD":/workspace -w /workspace ruby:3.4-alpine sh -lc '
  set -eu
  ruby scripts/check-agent-orchestration-timeout-contract.rb
  ruby scripts/test-agent-orchestration-timeout-contract.rb
  ruby scripts/check-experiment-launcher-manifest-contract.rb
  ruby scripts/test-check-experiment-launcher-manifest-contract.rb
  ruby scripts/test-promote-agent-orchestration-digests.rb
  ruby scripts/check-agent-orchestration-deployment-verification.rb
  ruby scripts/test-check-agent-orchestration-deployment-verification.rb
  ruby scripts/test-environment-catalog.rb
'
scripts/check-oauth-email-allowlist.sh
scripts/test-check-oauth-email-allowlist.sh
scripts/check-raw-data-prefixes-contract.sh
scripts/test-check-raw-data-prefixes-contract.sh
scripts/check-drift-summary-grep-consistency.sh
scripts/test-check-drift-summary-grep-consistency.sh
terraform -chdir=terraform/admin/autoresearch-k8s init -backend=false -input=false
terraform -chdir=terraform/admin/autoresearch-k8s test
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest
```

- [x] **Step 2: 변경 범위와 old digest 잔류를 확인한다**

Run:

```bash
git diff --check
rg -n "e8886396c00a6c919cb28d49c7ad4de836b0de07a685da5db7a166384e72f066" deploy/agent-orchestration
rg -n "4d7d156cd08d1e5ebfa0c0283026d72ea7504dfaa40aa837edc917627b107c24" deploy/agent-orchestration
```

Expected: old digest scan has no output, new digest scan has exactly 7 API references.
Only the five manifests, promotion self-test, runbook, CHANGE_HISTORY, and approved
spec/plan are changed; launcher/executor training wiring remains intact.

- [x] **Step 3: 구현을 커밋한다**

```bash
git add deploy/agent-orchestration/api-deployment.yaml \
  deploy/agent-orchestration/api-migration-job.yaml \
  deploy/agent-orchestration/deployment-verification-job.yaml \
  deploy/agent-orchestration/runner-deployment.yaml \
  deploy/agent-orchestration/launcher-cronjob.yaml \
  scripts/check-experiment-launcher-manifest-contract.rb \
  scripts/test-promote-agent-orchestration-digests.rb \
  docs/runbooks/2026-08-01-auto-research-experiment-job.md \
  docs/CHANGE_HISTORY.md \
  docs/superpowers/plans/2026-08-08-api-v09-promotion.md
git commit -m "feat: API v0.9.0 digest 승격"
```
