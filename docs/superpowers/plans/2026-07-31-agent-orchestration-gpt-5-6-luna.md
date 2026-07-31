# Agent Orchestration GPT-5.6 Luna 전환 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 공용 Codex OAuth Runner의 고정 기본 모델을 `gpt-5.6-luna`로 전환하고, 실제 채팅·PostgreSQL 저장까지 검증한다.

**Architecture:** GitOps manifest의 Runner `CODEX_MODEL`만 변경한다. 병합된 commit SHA를 Terraform admin apply로 Argo CD Application의 target revision에 반영하고, manual sync 후 내부 API 요청으로 Runner의 OAuth 모델 호환성과 DB 저장을 검증한다.

**Tech Stack:** Kubernetes Deployment/Service, Argo CD, Terraform admin apply workflow, Codex CLI OAuth, FastAPI, Cloud SQL PostgreSQL.

## Global Constraints

- `CODEX_MODEL`의 단일 출처는 `deploy/agent-orchestration/runner-deployment.yaml`이며, 직접 `kubectl set env` 또는 rollout restart를 사용하지 않는다.
- OAuth bootstrap 시크릿, Runner PVC, API·Runner 요청 토큰, Cloud SQL DB 권한·비밀번호, 이미지 digest, API JSON 계약은 변경하지 않는다.
- `gpt-5.6-luna`의 실제 Codex OAuth 호출 가능 여부는 post-sync 인증된 `/chat` 요청으로만 판정한다.
- Runner `/healthcheck`는 Codex 모델 호출을 수행하지 않는다. 지원되지 않는 모델명 또는 Codex 110초 timeout은 Runner가 Ready인 뒤 첫 `/chat`에서 API HTTP 502로 나타나며, LLM 응답 전 실패이므로 `chat_interactions` 행을 만들지 않는다.
- 이 내부 MVP에는 모델별 canary·traffic drain이 없다. sync 후 즉시 end-to-end gate를 실행하는 동안 알려진 다른 내부 호출자를 중지하고, gate 성공 또는 rollback 완료 전에는 정상 서비스로 선언하지 않는다.
- 실패 시 추가 요청을 중단하고, `gpt-5.3-codex-spark`로 되돌린 새 manifest commit을 같은 GitOps 절차로 배포한다.

---

### Task 1: Runner 모델 manifest를 GPT-5.6 Luna로 고정

**Files:**
- Modify: `deploy/agent-orchestration/runner-deployment.yaml:92-93`
- Create: `docs/superpowers/plans/2026-07-31-agent-orchestration-gpt-5-6-luna.md`

**Interfaces:**
- Consumes: Runner container의 `CODEX_MODEL` 환경 변수와 Codex CLI `-m` 전달 계약.
- Produces: 다음 Argo CD sync에서 `gpt-5.6-luna`로 재생성되는 Runner Pod.

- [x] **Step 1: 변경 전 모델 계약 확인**

Run:

```bash
rg -n -C 2 'name: CODEX_MODEL|gpt-5.3-codex-spark' deploy/agent-orchestration/runner-deployment.yaml
```

Expected: Runner container에 `CODEX_MODEL=gpt-5.3-codex-spark`가 정확히 한 번 존재한다.

- [x] **Step 2: 전역 모델 값만 변경**

Change the exact environment variable block to:

```yaml
- name: CODEX_MODEL
  value: gpt-5.6-luna
```

Do not alter any image digest, service account, volume, secret reference, timeout, resource, or NetworkPolicy field.

- [x] **Step 3: 변경 후 manifest 계약 검증**

Run:

```bash
rg -n -C 2 'name: CODEX_MODEL|gpt-5.3-codex-spark|gpt-5.6-luna' deploy/agent-orchestration/runner-deployment.yaml
kubectl apply --dry-run=client --filename deploy/agent-orchestration
ruby scripts/check-agent-orchestration-timeout-contract.rb
ruby scripts/test-agent-orchestration-timeout-contract.rb
git diff --check
```

