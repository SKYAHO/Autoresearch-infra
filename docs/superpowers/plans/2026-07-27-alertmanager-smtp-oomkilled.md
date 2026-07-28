# Alertmanager SMTP 알림과 OOMKilled 감지 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kubernetes workload가 OOMKilled 또는 CrashLooping 상태일 때 Alertmanager가 warning/critical 이메일과 복구 이메일을 발송하게 한다.

**Architecture:** kube-prometheus-stack Alertmanager는 `monitoring/alertmanager-smtp-config`의 전체 `alertmanager.yaml`을 기존 config Secret으로 사용한다. PrometheusRule은 umbrella chart values의 `additionalPrometheusRulesMap`으로 렌더링한다. SMTP 값은 운영자 주입 Secret에만 저장하고, chart values와 문서는 Secret 이름과 안전한 생성 절차만 가진다.

**Tech Stack:** Helm umbrella chart, kube-prometheus-stack 87.12.1, Prometheus Operator, Alertmanager, ArgoCD manual sync, Kubernetes Secret, PrometheusRule.

## Global Constraints

- 모든 chart 값은 `deploy/monitoring/values.yaml`의 `kube-prometheus-stack:` 아래에 둔다.
- `monitoring/alertmanager-smtp-config`는 `alertmanager.yaml` 키 하나만 가진 운영자 주입 Secret이다.
- SMTP host, account, password, sender, recipients, Secret payload, 실제 endpoint를 Git, Terraform state, command line 인수, 로그, PR 본문에 남기지 않는다.
- email receiver는 `severity=warning|critical`만 전달하고 `info`는 `null` receiver로 폐기한다.
- 이메일은 발화와 해소에 모두 전송한다(`send_resolved: true`).
- 새 GCP 리소스, IAM 권한, public endpoint, External Secrets Operator, Secret Manager 동기화, monitoring NetworkPolicy 변경은 범위 밖이다.
- ArgoCD sync와 OOM test Pod 생성은 실제 클러스터 변경이므로 실행 직전에 사용자 승인을 받는다.

---

## File Structure

| 경로 | 책임 |
| --- | --- |
| `deploy/monitoring/values.yaml` | 외부 Alertmanager config Secret 참조와 OOMKilled PrometheusRule 선언 |
| `docs/GRAFANA_OPERATIONS_RUNBOOK.md` | Alertmanager SMTP Secret의 비노출 생성·교체·검증·롤백 절차 |
| `docs/OBSERVABILITY_STRATEGY.md` | Alertmanager 이메일 채널의 현재 운영 상태와 책임 경계 |

### Task 1: Alertmanager와 OOMKilled 규칙 선언

**Files:**
- Modify: `deploy/monitoring/values.yaml:102-103`
- Modify: `deploy/monitoring/values.yaml:after kube-prometheus-stack.alertmanager`
- Test: rendered `PrometheusRule` and `Alertmanager` manifests from `helm template`

**Interfaces:**
- Consumes: 운영자가 `monitoring` namespace에 생성한 `alertmanager-smtp-config` Secret의 `alertmanager.yaml` key.
- Produces: Alertmanager CR의 `spec.configSecret=alertmanager-smtp-config`와 `ContainerOOMKilled` PrometheusRule.

- [ ] **Step 1: Capture the current rendered behavior before changing values**

Run:

```bash
helm dependency build deploy/monitoring
helm template kube-prometheus-stack deploy/monitoring --namespace monitoring > /tmp/monitoring-before-372.yaml
! grep -q "ContainerOOMKilled" /tmp/monitoring-before-372.yaml
! grep -q "configSecret: alertmanager-smtp-config" /tmp/monitoring-before-372.yaml
```

Expected: no matches. This proves the new rule and existing config Secret reference are absent before the change.

- [ ] **Step 2: Configure the existing Alertmanager config Secret**

Replace the current Alertmanager block with this block under `kube-prometheus-stack:`.

