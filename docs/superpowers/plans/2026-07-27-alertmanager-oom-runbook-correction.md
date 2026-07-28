# Alertmanager OOM 검증 Runbook 정정 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** OOMKilled 검증 절차를 `ContainerOOMKilled` metric 계약에 맞추고, Alertmanager SMTP의 실제 검증 상태를 운영 문서에 정확히 기록한다.

**Architecture:** 운영 runbook과 과거 실행 plan은 재시작된 container의 previous-termination metric을 전제로 `restartPolicy: Always`를 사용한다. 관측 전략은 실제로 확인한 OOMKilled·CrashLooping warning/resolved 이메일만 운영 완료로 기록하고, critical 전달은 route 구성과 별도로 미실증으로 남긴다.

**Tech Stack:** Markdown, Prometheus `kube_pod_container_status_last_terminated_reason`, Kubernetes Pod `restartPolicy`.

## Global Constraints

- `ContainerOOMKilled` 식, `for: 1m`, `severity: warning`은 변경하지 않는다.
- SMTP Secret payload, receiver 주소, 계정, recipient, endpoint를 문서나 diff에 기록하지 않는다.
- IAM, 네트워크, Helm values, PrometheusRule, live Kubernetes 리소스를 변경하지 않는다.
- `restartPolicy: Always` 검증 Pod는 OOMKilled 뒤 재시작해야 `last_terminated_reason` metric을 제공하며, resolved 검증 뒤 명시적으로 삭제한다.
- critical receiver route는 구성됐지만 critical 이메일을 별도로 실증하지 않았다고 기록한다.

---

## File Structure

- Modify: `docs/GRAFANA_OPERATIONS_RUNBOOK.md`
  - 현재 운영자가 복사해 따르는 OOM/해소 이메일 검증 계약을 제공한다.
- Modify: `docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md`
  - 과거 실행 plan의 직접 실행 가능한 OOM test Pod와 기대 결과를 현재 계약과 일치시킨다.
- Modify: `docs/OBSERVABILITY_STRATEGY.md`
  - Alertmanager SMTP의 배포 및 실제 검증 상태를 기록한다.

### Task 1: OOM 검증 Pod 계약 정정

**Files:**
- Modify: `docs/GRAFANA_OPERATIONS_RUNBOOK.md:241-250`
- Modify: `docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md:277-288,372-436`
- Test: static Markdown assertions only

**Interfaces:**
- Consumes: `ContainerOOMKilled` query `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1` and its confirmed `for: 1m` firing behavior.
- Produces: Every actionable OOM test instruction uses `restartPolicy: Always`, waits for `.status.containerStatuses[0].lastState.terminated.reason`, and explains why the Pod must restart before the rule can fire.

- [ ] **Step 1: Prove the stale contract exists before editing**

Run:

```bash
grep -n "restartPolicy: Never" docs/GRAFANA_OPERATIONS_RUNBOOK.md \
  docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md
```

Expected: the runbook validation step and the two executable Pod manifests in the old plan are reported.

- [ ] **Step 2: Replace the runbook validation step with the metric-compatible contract**

Replace runbook step 3 with:

```markdown
3. 이전 `alertmanager-oom-test` Pod가 없는 것을 확인한 뒤, `restartPolicy: Always`와 낮은 memory limit을 가진 dummy Pod로 OOMKilled를 발생시킨다. container가 재시작되어야 `kube_pod_container_status_last_terminated_reason` metric이 생기므로, `ContainerOOMKilled`가 pending을 거쳐 1분 뒤 firing한 뒤 warning 이메일을 수신한다. 이 Pod는 OOMKilled와 재시작을 반복하므로 OOM 검증에만 단독으로 사용한다.
```

Update steps 4 through 6 so the warning email 뒤 즉시 Pod를 삭제하고, `lastState` OOMKilled 확인 뒤 5분 안에 rule이 firing하지 않으면 삭제 후 조사하며, 이메일 전달 성공·실패와 관계없이 처음 `lastState` OOMKilled 확인 뒤 10분 안에는 Pod를 삭제한다고 명시한다. OOM Pod를 삭제한 뒤에만 CrashLooping test를 생성한다고 명시하고, 기본 `KubePodCrashLooping`의 `for: 15m` 전에 OOM test를 정리해 두 신호가 겹치지 않는다는 설명을 포함한다.

- [ ] **Step 3: Correct the historical plan’s prose and both executable manifests**

In the Task 2 validation contract, replace line 284 with the same `restartPolicy: Always` metric explanation from Step 2. Replace the stale Alerting and Alertmanager current-state rows at lines 301 and 307 with the verified warning/resolved wording from Task 2, including the qualification that critical email is not separately verified.

In both Pod specifications, replace only:

```yaml
restartPolicy: Never
```

with:

```yaml
restartPolicy: Always
```

Replace the stale expected result with:

```markdown
Expected: container restart 뒤 `ContainerOOMKilled`가 pending을 거쳐 one-minute rule delay 후 firing하며 warning 이메일이 도착한다.
```

