# Alertmanager Slack 전환과 노이즈 제어 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Alertmanager의 Gmail 알림을 `#alerts-infra` Incoming Webhook으로 전환하고 namespace 범위, 그룹화, severity 억제, 반복 주기, OOM 사건 의미를 정정한다.

**Architecture:** kube-prometheus-stack은 운영자 주입 `alertmanager-slack-config`의 전체 `alertmanager.yaml`을 읽는다. Git은 Secret 이름과 사건형 PrometheusRule, payload를 출력하지 않는 생성·검증 runbook만 관리한다. root null route 아래 workload namespace allowlist와 cluster critical allowlist를 분리하고 warning/critical receiver가 같은 channel-bound webhook을 사용한다.

**Tech Stack:** kube-prometheus-stack 87.12.1, Alertmanager native `slack_configs`, Prometheus/PromQL, Helm, ArgoCD manual sync, Kubernetes Secret

## Global Constraints

- 논리 채널은 `#alerts-infra` 하나이고 Slack App의 channel-bound Incoming Webhook을 사용한다.
- workload namespace allowlist는 정확히 `airflow|autoresearch|mlflow|monitoring`이다.
- root receiver는 `null`이며 info와 관리 namespace는 Slack으로 보내지 않는다.
- group key는 정확히 `alertname`, `namespace`; `group_wait=30s`, `group_interval=1m`이다.
- warning은 멘션 없이 `repeat_interval=12h`, critical은 firing일 때만 `<!here>`와 `repeat_interval=4h`다.
- warning/critical receiver 모두 `send_resolved: true`이고 resolved에는 mention이 없다.
- 같은 `alertname`, `namespace`의 critical은 warning을 억제한다.
- webhook URL, 실제 channel ID, Secret payload는 Git, Terraform state, command line, 로그, PR 본문에 남기지 않는다.
- Terraform, IAM, GCP resource, public endpoint, monitoring NetworkPolicy는 변경하지 않는다.
- Slack App/Webhook/Secret/ArgoCD sync/test alert/OOM Pod는 별도 운영 승인 전에는 실행하지 않는다.

---

## File Structure

| 경로 | 책임 |
| --- | --- |
| `deploy/monitoring/values.yaml` | `alertmanager-slack-config` 참조와 사건형 `ContainerOOMKilled` rule |
| `docs/GRAFANA_OPERATIONS_RUNBOOK.md` | 전체 Alertmanager config의 비노출 생성·검증·교체·smoke·rollback |
| `docs/OBSERVABILITY_STRATEGY.md` | Slack 운영 채널과 대상·반복·억제 정책 |
| `docs/CHANGE_HISTORY.md` | SMTP→Slack 결정과 운영 교훈 요약 |

### Task 1: 사건형 OOM rule과 Slack config Secret 참조

**Files:**
- Modify: `deploy/monitoring/values.yaml`
- Test: rendered Alertmanager and PrometheusRule manifests

**Interfaces:**
- Consumes: 운영자 주입 `monitoring/alertmanager-slack-config`의 `alertmanager.yaml`.
- Produces: `Alertmanager.spec.configSecret=alertmanager-slack-config`.
- Produces: 최근 5분 restart 증가와 OOM 종료 이유를 결합한 `ContainerOOMKilled`.

- [ ] **Step 1: 변경 전 chart 상태를 캡처한다**

Run:

```bash
helm dependency build deploy/monitoring
helm template autoresearch-monitoring deploy/monitoring \
  --namespace monitoring > /tmp/monitoring-before-406.yaml
rg -n "configSecret: alertmanager-smtp-config" /tmp/monitoring-before-406.yaml
rg -n 'kube_pod_container_status_last_terminated_reason.*OOMKilled' \
  /tmp/monitoring-before-406.yaml
! rg -n "alertmanager-slack-config|restarts_total" \
  /tmp/monitoring-before-406.yaml
```

Expected: SMTP Secret과 상태형 OOM 식은 있고 Slack Secret/restart 식은 없다.

- [ ] **Step 2: 바뀔 계약의 정적 실패 검사를 먼저 실행한다**

Run:

```bash
rg -n "configSecret: alertmanager-slack-config" deploy/monitoring/values.yaml
rg -n "increase\\(|kube_pod_container_status_restarts_total" \
  deploy/monitoring/values.yaml
```

Expected: 두 명령 모두 match가 없어 nonzero.

- [ ] **Step 3: Alertmanager config Secret 참조를 바꾼다**

`alertmanagerSpec.configSecret`을 정확히 다음 값으로 변경하고 comment도 Slack
payload 소유권을 설명하도록 갱신한다.

```yaml
configSecret: alertmanager-slack-config
```

- [ ] **Step 4: OOM rule을 사건형 식으로 교체한다**

기존 rule 이름, `for: 1m`, `severity: warning`은 유지하고 expr을 다음으로
교체한다.

```yaml
expr: |
  (
    increase(
      kube_pod_container_status_restarts_total{
        namespace=~"airflow|autoresearch|mlflow|monitoring"
      }[5m]
    ) > 0
  )
  and on (namespace, pod, container)
  (
    kube_pod_container_status_last_terminated_reason{
      namespace=~"airflow|autoresearch|mlflow|monitoring",
      reason="OOMKilled"
    } == 1
  )
```

annotation summary는 “최근 OOM restart가 발생함”이라는 사건 의미로 수정한다.

- [ ] **Step 5: chart를 렌더링해 정확한 변경을 검증한다**

Run:

```bash
helm lint deploy/monitoring
helm template autoresearch-monitoring deploy/monitoring \
  --namespace monitoring > /tmp/monitoring-after-406.yaml
rg -n "configSecret: alertmanager-slack-config" \
  /tmp/monitoring-after-406.yaml
rg -n "kube_pod_container_status_restarts_total|reason=.OOMKilled" \
  /tmp/monitoring-after-406.yaml
! rg -n "configSecret: alertmanager-smtp-config" \
  /tmp/monitoring-after-406.yaml
git diff --check
```

Expected: Helm exit 0, Slack Secret 한 건, restart/OOM 식 한 건, SMTP 참조 0건.

- [ ] **Step 6: chart 변경만 커밋한다**

```bash
git add deploy/monitoring/values.yaml
git commit -m "feat: Alertmanager Slack 설정 참조 추가"
```

### Task 2: Alertmanager Slack Secret 생성·검증 runbook

**Files:**
- Modify: `docs/GRAFANA_OPERATIONS_RUNBOOK.md`

**Interfaces:**
- Consumes: mode 0600 `slack-webhook-url`과 `slack-channel` 입력 파일.
- Produces: `monitoring/alertmanager-slack-config` with exactly one `alertmanager.yaml` key.
- Produces: root null, three child routes, two Slack receivers, one inhibit rule.

- [ ] **Step 1: 기존 SMTP section의 교체 범위를 확인한다**

Run:

```bash
rg -n "^## Alertmanager SMTP|^### Secret|^### Cluster|alertmanager-smtp-config" \
  docs/GRAFANA_OPERATIONS_RUNBOOK.md
```

Expected: 기존 생성, 검증, cluster smoke, rollback 범위가 모두 표시된다.

- [ ] **Step 2: Slack 입력 파일 검증 절차를 작성한다**

runbook은 shell history에 값을 넣지 않고 mode 0600 디렉터리의 두 파일을 읽는다.
Python generator는 다음 key 규칙을 강제한다.

```python
required = {"slack-webhook-url", "slack-channel"}
for name in required:
    value = (root / name).read_bytes()
    if not value or value.endswith((b"\n", b"\r")):
        raise SystemExit(f"Invalid Slack input file: {name}")
```

webhook은 `https`, hostname `hooks.slack.com`, path가 `/services/`로 시작하는지만
검증하고 URL 자체는 출력하지 않는다. channel은 빈 값과 CR/LF만 거부하며 실제
값은 config Secret 안에만 둔다.

- [ ] **Step 3: 전체 Alertmanager config generator를 작성한다**

생성 config는 다음 route 구조를 정확히 포함한다.