```yaml
  alertmanager:
    enabled: true
    # SMTP payload와 Alertmanager route는 Git이 아닌 운영자 주입 Secret에 둔다.
    # Secret이 없으면 sync 전에 먼저 주입해야 하며 ArgoCD는 이를 관리하거나 prune하지 않는다.
    alertmanagerSpec:
      useExistingSecret: true
      configSecret: alertmanager-smtp-config
```

- [ ] **Step 3: Add the OOMKilled rule in the chart-supported rule map**

Add this sibling block under `kube-prometheus-stack:` after the `alertmanager` block.

```yaml
  additionalPrometheusRulesMap:
    container-oom-killed:
      groups:
        - name: autoresearch.container-termination
          rules:
            - alert: ContainerOOMKilled
              expr: kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
              for: 1m
              labels:
                severity: warning
              annotations:
                summary: Container terminated due to OOMKilled
```

- [ ] **Step 4: Render and assert the changed resources**

Run:

```bash
helm lint deploy/monitoring
helm template kube-prometheus-stack deploy/monitoring --namespace monitoring > /tmp/monitoring-after-372.yaml
grep -n "configSecret: alertmanager-smtp-config" /tmp/monitoring-after-372.yaml
grep -n "alert: ContainerOOMKilled" /tmp/monitoring-after-372.yaml
```

Expected: `helm lint` succeeds; the first `grep` finds the Alertmanager spec reference and the second finds exactly one custom alert rule.

- [ ] **Step 5: Inspect the rendered diff for unintended monitoring changes**

Run:

```bash
diff -u /tmp/monitoring-before-372.yaml /tmp/monitoring-after-372.yaml
git diff -- deploy/monitoring/values.yaml
```

Expected: only Alertmanager config Secret selection and one `ContainerOOMKilled` PrometheusRule are introduced. Existing Grafana, Prometheus PVC, resource, and node placement settings remain unchanged.

- [ ] **Step 6: Commit the chart configuration**

```bash
git add deploy/monitoring/values.yaml
git commit -m "feat: Alertmanager SMTP 설정 참조 추가"
```

### Task 2: Alertmanager SMTP Secret 운영 절차 문서화

**Files:**
- Modify: `docs/GRAFANA_OPERATIONS_RUNBOOK.md:after Google OAuth section`
- Modify: `docs/OBSERVABILITY_STRATEGY.md:19-26, 32-44`
- Test: temporary config validation and `kubectl` dry-run command paths described in the runbook

**Interfaces:**
- Consumes: `airflow/airflow-email-alerts` with the eight existing SMTP keys and an operator allowed to read `airflow` and create/update `monitoring` Secrets.
- Produces: `monitoring/alertmanager-smtp-config` with exactly the `alertmanager.yaml` key consumed by Task 1.

- [ ] **Step 1: Add the Alertmanager operation section and state its ownership boundary**

Add a `## Alertmanager SMTP 알림 (#372)` section to `docs/GRAFANA_OPERATIONS_RUNBOOK.md` stating all of the following:

```markdown
- Airflow scheduler의 DAG/task 실패 이메일과 Alertmanager의 Kubernetes workload 장애 이메일은 서로 대체하지 않는다.
- Alertmanager는 `monitoring/alertmanager-smtp-config`의 `alertmanager.yaml`만 읽고, ArgoCD는 이 Secret을 관리하거나 prune하지 않는다.
- `airflow/airflow-email-alerts`를 namespace를 넘어 직접 참조할 수 없으므로 두 Secret은 같은 SMTP 값을 별도로 보관한다.
- SMTP 회전 시 두 Secret을 같은 비공개 입력으로 함께 교체한다.
```

- [ ] **Step 2: Document the no-output source Secret validation and config generation command**

Add the following procedure. It reads the existing Airflow Secret into mode-0600 temporary files, rejects missing/empty/newline-terminated values, requires the current STARTTLS/587 mode, and writes only a local `alertmanager.yaml` file.