Expected: `gpt-5.6-luna`만 나타나고, Kubernetes client dry-run·기존 deployment contract tests·diff whitespace check가 모두 성공한다.

- [x] **Step 4: 모델 전환 commit 생성**

Run:

```bash
git add deploy/agent-orchestration/runner-deployment.yaml docs/superpowers/plans/2026-07-31-agent-orchestration-gpt-5-6-luna.md
git commit -m 'feat: Agent Runner 모델을 GPT-5.6 Luna로 전환'
```

Expected: 하나의 모델 전환 commit이 생성되고 secret·OAuth payload·token은 포함되지 않는다. 설계 문서는 이전 설계 검토 checkpoint에서 별도 commit으로 이미 기록되어 있다.

### Task 2: GitOps 배포 및 end-to-end 판정

**Files:**
- Verify: `deploy/agent-orchestration/runner-deployment.yaml`
- Verify: `docs/runbooks/2026-07-30-agent-orchestration-gke.md`

**Interfaces:**
- Consumes: main에 병합된 Task 1 commit SHA, `AGENT_ORCHESTRATION_TARGET_REVISION`, enabled Application, internal API request token.
- Produces: `Synced`·`Healthy` Application, `gpt-5.6-luna` 모델명이 포함된 HTTP 201 chat response, PostgreSQL의 새 저장 행 ID.

- [ ] **Step 1: PR 검토·병합 후 target revision 적용**

Set the non-secret GitHub Actions Variable `AGENT_ORCHESTRATION_TARGET_REVISION` to the merged 40-character main commit SHA. Keep `AGENT_ORCHESTRATION_DEPLOYMENT_ENABLED=true`, run the reviewed admin apply workflow, and approve its protected deployment only after the plan succeeds. Before sync, verify the Application `spec.source.targetRevision` equals that exact SHA and inspect the Argo CD diff for that declared target. If either check fails, stop; do not issue a revision-overriding sync operation.

Expected: Terraform updates only the Argo CD Application source target revision; it does not create, replace, or widen OAuth, DB, or IAM resources.

- [ ] **Step 2: Argo CD manual sync 및 rollout 확인**

Run:

```bash
kubectl -n argocd patch applications.argoproj.io agent-orchestration --type merge --patch '{"operation":{"sync":{"prune":false}}}'
kubectl -n autoresearch rollout status deployment/agent-orchestration-runner --timeout=5m
kubectl -n autoresearch rollout status deployment/agent-orchestration-api --timeout=5m
```

Expected: Application is `Synced`/`Healthy`, both pods are Ready, and neither has a restart. The operation syncs only the previously verified `spec.source.targetRevision`; a direct `operation.sync.revision` is prohibited because it can leave the live cluster ahead of the fixed Application revision without self-heal.

- [ ] **Step 3: 내부 채팅·저장 gate 수행**

Use an ephemeral file to read `agent-orchestration-api-token` without printing its payload. Port-forward only the ClusterIP API service, send one authenticated JSON `POST /chat`, and inspect only HTTP status, `id`, `model`, and `latency_ms` from the response.

Expected: HTTP 201, a new integer `id`, `model=gpt-5.6-luna`, and `0 <= latency_ms < 120000`. The existing `CODEX_TIMEOUT_SEC=110` and API-to-Runner timeout=120 are separately checked by the deployment contract. A model rejection or execution over 110 seconds returns API HTTP 502 before persistence, so it has no `latency_ms` response or saved interaction row.

- [ ] **Step 4: 실패 시 GitOps 롤백**

If Runner readiness, HTTP 201, or the returned model check fails, stop further chat calls. Create a new reviewed commit that changes only the same field back to:

```yaml
- name: CODEX_MODEL
  value: gpt-5.3-codex-spark
```

Then apply that new main SHA through the same reviewed admin apply and Argo CD manual-sync sequence. Do not delete the OAuth PVC or rotate any secret as part of this rollback.