```yaml
route:
  receiver: "null"
  group_by: [alertname, namespace]
  group_wait: 30s
  group_interval: 1m
  routes:
    - receiver: slack-critical
      matchers:
        - alertname=~"KubeNodeNotReady|KubeNodeUnreachable|KubeAPIDown|KubeSchedulerDown|KubeControllerManagerDown|KubeletDown"
      repeat_interval: 4h
    - receiver: slack-critical
      matchers:
        - severity="critical"
        - namespace=~"airflow|autoresearch|mlflow|monitoring"
      repeat_interval: 4h
    - receiver: slack-warning
      matchers:
        - severity="warning"
        - namespace=~"airflow|autoresearch|mlflow|monitoring"
      repeat_interval: 12h
```

receiver는 `null`, `slack-warning`, `slack-critical` 세 개다. 두 slack config는
같은 `global.slack_api_url`, operator 입력 channel, `send_resolved: true`를
사용한다. 두 receiver는 첫 alert의 summary 500자, description 1,000자,
Pod/container 각 200자와 전체 alert 건수를 직접 렌더링한다. 외부 문자열은
`reReplaceAll "[<>&@]" ""`로 Slack 제어문자를 제거한다. critical text만
다음 정적 mention 조건을 앞에 포함한다.

```yaml
text: >-
  {{ if eq .Status "firing" }}<!here> {{ end }}
  {{ $first := index .Alerts 0 }}
  *Summary:* {{ printf "%.500s" (reReplaceAll "[<>&@]" "" $first.Annotations.summary) }}
```

두 receiver 모두 `link_names` 자동 파싱을 사용하지 않으며 warning에는 mention
token을 넣지 않는다.

- [ ] **Step 4: inhibit rule과 attachment field를 문서화한다**

```yaml
inhibit_rules:
  - source_matchers: ['severity="critical"']
    target_matchers: ['severity="warning"']
    equal: [alertname, namespace]
```

attachment는 resolved=good, critical=danger, warning=warning 색상과 Status,
Severity, Namespace, Alert count, Started at을 표시한다. label/annotation은
외부 입력으로 취급해 `<`, `>`, `&`, `@`를 제거하고 webhook 값은 template에
넣지 않는다. 안전한 내부 URL을 generator가 검증하지 않으므로 `title_link`는
기본적으로 생성하지 않는다.

- [ ] **Step 5: no-output config 검증과 create-or-replace 절차를 작성한다**

runbook은 다음 순서를 사용한다.

```bash
amtool check-config "$ALERTMANAGER_SECRET_DIR/alertmanager.yaml"
kubectl create secret generic alertmanager-slack-config \
  --namespace monitoring \
  --from-file=alertmanager.yaml="$ALERTMANAGER_SECRET_DIR/alertmanager.yaml" \
  --dry-run=client -o json
```

dry-run JSON은 mode 0600 파일로만 저장하고 stdout에 출력하지 않는다. 기존
Secret이 있으면 `resourceVersion`을 보존해 replace하며, 확인은
name/namespace/type/resourceVersion/key count metadata만 출력한다.

- [ ] **Step 6: SMTP rollback을 유지한다**

`alertmanager-smtp-config`는 Slack live smoke 전까지 삭제하지 않고, Helm의
configSecret을 이전 이름으로 되돌리는 절차를 남긴다. 두 receiver를 동시에
활성화하는 dual delivery는 금지한다.

- [ ] **Step 7: 문서 정적 검증을 실행한다**

Run:

```bash
rg -n "alertmanager-slack-config|slack-warning|slack-critical|repeat_interval: (12h|4h)" \
  docs/GRAFANA_OPERATIONS_RUNBOOK.md
rg -n "severity=.critical|severity=.warning|equal:.*alertname.*namespace" \
  docs/GRAFANA_OPERATIONS_RUNBOOK.md
! rg -n "https://hooks\\.slack\\.com/services/[A-Z0-9]" \
  docs/GRAFANA_OPERATIONS_RUNBOOK.md
git diff --check
```

Expected: routing 계약이 있고 실제 webhook URL은 없다.

- [ ] **Step 8: runbook을 커밋한다**

```bash
git add docs/GRAFANA_OPERATIONS_RUNBOOK.md
git commit -m "docs: Alertmanager Slack 운영 절차 추가"
```