```bash
umask 077
ALERTMANAGER_SECRET_DIR="$(mktemp -d "${TMPDIR:-/tmp}/alertmanager-smtp-config.XXXXXX")"
trap 'rm -f -- "$ALERTMANAGER_SECRET_DIR"/*; rmdir "$ALERTMANAGER_SECRET_DIR"' EXIT

kubectl -n airflow get secret airflow-email-alerts -o json > "$ALERTMANAGER_SECRET_DIR/source-secret.json"

python - "$ALERTMANAGER_SECRET_DIR" <<'PY'
import base64
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = {
    "smtp-host", "smtp-port", "smtp-starttls", "smtp-ssl",
    "smtp-user", "smtp-password", "smtp-mail-from", "alert-recipients",
}
source = json.loads((root / "source-secret.json").read_text())
actual = set(source.get("data", {}))
if actual != expected:
    raise SystemExit(
        f"Secret key mismatch: missing={sorted(expected - actual)}, "
        f"extra={sorted(actual - expected)}"
    )

values = {}
for key in sorted(expected):
    value = base64.b64decode(source["data"][key])
    if not value:
        raise SystemExit(f"Secret value is empty: {key}")
    if value.endswith((b"\n", b"\r")):
        raise SystemExit(f"Secret value has trailing CR/LF: {key}")
    values[key] = value.decode("utf-8")

if values["smtp-port"] != "587":
    raise SystemExit("Alertmanager SMTP requires the approved STARTTLS port: 587")
if values["smtp-starttls"].lower() != "true" or values["smtp-ssl"].lower() != "false":
    raise SystemExit("Alertmanager SMTP requires smtp-starttls=true and smtp-ssl=false")

def scalar(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"

config = f"""global:
  resolve_timeout: 5m
  smtp_smarthost: {scalar(values['smtp-host'] + ':' + values['smtp-port'])}
  smtp_from: {scalar(values['smtp-mail-from'])}
  smtp_auth_username: {scalar(values['smtp-user'])}
  smtp_auth_password: {scalar(values['smtp-password'])}
  smtp_require_tls: true
route:
  receiver: "null"
  group_by: [alertname, namespace, pod]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - receiver: email
      matchers:
        - severity=~\"warning|critical\"
receivers:
  - name: "null"
  - name: email
    email_configs:
      - to: {scalar(values['alert-recipients'])}
        send_resolved: true
"""
(root / "alertmanager.yaml").write_text(config)
print("Alertmanager config generated without displaying SMTP values.")
PY
```

- [ ] **Step 3: Document local config validation, atomic Secret update, and metadata-only checks**

Add these commands immediately after the generator. Validate the locally generated
`alertmanager.yaml` before any Kubernetes Secret create or replace mutation. Only if
that validation succeeds, atomically create or replace the Secret; inspect only its
metadata afterward. These commands never display the payload.

```bash
docker run --rm \
  --volume "$ALERTMANAGER_SECRET_DIR:/work:ro" \
  quay.io/prometheus/alertmanager:v0.33.1 \
  amtool check-config /work/alertmanager.yaml

kubectl -n monitoring get secret alertmanager-smtp-config --ignore-not-found -o json \
  > "$ALERTMANAGER_SECRET_DIR/existing-alertmanager-secret.json"

python - "$ALERTMANAGER_SECRET_DIR" <<'PY'
import base64
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
config = (root / "alertmanager.yaml").read_bytes()
if not config:
    raise SystemExit("Generated Alertmanager config is empty")

secret = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {
        "name": "alertmanager-smtp-config",
        "namespace": "monitoring",
    },
    "type": "Opaque",
    "data": {"alertmanager.yaml": base64.b64encode(config).decode("ascii")},
}
existing_path = root / "existing-alertmanager-secret.json"
if existing_path.stat().st_size:
    existing = json.loads(existing_path.read_text())
    resource_version = existing.get("metadata", {}).get("resourceVersion")
    if not resource_version:
        raise SystemExit("Existing Secret has no resourceVersion")
    secret["metadata"]["resourceVersion"] = resource_version

(root / "alertmanager-secret.json").write_text(json.dumps(secret))
PY

if [ -s "$ALERTMANAGER_SECRET_DIR/existing-alertmanager-secret.json" ]; then
  kubectl -n monitoring replace -f "$ALERTMANAGER_SECRET_DIR/alertmanager-secret.json"
else
  kubectl -n monitoring create -f "$ALERTMANAGER_SECRET_DIR/alertmanager-secret.json"
fi

kubectl -n monitoring get secret alertmanager-smtp-config \
  -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,TYPE:.type,RESOURCE-VERSION:.metadata.resourceVersion,CREATED:.metadata.creationTimestamp
```

