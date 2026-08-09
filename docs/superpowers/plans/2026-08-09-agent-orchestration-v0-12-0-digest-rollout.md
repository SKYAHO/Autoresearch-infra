# Agent Orchestration v0.12.0 Digest Rollout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Autoresearch main `8750bce`에서 검증된 v0.12.0 Agent Orchestration의 executor·launcher와 함께 제공된 api·runner·ui immutable digest를 infra GitOps manifest와 정적 계약에 반영한다.

**Architecture:** `deploy/agent-orchestration/`의 허용된 image 참조만 새 digest로 원자적으로 갱신한다. 승격 스크립트의 self-test와 launcher manifest contract의 고정 기대값을 같은 release 좌표로 바꿔 부분 승격을 방지하고, 변경 이력에 source SHA와 rollback 좌표를 기록한다.

**Tech Stack:** Kubernetes YAML, Ruby/Psych contract checks, GitHub Actions/ArgoCD GitOps.

## Global Constraints

- executor와 launcher는 반드시 함께 반영한다. executor는 Codex #2·harness·report 게시를, launcher는 candidate-finalizer의 Codex Secret/CODEX_HOME wiring을 제공한다.
- API 7개, runner 1개, UI 1개 참조는 각각 지정된 v0.12.0 digest로 일관되게 갱신한다.
- 모든 image 참조는 고정 `repository@sha256:<64자리 소문자 hex>` 형식이어야 하며, IAM·Secret·Terraform state는 변경하지 않는다.
- 실제 클러스터 apply/ArgoCD sync는 PR merge 후 운영 절차에서 수행하며 이 PR에서는 정적 검증만 한다.

### Task 1: Release digest manifest 갱신

**Files:**
- Modify: `deploy/agent-orchestration/api-deployment.yaml`
- Modify: `deploy/agent-orchestration/api-migration-job.yaml`
- Modify: `deploy/agent-orchestration/deployment-verification-job.yaml`
- Modify: `deploy/agent-orchestration/launcher-cronjob.yaml`
- Modify: `deploy/agent-orchestration/runner-deployment.yaml`
- Modify: `deploy/agent-orchestration/ui-deployment.yaml`

- [x] **Step 1: 지정된 v0.12.0 repository@digest를 각 허용 참조에 적용한다.**
- [x] **Step 2: API 7곳과 단일 launcher/executor/runner/ui 참조 수를 확인한다.**

### Task 2: 정적 계약과 self-test 기대값 동기화

**Files:**
- Modify: `scripts/check-experiment-launcher-manifest-contract.rb`
- Modify: `scripts/test-check-experiment-launcher-manifest-contract.rb`
- Modify: `scripts/test-promote-agent-orchestration-digests.rb`

- [x] **Step 1: launcher contract의 launcher·executor·API bootstrap 기대값을 v0.12.0으로 갱신한다.**
- [x] **Step 2: fixture release pin과 promotion self-test의 expected API release를 v0.12.0으로 갱신한다.**
- [x] **Step 3: promotion script 및 launcher contract self-test를 실행해 부분 갱신과 digest 불일치 방어를 확인한다.**

### Task 3: 운영 문서와 변경 이력 갱신

**Files:**
- Modify: `docs/CHANGE_HISTORY.md`

- [x] **Step 1: v0.12.0 source SHA, 다섯 digest, executor·launcher 동시 배포 이유를 기록한다.**
- [x] **Step 2: rollback은 launcher suspend 후 직전 검증 digest 다섯 개를 함께 되돌리는 절차임을 기록한다.**

### Task 4: 통합 검증 및 PR 준비

- [x] **Step 1: Ruby self-test, YAML dry-run, digest 참조 수/일관성 검사를 실행한다.**
- [x] **Step 2: `git diff --check`와 변경 범위를 셀프 리뷰한다.**
- [ ] **Step 3: 커밋하고 Draft PR을 열어 이슈 #609를 연결한다.**