In the executable `kubectl wait` command, replace `.status.containerStatuses[0].state.terminated.reason` with `.status.containerStatuses[0].lastState.terminated.reason` so the OOMKilled reason remains observable after the `restartPolicy: Always` container restarts. Prepend an idempotent `--ignore-not-found --wait=true` delete and absence assertion before applying the fixed-name Pod; both commands must fail closed with `exit 1` if cleanup fails or the Pod remains. Replace the preceding lifecycle prose so it waits for `lastState` for up to five minutes, treats the Pod as an OOM/restart loop rather than a one-shot series, deletes it immediately after the warning email or on firing failure, deletes it no later than ten minutes after first `lastState` OOMKilled even if SMTP delivery is delayed, and starts the CrashLooping test only after deletion.

Keep the explicit deletion and resolved-email contract unchanged.

- [ ] **Step 4: Run static contract checks**

Run:

```bash
! grep -n "restartPolicy: Never" docs/GRAFANA_OPERATIONS_RUNBOOK.md \
  docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md
! grep -n "wait until its terminated reason\|one-shot metric series\|아직 운영 중이 아님\|아직 운영하지 않음" \
  docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md
grep -n "restartPolicy: Always" docs/GRAFANA_OPERATIONS_RUNBOOK.md \
  docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md
grep -n "last_terminated_reason" docs/GRAFANA_OPERATIONS_RUNBOOK.md \
  docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md
grep -n "lastState.terminated.reason" \
  docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md \
  docs/superpowers/plans/2026-07-27-alertmanager-oom-runbook-correction.md
grep -n -- "--ignore-not-found --wait=true\|ten minutes\|10분" \
  docs/GRAFANA_OPERATIONS_RUNBOOK.md \
  docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md
grep -n "previous alertmanager-oom-test.*failed\|previous alertmanager-oom-test.*present\|exit 1" \
  docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md
```

Expected: the negative checks exit zero; the remaining output shows the new restart policy, metric explanation, verified current-state wording, post-restart `lastState.terminated.reason` selector, fail-closed stale-Pod cleanup, and absolute cleanup deadline in the changed documents.

### Task 2: Alertmanager 운영 상태 정정

**Files:**
- Modify: `docs/OBSERVABILITY_STRATEGY.md:25,44`
- Test: static Markdown assertions only

**Interfaces:**
- Consumes: verified #372 results: ArgoCD sync, OOMKilled warning/resolved email, and CrashLooping warning/resolved email.
- Produces: current-state text that distinguishes verified warning/resolved delivery from an untested critical email.

- [ ] **Step 1: Prove the stale pending-state text exists before editing**

Run:

```bash
grep -n "아직 운영 중이 아님\|아직 운영하지 않음" \
  docs/OBSERVABILITY_STRATEGY.md
```

Expected: the Alerting row and Alertmanager design-decision row are reported.

- [ ] **Step 2: Replace the Alerting current-state row**

Replace the Alerting row with:

```markdown
| Alerting | 기본 rule 설치됨. Alertmanager SMTP 이메일 설정을 ArgoCD manual sync했고, OOMKilled와 CrashLooping의 warning·resolved 이메일 전달을 실증했다. warning/critical receiver route는 구성됐지만 critical 이메일은 별도로 실증하지 않음 |
```

- [ ] **Step 3: Replace the Alertmanager design-decision row**

Replace the Alertmanager row with:

```markdown
| Alertmanager | 설치·운영 중. SMTP 이메일 설정은 ArgoCD manual sync 뒤 OOMKilled와 CrashLooping warning·resolved 이메일로 실증했다. warning/critical receiver route는 구성됐지만 critical 이메일은 별도로 실증하지 않음. 설정 payload는 ArgoCD 관리 대상이 아닌 `monitoring` namespace의 운영자 주입 Secret으로 관리 |
```

- [ ] **Step 4: Validate scope and sensitive-data absence**

Run:

```bash
! grep -n "아직 운영 중이 아님\|아직 운영하지 않음" \
  docs/OBSERVABILITY_STRATEGY.md
grep -n "critical 이메일은 별도로 실증하지 않음" \
  docs/OBSERVABILITY_STRATEGY.md
git diff --check
git diff --check -- docs/GRAFANA_OPERATIONS_RUNBOOK.md \
  docs/OBSERVABILITY_STRATEGY.md \
  docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md
git diff -- docs/GRAFANA_OPERATIONS_RUNBOOK.md \
  docs/OBSERVABILITY_STRATEGY.md \
  docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md
```

Expected: no stale operating-state wording remains, both rows preserve the critical-delivery qualification, no whitespace errors occur, and the diff contains no Secret payload, account, recipient, or endpoint.

- [ ] **Step 5: Commit the documentation correction**

```bash
git add docs/GRAFANA_OPERATIONS_RUNBOOK.md \
  docs/OBSERVABILITY_STRATEGY.md \
  docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md
```