State directly below the command that `amtool` must succeed without copying its input or output into a ticket, terminal recording, or log. The create-or-replace input contains only the `alertmanager.yaml` key, preserves `resourceVersion` for an existing Secret, and must not use delete-and-recreate. The post-update command displays metadata columns only; do not display or copy payloads.

- [ ] **Step 4: Document cluster validation, alert resolution, and rollback**

Add the following validation contract, not a production command with live values:

```markdown
1. ArgoCD manual sync 전에 diff에서 `alertmanager-smtp-config` 참조와 `ContainerOOMKilled` 규칙만 추가되는지 확인한다.
2. sync 뒤 Alertmanager StatefulSet이 Ready인지와 Alertmanager log에 config parse error가 없는지 확인한다.
3. `restartPolicy: Always`와 낮은 memory limit을 가진 dummy Pod로 OOMKilled를 발생시킨다. container가 재시작되어야 `kube_pod_container_status_last_terminated_reason` metric이 생기므로, `ContainerOOMKilled`가 pending을 거쳐 1분 뒤 firing한 뒤 warning 이메일을 수신한다.
4. dummy Pod를 삭제해 metric이 해소된 뒤 resolved 이메일을 수신한다.
5. 기존 CrashLooping 조건도 warning/critical receiver로 전달되는지 확인한다.
6. 검증 Pod는 즉시 삭제한다.
```

Add this rollback contract:

```markdown
config 오류 또는 메일 전달 실패 시 ArgoCD sync를 중단하거나 values를 기존 chart 생성 config로 되돌려 `null` receiver를 복원한다. Alertmanager가 `alertmanager-smtp-config`를 더 이상 참조하지 않는 것을 확인한 뒤에만 Secret을 삭제한다.
```

- [ ] **Step 5: Update the observability strategy status**

In `docs/OBSERVABILITY_STRATEGY.md`, replace the current Alerting row with this current-state statement.

```markdown
| Alerting | 기본 rule 설치됨. Alertmanager SMTP 이메일 설정을 ArgoCD manual sync했고, OOMKilled와 CrashLooping의 warning·resolved 이메일 전달을 실증했다. warning/critical receiver route는 구성됐지만 critical 이메일은 별도로 실증하지 않음 |
```

Replace the Alertmanager design decision with this statement.

```markdown
| Alertmanager | 설치·운영 중. SMTP 이메일 설정은 ArgoCD manual sync 뒤 OOMKilled와 CrashLooping warning·resolved 이메일로 실증했다. warning/critical receiver route는 구성됐지만 critical 이메일은 별도로 실증하지 않음. 설정 payload는 ArgoCD 관리 대상이 아닌 `monitoring` namespace의 운영자 주입 Secret으로 관리 |
```

Remove the completed “Alertmanager 알림 채널은 Slack, email, GitHub issue 중 무엇을 사용할지?” question from the future confirmation list. Keep Slack and other immediate channels as a future scope, not a prerequisite for email operation.

- [ ] **Step 6: Validate the documentation change**

Run:

```bash
git diff --check
git diff -- docs/GRAFANA_OPERATIONS_RUNBOOK.md docs/OBSERVABILITY_STRATEGY.md
```