### Task 3: 관측 전략과 변경 이력 갱신

**Files:**
- Modify: `docs/OBSERVABILITY_STRATEGY.md`
- Modify: `docs/CHANGE_HISTORY.md`

**Interfaces:**
- Consumes: Tasks 1-2의 실제 채널, 범위, 반복, 억제, OOM lifecycle.
- Produces: 현재 운영 상태와 결정 근거의 정본.

- [ ] **Step 1: SMTP current-state 문구가 존재함을 확인한다**

Run:

```bash
rg -n "SMTP|이메일|Slack 등 즉시 알림" \
  docs/OBSERVABILITY_STRATEGY.md
```

Expected: Alerting 현재 상태와 Alertmanager 결정 행이 표시된다.

- [ ] **Step 2: 전략 문서를 Slack 전환 상태로 갱신한다**

Alerting 행과 Alertmanager 행에 `#alerts-infra`, Incoming Webhook,
namespace allowlist, warning/critical 반복, resolved, inhibit를 기록한다.
실제 live smoke 전에는 “구성 예정/로컬 검증”으로, smoke 후에는 검증한
severity와 lifecycle만 “운영 중”으로 바꾼다.

- [ ] **Step 3: 변경 이력에 운영 결정을 요약한다**

`2026-07-29: Alertmanager Slack 전환 (#406)` 항목에 다음을 기록한다.

- 메일 노이즈 원인
- channel-bound webhook 선택과 Bot Token 미도입 이유
- `alertname+namespace` grouping과 critical→warning inhibit
- 사건형 OOM 식의 restart window 의미
- SMTP rollback과 Secret 비노출
- 비용/IAM/Terraform 영향 없음

- [ ] **Step 4: 문서 검증을 실행한다**

Run:

```bash
rg -n "#alerts-infra|12시간|4시간|inhibit|OOM" \
  docs/OBSERVABILITY_STRATEGY.md docs/CHANGE_HISTORY.md
! rg -n "https://hooks\\.slack\\.com/services/[A-Z0-9]|xox[baprs]-" \
  docs/OBSERVABILITY_STRATEGY.md docs/CHANGE_HISTORY.md
git diff --check
```

Expected: 결정이 문서화되고 credential 실값과 whitespace 오류가 없다.

- [ ] **Step 5: 전략 문서를 커밋한다**

```bash
git add docs/OBSERVABILITY_STRATEGY.md docs/CHANGE_HISTORY.md
git commit -m "docs: Slack 인프라 알림 전략 반영"
```

### Task 4: 로컬 통합 검증

**Files:**
- Verify: `deploy/monitoring/values.yaml`
- Verify: `docs/GRAFANA_OPERATIONS_RUNBOOK.md`
- Verify: `docs/OBSERVABILITY_STRATEGY.md`
- Verify: `docs/CHANGE_HISTORY.md`

**Interfaces:**
- Consumes: Tasks 1-3 전체 변경.
- Produces: Secret 주입 전 리뷰 가능한 GitOps revision.

- [ ] **Step 1: chart dependency와 lint/template을 새로 실행한다**

Run:

```bash
helm dependency build deploy/monitoring
helm lint deploy/monitoring
helm template autoresearch-monitoring deploy/monitoring \
  --namespace monitoring > /tmp/monitoring-406-final.yaml
```

Expected: Helm 명령 모두 exit 0.

- [ ] **Step 2: 렌더링 계약을 검사한다**

Run:

```bash
rg -n "configSecret: alertmanager-slack-config" \
  /tmp/monitoring-406-final.yaml
rg -n "alert: ContainerOOMKilled|kube_pod_container_status_restarts_total|reason=.OOMKilled" \
  /tmp/monitoring-406-final.yaml
! rg -n "configSecret: alertmanager-smtp-config|hooks\\.slack\\.com|xox[baprs]-" \
  /tmp/monitoring-406-final.yaml
```

Expected: Slack Secret과 사건형 rule만 렌더링되고 SMTP 참조/credential은 없다.

- [ ] **Step 3: 전체 diff의 범위와 민감정보를 검사한다**

Run:

```bash
git diff --check
git status --short
git diff HEAD~4 -- deploy/monitoring/values.yaml \
  docs/GRAFANA_OPERATIONS_RUNBOOK.md \
  docs/OBSERVABILITY_STRATEGY.md docs/CHANGE_HISTORY.md
rg -n "hooks\\.slack\\.com/services/[A-Z0-9]|xox[baprs]-|BEGIN .*PRIVATE KEY" \
  deploy docs || true
```

Expected: #406 파일만 변경되고 실제 secret이 없다.

### Task 5: 승인된 live smoke와 SMTP 정리

**Files:**
- Modify: `docs/GRAFANA_OPERATIONS_RUNBOOK.md`
- Modify: `docs/OBSERVABILITY_STRATEGY.md`
- Modify: `docs/CHANGE_HISTORY.md`
- Move: `docs/superpowers/plans/2026-07-29-alertmanager-slack-noise-control.md` → `docs/superpowers/archive/2026-07-29-alertmanager-slack-noise-control.md`

**Interfaces:**
- Consumes: 사용자 승인, 실제 webhook, cluster 접근, Task 4 GitOps revision.
- Produces: 실증된 Slack 운영 상태와 제거 가능한 SMTP Secret.

- [ ] **Step 1: live 변경 범위를 명시해 승인을 받는다**

Slack App/Webhook 생성, `alertmanager-slack-config` create-or-replace, ArgoCD
manual sync, warning/critical test alert, OOM Pod 생성·삭제가 모두 승인됐는지
확인한다. 승인 전에는 이후 step을 실행하지 않는다.

- [ ] **Step 2: 현재 rule 이름과 firing 상태를 read-only로 캡처한다**

runbook 명령으로 현재 context를 고정하고 namespace/severity 분포, cluster
critical allowlist alertname이 실제 chart에 존재하는지 확인한다. 불일치가 있으면
Secret을 만들기 전에 spec/runbook allowlist를 수정하고 다시 로컬 검증한다.

- [ ] **Step 3: Slack Secret을 주입하고 ArgoCD sync한다**

Task 2의 no-output generator와 `amtool check-config`를 사용한다. sync 뒤
Alertmanager Ready, config reload 성공, Slack API 오류 부재만 확인하며 payload는
출력하지 않는다.

- [ ] **Step 4: warning과 critical lifecycle을 검증한다**

warning test는 무멘션 firing/resolved, critical test는 firing `@here` 한 번과
무멘션 resolved를 확인한다. 같은 alertname/namespace의 warning+critical을
겹쳐 critical firing 중 warning이 억제되는지 확인한다.

- [ ] **Step 5: OOM 사건 lifecycle을 검증한다**

고정 context와 `restartPolicy: Always` 검증 Pod를 사용한다. 첫 OOM firing,
restart 증가가 멈춘 뒤 resolved, 새 OOM 뒤 재-firing을 확인한다. watchdog과
bounded delete를 사용해 Pod를 즉시 정리하고 API로 부재를 확인한다.

- [ ] **Step 6: SMTP Secret 제거 여부를 승인받는다**

최소 한 운영 관찰 구간이 통과한 뒤에만 `alertmanager-smtp-config` 삭제를 별도로
승인받는다. 승인되지 않으면 참조되지 않는 rollback Secret으로 유지한다.

- [ ] **Step 7: 문서를 실증 결과로 갱신하고 plan을 archive한다**

실제로 확인한 severity/lifecycle만 운영 중으로 기록한다.

```bash
mkdir -p docs/superpowers/archive
git mv docs/superpowers/plans/2026-07-29-alertmanager-slack-noise-control.md \
  docs/superpowers/archive/2026-07-29-alertmanager-slack-noise-control.md
git add docs
git commit -m "docs: Alertmanager Slack 실증 결과 반영"
```

## Rollback Checkpoint

Slack config load나 전달이 실패하면 같은 승인 창에서 Helm configSecret을
`alertmanager-smtp-config`로 되돌려 sync한다. 사건형 OOM 식만 실패하면 그 rule만
이전 식으로 되돌리되 상태형 반복 노이즈가 다시 생긴다는 사실을 운영 로그에
남긴다.
