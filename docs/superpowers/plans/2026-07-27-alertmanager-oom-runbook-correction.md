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
3. OOM 검증을 시작할 때 현재 Kubernetes context를 저장하고 이후 OOM·CrashLooping 검증의 모든 `kubectl` 호출에 그 context를 고정한다. 이전 `alertmanager-oom-test` Pod를 삭제하고 Kubernetes API로 부재를 확인한다. 삭제 또는 부재 확인이 실패하면 새 Pod를 만들지 않고, 수동 삭제와 Kubernetes API 장애 조사를 수행한다. 그 뒤 `restartPolicy: Always`와 낮은 memory limit을 가진 dummy Pod로 OOMKilled를 발생시킨다. container가 재시작되어야 `kube_pod_container_status_last_terminated_reason` metric이 생기므로, `ContainerOOMKilled`가 pending을 거쳐 1분 뒤 firing한 뒤 warning 이메일을 수신한다. 이 Pod는 OOMKilled와 재시작을 반복하므로 OOM 검증에만 단독으로 사용한다.
```

Update steps 4 through 6 so the warning email 뒤 즉시 Pod를 삭제하고, `lastState` OOMKilled 확인 뒤 5분 안에 rule이 firing하지 않으면 삭제 후 조사하며, `lastState` 관측 뒤 8분에 watchdog cleanup을 시작해 최대 100초의 재시도 예산을 확보하고 API request 및 deletion wait를 각각 15초로 제한한 삭제를 세 번 시도한다고 명시한다. 세 시도가 모두 실패하면 오류를 기록하고 수동 삭제와 Kubernetes API 조사를 수행한다. OOM test 시작 시 현재 context를 저장해 이후 모든 OOM·CrashLooping `kubectl` 호출에 고정하고, CrashLooping test 생성 직전에 같은 context에서 OOM Pod의 부재를 재확인하며 실패 시 수동 삭제와 Kubernetes API 조사를 수행한다. 기본 `KubePodCrashLooping`의 `for: 15m` 전에 OOM test를 정리해 두 신호가 겹치지 않는다는 설명을 포함한다.

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

In the executable `kubectl wait` command, replace `.status.containerStatuses[0].state.terminated.reason` with `.status.containerStatuses[0].lastState.terminated.reason` so the OOMKilled reason remains observable after the `restartPolicy: Always` container restarts. Save `kubectl config current-context` before the first cleanup and use that context for every OOM and CrashLooping `kubectl` call. Prepend an idempotent `--ignore-not-found --wait=true` delete and absence assertion before applying the fixed-name Pod; both commands must fail closed with `exit 1` if cleanup fails, the absence API call fails, or the Pod remains, and report manual deletion plus Kubernetes API investigation. Install EXIT and HUP/INT/TERM traps before apply: HUP/INT/TERM cleanup must then exit nonzero so no later command creates a Pod without a watchdog, and EXIT cleanup failure must exit nonzero. Start a 480-second background watchdog only after the `lastState` wait succeeds; it must reserve up to 100 seconds for three `--timeout=15s --request-timeout=15s` deletion attempts with 5-second pauses. Because that watchdog runs in the interactive shell's background, its exhausted cleanup writes an error for immediate manual deletion and the later CrashLooping preflight independently blocks on OOM Pod absence/API failure; it cannot exit the parent shell. Do not stop the watchdog after normal cleanup because its later `--ignore-not-found` deletion applies only to the fixed OOM test Pod and avoids PID-reuse races. Before creating the CrashLooping Pod, fail closed if the saved context is unavailable, the OOM Pod absence API check fails, or the OOM Pod remains. Install independent EXIT and HUP/INT/TERM cleanup traps before creating the CrashLooping Pod, with `--request-timeout=15s` on its cleanup deletes. If the CrashLoopBackOff wait fails, delete the CrashLooping Pod before exiting nonzero; report manual deletion plus Kubernetes API investigation if that cleanup fails. Normal completion must delete the Pod and remove the traps. Replace the preceding lifecycle prose so it waits for `lastState` for up to five minutes, treats the Pod as an OOM/restart loop rather than a one-shot series, deletes it immediately after the warning email or on firing failure, starts bounded cleanup eight minutes after the observed `lastState` OOMKilled, reports failed cleanup for manual deletion and Kubernetes API investigation, and starts the CrashLooping test only after deletion.

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
grep -n -- "--ignore-not-found --wait=true\|sleep 480\|--timeout=15s\|--request-timeout=15s\|100초\|ten-minute\|10분" \
  docs/GRAFANA_OPERATIONS_RUNBOOK.md \
  docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md
grep -n "absence check failed\|on_oom_signal\|on_oom_exit\|sleep 480\|previous alertmanager-oom-test.*failed\|previous alertmanager-oom-test.*present\|exit 1" \
  docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md
grep -n "OOM_TEST_CONTEXT\|--context" \
  docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md
```

Expected: the negative checks exit zero; the remaining output shows the new restart policy, metric explanation, verified current-state wording, post-restart `lastState.terminated.reason` selector, fail-closed stale-Pod cleanup, fixed Kubernetes context, post-`lastState` 480-second watchdog with a 100-second retry budget, bounded API and deletion retries, and signal handlers that stop the workflow after cleanup.

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