Expected: no whitespace errors; the diff contains no SMTP payload, account, recipient, or endpoint.

- [ ] **Step 7: Commit the operational documentation**

```bash
git add docs/GRAFANA_OPERATIONS_RUNBOOK.md docs/OBSERVABILITY_STRATEGY.md
git commit -m "docs: Alertmanager 이메일 운영 절차 추가"
```

### Task 3: Pre-deployment review and live alert delivery verification

**Files:**
- Modify: none unless Task 1 or Task 2 verification identifies a defect.
- Test: ArgoCD manual sync, Alertmanager readiness/logs, OOMKilled email, resolved email, existing CrashLooping email.

**Interfaces:**
- Consumes: merged chart and runbook changes, an approved `monitoring/alertmanager-smtp-config` Secret, manual ArgoCD sync approval.
- Produces: evidence that Alertmanager receives and routes Kubernetes alerts independently of Airflow scheduler availability.

- [ ] **Step 1: Obtain explicit approval before changing the live cluster**

Ask for approval to perform all of the following: create/update the `monitoring/alertmanager-smtp-config` Secret, manually sync the monitoring ArgoCD Application, and create/delete one disposable OOM test Pod. Do not proceed on implicit approval for local code changes alone.

- [ ] **Step 2: Inspect the ArgoCD diff and sync manually**

Run:

```bash
argocd app diff monitoring
argocd app sync monitoring
argocd app wait monitoring --sync --health --timeout 300
```

Expected: the pre-sync diff has the Alertmanager config Secret reference and
`ContainerOOMKilled` PrometheusRule only. It must not delete a PVC or change a
nodeSelector, Grafana credential, or unrelated monitoring resource. The wait command
ends with Application `monitoring` in `Synced` and `Healthy` state.

- [ ] **Step 3: Verify Alertmanager config loading without printing payloads**

Run:

```bash
kubectl -n monitoring rollout status statefulset/alertmanager-kube-prometheus-stack-alertmanager --timeout=5m
if kubectl -n monitoring logs statefulset/alertmanager-kube-prometheus-stack-alertmanager -c alertmanager --since=10m | grep -Ei "(error|failed).*(config|reload)|(config|reload).*(error|failed)"; then
  exit 1
fi
```

Expected: StatefulSet rollout succeeds. Investigate any config parse or reload error before creating the OOM test Pod. Do not paste Secret content from logs or mounted files.

- [ ] **Step 4: Create a disposable OOMKilled test Pod after approval**

First remove any prior `alertmanager-oom-test` Pod and confirm that it is absent.
Apply this exact Pod, wait up to five minutes until its
`lastState.terminated.reason` is `OOMKilled`, then wait for the
`ContainerOOMKilled` warning email. The Pod repeats OOMKilled and restart while
it exists, so delete it immediately after the warning email arrives. If the rule
does not fire within five minutes after `lastState` records OOMKilled, delete the
Pod and investigate Prometheus rule evaluation and Alertmanager config. Regardless
of email delivery, delete the Pod no later than ten minutes after first observing
`lastState.terminated.reason=OOMKilled`. Do not create the CrashLooping test Pod
until this Pod is deleted; that prevents the OOM test Pod from reaching the default
`KubePodCrashLooping` rule's `for: 15m` period.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: alertmanager-oom-test
  namespace: monitoring
  labels:
    app.kubernetes.io/name: alertmanager-oom-test
spec:
  restartPolicy: Always
  containers:
    - name: allocate-memory
      image: python:3.12-alpine
      command: ["python", "-c", "memory = bytearray(64 * 1024 * 1024); print(len(memory))"]
      resources:
        limits:
          memory: 16Mi
        requests:
          memory: 16Mi
```

Run:

```bash
if ! kubectl -n monitoring delete pod alertmanager-oom-test \
  --ignore-not-found --wait=true --timeout=1m; then
  printf '%s\n' 'previous alertmanager-oom-test cleanup failed' >&2
  exit 1
