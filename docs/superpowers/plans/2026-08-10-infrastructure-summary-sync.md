# 인프라 요약 문서 정합화 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 현재 `main`의 Terraform, ArgoCD, Kubernetes, GitHub Actions 구성을 `docs/INFRASTRUCTURE_SUMMARY.md`에 정확히 반영합니다.

**Architecture:** 기존 요약 문서 구조를 유지하면서 코드에서 추출한 인벤토리로 절대 표현과 수치를 교정합니다. configured 상태와 과거 apply/live 검증 상태를 분리하고, 독립 peer review로 누락과 과도한 단정을 다시 검사합니다.

**Tech Stack:** Markdown, Terraform HCL, Kubernetes YAML, GitHub Actions YAML, Git, ripgrep

## Global Constraints

- Terraform, Kubernetes, GCP 리소스와 workflow 동작은 변경하지 않습니다.
- 코드로 확인할 수 없는 apply/live 상태와 비용을 추정하지 않습니다.
- secret 값, Terraform state, `.tfvars` 실값을 읽거나 문서에 포함하지 않습니다.
- 현재 문서 구조와 한국어 격식체를 유지합니다.
- 변경 파일은 설계·계획 문서와 `docs/INFRASTRUCTURE_SUMMARY.md`로 제한합니다.

---

### Task 1: 코드 인벤토리와 문서 주장 대조

**Files:**
- Read: `docs/INFRASTRUCTURE_SUMMARY.md`
- Read: `terraform/envs/dev/*.tf`
- Read: `terraform/admin/*/*.tf`
- Read: `deploy/**/*`
- Read: `.github/workflows/*.yml`
- Read: `docs/CHANGE_HISTORY.md`

**Interfaces:**
- Consumes: 승인된 설계의 정본 우선순위와 전체 누락 재검토 기준
- Produces: root, Application, quota/LimitRange, DB, bucket, dashboard, 실행 경로의 확정 목록

- [x] **Step 1: 구조화 인벤토리를 추출합니다.**

  `rg`로 Terraform root, `ADMIN_ROOTS`, `google_storage_bucket`,
  `google_sql_database`, Kubernetes namespace/ResourceQuota/LimitRange,
  ArgoCD Application, dashboard와 workload kind를 추출합니다.

- [x] **Step 2: 절대 표현을 전수 검색합니다.**

  `~만`, `없음`, `전부`, `모든`, `고정`, `manual sync`, `미적용`, 숫자 개수와
  timeout을 검색하여 코드로 반증되는지 확인합니다.

- [x] **Step 3: configured/apply/live 판정표를 작성합니다.**

  저장소 코드로 확인되는 구성과 과거 문서에만 있는 운영 상태를 분리하며, live 확인이
  필요한 항목은 코드 사실로 덮어쓰지 않습니다.

### Task 2: 인프라 요약 문서 현행화

**Files:**
- Modify: `docs/INFRASTRUCTURE_SUMMARY.md`

**Interfaces:**
- Consumes: Task 1의 확정 인벤토리
- Produces: 현재 코드와 일치하고 live 상태를 별도로 표시한 운영 요약 문서

- [x] **Step 1: 상단 상태와 기본 정보를 수정합니다.**

  launcher 소유권, Phase 2/Stage 1 배선, active deadline/TTL, admin root 8개를
  반영합니다.

- [x] **Step 2: 운영 흐름과 주요 관리 대상을 수정합니다.**

  ARC 셀프 호스티드 Feast apply 주 경로와 WIF/GKE Job 롤백 경로, Agent
  Orchestration·ARC·실험 결과 저장 경계를 추가합니다.

- [x] **Step 3: Terraform/ArgoCD/Kubernetes 상세 구조를 수정합니다.**

  ArgoCD Application 9개와 6개 destination, 자동 sync 정책, admin root별 책임,
  quota/LimitRange namespace를 반영합니다.

- [x] **Step 4: 리소스와 데이터 계층을 수정합니다.**

  동적 ARC/CronJob 동작, Agent Orchestration workload 자원, dashboard 7개,
  Agent Orchestration DB 및 누락 GCS bucket을 반영합니다.

- [x] **Step 5: 문서 내부 중복 설명을 동일한 값으로 맞춥니다.**

  상단 요약, 상세 표, 보안 경계, 저장소 책임 경계에 반복되는 root/Application/sync
  설명이 서로 모순되지 않게 정리합니다.

### Task 3: 로컬 검증과 문서 커밋

**Files:**
- Verify: `docs/INFRASTRUCTURE_SUMMARY.md`
- Verify: `docs/superpowers/specs/2026-08-10-infrastructure-summary-sync-design.md`
- Verify: `docs/superpowers/plans/2026-08-10-infrastructure-summary-sync.md`

**Interfaces:**
- Consumes: Task 2의 문서 diff
- Produces: peer review가 가능한 검증 완료 커밋

- [x] **Step 1: 경로와 개수 계약을 재검증합니다.**

  문서의 root 8개, Application 9개, dashboard 7개, quota/LimitRange namespace,
  DB와 bucket 목록을 코드 추출 결과와 다시 대조합니다.

- [x] **Step 2: Markdown과 보안 범위를 검사합니다.**

  `git diff --check`, placeholder 검색, 민감 파일명·secret payload·state/tfvars 포함 여부를
  확인합니다.

- [x] **Step 3: 전체 diff를 셀프 리뷰합니다.**

  이슈 #615의 완료 조건, IAM/비용/리전 무변경, configured/apply/live 구분을 줄 단위로
  확인합니다.

- [x] **Step 4: 문서 변경을 커밋합니다.**

  커밋 메시지는 `docs: 인프라 요약을 현재 코드와 정합화`를 사용합니다.

### Task 4: 독립 peer review와 확정 검증

**Files:**
- Review: issue #615의 base SHA부터 현재 HEAD까지 전체 diff
- Modify if needed: peer review가 지적한 문서 파일

**Interfaces:**
- Consumes: Task 3의 검증 완료 커밋과 이슈 #615 완료 조건
- Produces: Critical/Important 발견 사항이 없는 최종 문서와 검증 증거

- [x] **Step 1: 독립 reviewer에게 전체 diff 검토를 요청합니다.**

  현재 코드와 문서의 수치·소유권·경로·configured/apply/live 구분, 누락, 보안상
  오해 가능성을 심각도 순으로 검토하도록 요청합니다.

- [x] **Step 2: reviewer 발견 사항을 기술적으로 검증합니다.**

  각 발견 사항을 실제 코드 줄과 대조하고 Critical/Important는 수정하며, 잘못된
  지적은 근거를 기록하고 반영하지 않습니다.

- [x] **Step 3: 수정이 있으면 별도 커밋합니다.**

  커밋 메시지는 `docs: 인프라 요약 peer review 반영`을 사용합니다.

- [ ] **Step 4: 최종 검증을 새로 실행합니다.**

  root/Application/dashboard/quota/DB/bucket 대조와 `git diff --check`, 보안 범위,
  `git status --short --branch`를 다시 실행해 결과를 확인합니다.
