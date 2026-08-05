# GKE Deployment Digest 승격 PR 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 앱 릴리스가 검증한 GKE 이미지 digest를 infra Draft PR로 안전하게 승격한다.

**Architecture:** infra의 순수 Python 치환 도구가 manifest별 이미지·치환 개수를
fail-closed로 검증한다. 앱 release workflow가 한정된 GitHub App token으로 infra를
checkout해 도구를 실행하고 Draft PR만 만든다. ArgoCD sync·Terraform apply는 계속
사람의 운영 절차다.

**Tech Stack:** Python 3 표준 라이브러리, GitHub Actions, GitHub App token,
`peter-evans/create-pull-request@v8`, YAML manifest, Ruby contract test.

## Global Constraints

- mutable tag, PAT, 직접 main push, 자동 merge·sync·apply를 사용하지 않는다.
- 대상 이미지 URI는 dev GAR prefix와 SHA-256 digest 형식만 허용한다.
- API 참조 5곳은 모두 바뀌거나 하나도 바뀌지 않아야 한다.
- 동작 변경 문서와 second-brain 기록을 같은 작업에 포함한다.

---

### Task 1: Infra digest 승격 도구와 계약 테스트

**Files:**
- Create: `scripts/promote_gke_image_digests.py`
- Create: `scripts/test-promote-gke-image-digests.py`

- [ ] 실패 테스트로 유효 digest 5종이 정확한 manifest 위치만 치환하는지, API 다섯 참조가
      하나의 digest로 유지되는지 검증한다.
- [ ] 실패 테스트로 잘못된 registry·tag·대문자 digest·누락된 API 참조가 종료 코드 1로
      거부되는지 검증한다.
- [ ] 표준 라이브러리 기반 도구를 구현하고 테스트를 통과시킨다.

### Task 2: 운영 문서 갱신

**Files:**
- Modify: `docs/GITOPS_STRATEGY.md`
- Modify: `docs/TEAM_OPERATIONS_RUNBOOK.md`
- Modify: `docs/CHANGE_HISTORY.md`

- [ ] Draft PR 생성, 사람 merge, serving 자동 sync와 MLflow/Agent Orchestration의 수동
      후속 단계를 분리해 기록한다.
- [ ] GitHub App installation 범위와 실패 시 PAT 우회 금지 원칙, rollback 방법을 기록한다.

### Task 3: 앱 release workflow의 infra PR 생성

**Files (Autoresearch 저장소):**
- Modify: `.github/workflows/release.yml`

- [ ] 모든 GKE 대상 이미지 build job을 `needs`로 받는 promotion job을 추가한다.
- [ ] GitHub App token의 대상 repository를 `Autoresearch-infra` 하나로 제한한다.
- [ ] infra 도구에 image digest를 전달하고 지정 경로만 포함한 Draft PR을 만든다.
- [ ] `actionlint`로 workflow 문법과 권한 범위를 검증한다.

### Task 4: 전체 검증과 handoff

**Files:**
- Modify: `docs/superpowers/specs/2026-08-05-gke-digest-promotion-design.md`
- Modify: `docs/superpowers/plans/2026-08-05-gke-digest-promotion.md`

- [ ] Python 계약 테스트, Agent Orchestration timeout 계약 테스트, `actionlint`,
      `git diff --check`를 실행한다.
- [ ] 실제 release·PR 생성·merge·Terraform apply·ArgoCD sync는 실행하지 않고,
      GitHub App installation 대상 저장소 설정을 배포 전 사전 조건으로 명시한다.