fi
if [ -n "$(kubectl -n monitoring get pod alertmanager-oom-test \
  --ignore-not-found -o name)" ]; then
  printf '%s\n' 'previous alertmanager-oom-test is still present' >&2
  exit 1
fi

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: alertmanager-oom-test
  namespace: monitoring
  labels:
    app.kubernetes.io/name: alertmanager-oom-test
spec:
  restartPolicy: Always
  containers:
    - name: allocate-memory
      image: python:3.12-alpine
      command: ["python", "-c", "memory = bytearray(64 * 1024 * 1024); print(len(memory))"]
      resources:
        limits:
          memory: 16Mi
        requests:
          memory: 16Mi
EOF

kubectl -n monitoring wait \
  --for=jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'=OOMKilled \
  pod/alertmanager-oom-test --timeout=5m
```

Expected: container restart 뒤 `ContainerOOMKilled`가 pending을 거쳐 one-minute rule delay 후 firing하며 warning 이메일이 도착한다.
After the alert email arrives, run:

```bash
kubectl -n monitoring delete pod alertmanager-oom-test
```

Expected: pod deletion removes the metric series and a resolved email follows
Alertmanager grouping timing.

- [ ] **Step 5: Verify existing CrashLooping routing and record non-sensitive evidence**

Create this disposable pod. The pinned chart's `KubePodCrashLooping` rule has
`severity: warning` and `for: 15m`, so leave the pod in `CrashLoopBackOff` until
the warning email is received.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: alertmanager-crashloop-test
  namespace: monitoring
  labels:
    app.kubernetes.io/name: alertmanager-crashloop-test
spec:
  containers:
    - name: exit-with-error
      image: busybox:1.36
      command: ["sh", "-c", "exit 1"]
      resources:
        limits:
          memory: 16Mi
        requests:
          memory: 16Mi
EOF

kubectl -n monitoring wait \
  --for=jsonpath='{.status.containerStatuses[0].state.waiting.reason}'=CrashLoopBackOff \
  pod/alertmanager-crashloop-test --timeout=10m
```

Expected: after the rule's 15-minute pending period, one `KubePodCrashLooping`
warning email arrives through the same receiver. Record only alert name, severity,
received timestamp, resolved timestamp, and cleanup completion in the PR or runbook
execution note. Do not record SMTP endpoint, addresses, credentials, Secret data, or
email body content. After the email arrives, run:

```bash
kubectl -n monitoring delete pod alertmanager-crashloop-test
```

- [ ] **Step 6: Re-run local static checks and review the final diff**

Run:

```bash
helm lint deploy/monitoring
git diff --check
git status --short
git log --oneline -3
```

Expected: Helm lint and diff check succeed; only intended chart and documentation files are changed or committed.

## Plan Self-Review

### Spec coverage

- Independent Kubernetes-level notification when Airflow scheduler is unavailable: Task 1 Alertmanager config reference and PrometheusRule, Task 3 live delivery check.
- Secret payload remains outside Git and Terraform: Task 2 private-file generator and explicit diff review.
- warning/critical only and resolved notifications: Task 2 generated route, Task 3 receipt checks.
- Existing CrashLooping alerts remain routed: Task 1 preserves default rules, Task 3 verifies delivery.
- OOMKilled-specific alert: Task 1 declares the one-minute `ContainerOOMKilled` rule.
- Documentation and rollback: Task 2 updates both operational documents and includes config rollback.
- No new controller, IAM, public endpoint, or GCP resource: Global Constraints and Task 1 scope.

### Placeholder scan

The plan contains no TBD, TODO, deferred implementation, or unspecified file path. Live cluster actions are deliberately approval-gated because they mutate shared infrastructure.

### Interface consistency

All chart configuration references `monitoring/alertmanager-smtp-config` and its sole `alertmanager.yaml` key. All custom rule references use `ContainerOOMKilled`, warning severity, and a one-minute evaluation duration.
