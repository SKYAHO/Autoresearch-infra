# Alertmanager Slack 전환과 알림 노이즈 제어 설계 (#406)

> 작성: 2026-07-29 | 성격: 운영 알림 경로 변경
> 관련 설계:
> `docs/superpowers/specs/2026-07-27-alertmanager-smtp-oomkilled-design.md`

## 배경

현재 Alertmanager는 전 클러스터의 `warning`과 `critical`을 Gmail로 보내고,
`alertname`, `namespace`, `pod` 단위로 그룹화해 같은 장애도 Pod마다 메일이
나뉜다. warning과 critical 사이 억제가 없고 두 등급 모두 4시간마다 반복되며
resolved 메일까지 추가되어 팀 inbox 노이즈가 크다.

`ContainerOOMKilled`는
`kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1`을
상태로 감시한다. 마지막 종료 이유가 오래 남으면 새 OOM 사건이 없어도 계속
firing할 수 있어 사건 알림 의미와 맞지 않는다.

## 결정 요약

| 항목 | 결정 |
| --- | --- |
| 전송 방식 | Slack App의 `#alerts-infra` 전용 Incoming Webhook |
| 렌더링 | Alertmanager native `slack_configs` attachment |
| warning | 멘션 없음, 12시간 반복 |
| critical | firing일 때만 `@here`, 4시간 반복 |
| resolved | 멘션 없이 즉시 전송 |
| workload 범위 | `airflow`, `autoresearch`, `mlflow`, `monitoring` namespace |
| cluster 범위 | 운영 중단 alertname allowlist를 원본 severity와 무관하게 critical receiver로 승격 |
| 그룹화 | `alertname`, `namespace` |
| 억제 | 같은 `alertname`, `namespace`의 critical이 firing하면 warning 억제 |
| OOM | 최근 restart 증가와 마지막 OOM 종료 이유를 결합한 사건형 규칙 |
| Secret | 전체 `alertmanager.yaml`을 운영자 주입 Secret으로 관리 |

Bot Token은 사용하지 않는다. 현재 요구사항은 단방향 카드 전송이며 메시지
수정, thread, interactive action, 사용자별 DM이 필요하지 않다.

## 라우팅 범위

root receiver는 계속 `null`로 둔다. 다음 allowlist에 들어온 alert만 Slack으로
전달한다.

### Namespace-scoped workload

`namespace=~"airflow|autoresearch|mlflow|monitoring"`이면서
`severity=warning|critical`인 alert를 대상으로 한다.

- `airflow`: scheduler와 batch orchestration
- `autoresearch`: serving과 application workload
- `mlflow`: 모델 registry/tracking
- `monitoring`: Prometheus, Alertmanager, Grafana 자체

`kube-system`, `gke-managed-system`, `argocd`, `argo-rollouts`, `vault`,
`elastic`, 일회성 관리 namespace와 `info` 등급은 보내지 않는다. 범위를
추가할 때는 운영 소유자와 대응 방법이 있는지 먼저 확인하고 allowlist를
명시적으로 갱신한다.

### Cluster-scoped availability

namespace label이 없는 node/control-plane 장애를 strict namespace filter로
버리지 않도록 별도 critical receiver route를 둔다. 기본 chart에서 node
unavailable rule은 `severity=warning`이므로 이 allowlist는 원본 severity와
무관하게 Slack의 critical receiver로 승격한다. 의도한 범주는 node unavailable과
Kubernetes control-plane target down이며, 구현 시 설치된 chart의 렌더링된
rule에서 실제 alertname을 대조해 다음 allowlist만 사용한다.

```text
KubeNodeNotReady
KubeNodeUnreachable
KubeAPIDown
KubeSchedulerDown
KubeControllerManagerDown
KubeletDown
```

설치된 chart에 없는 이름은 추가 규칙을 새로 만들지 않는다. 반대로 렌더링된
기본 rule의 이름이 다르면 의미가 같은지 검토한 뒤 설계 문서와 allowlist를
함께 갱신한다.

## Alertmanager route

route 순서는 더 구체적인 critical부터 warning 순으로 둔다.

1. cluster-scoped availability alertname allowlist → `slack-critical`
2. namespace allowlist + `severity=critical` → `slack-critical`
3. namespace allowlist + `severity=warning` → `slack-warning`
4. 나머지 → root `null`

route 공통값:

```yaml
group_by: [alertname, namespace]
group_wait: 30s
group_interval: 1m
```

`group_interval`을 1분으로 둬 firing group 변경과 resolved를 준실시간으로
전달한다. Slack API 오류나 Alertmanager scheduling에 따라 정확히 1분을
보장하지는 않는다. 두 receiver의 `slack_configs`에는
`send_resolved: true`를 각각 둔다.

route branch별 반복값:

```text
slack-warning: repeat_interval 12h
slack-critical: repeat_interval 4h
```

Pod label을 group key에서 제거해 같은 namespace의 동일 alert를 한 사건으로
묶는다. 개별 Pod와 container는 attachment field 또는 본문에 제한된 개수만
표시하고 나머지는 건수로 요약한다.

## Inhibit rule

다음 조건으로 critical이 같은 사건의 warning을 억제한다.

```yaml
source_matchers:
  - severity="critical"
target_matchers:
  - severity="warning"
equal:
  - alertname
  - namespace
```

critical이 resolved되면 계속 firing 중인 warning이 다시 routing될 수 있다.
severity label이 없거나 다른 alertname인 신호를 임의로 억제하지 않는다.

## Slack attachment

Alertmanager native Slack attachment를 사용한다. `slack_config.channel`이
필수인 버전에서는 Secret 안에 webhook에 연결된 동일 채널을 지정하되, 실제
전송 대상은 channel-bound Incoming Webhook을 기준으로 하며 channel override에
의존하지 않는다.

- fallback: 환경, 상태, severity, alertname, namespace를 포함한 한 줄
- color: warning은 노랑, critical은 빨강, resolved는 초록
- title: `[FIRING|RESOLVED] <alertname>`
- fields: Severity, Namespace, Alert count, Started at
- text: annotation summary/description을 길이 제한 후 표시
- link: Alertmanager 또는 Grafana의 내부 URL이 안전한 경우에만 추가

`slack-critical`의 text는 `.Status == "firing"`일 때만 `<!here>`를 한 번
포함한다. resolved attachment에는 mention을 넣지 않는다. label/annotation은
외부 입력으로 취급해 `<`, `>`, `&`, `@`를 제거하고 `link_names` 자동 파싱을
사용하지 않는다. webhook URL, credential, 원본 Secret payload는 template나
로그에 넣지 않는다.

Incoming Webhook은 실제 channel ID에 고정한다. 논리 채널명
`#alerts-infra`는 문서화할 수 있지만 webhook URL과 실제 channel ID는 Git,
Terraform state, CLI 인수, 로그, PR 본문에 기록하지 않는다.

## 사건형 OOM 규칙

`ContainerOOMKilled`는 최근 restart가 증가했고 마지막 종료 이유가
OOMKilled인 container만 잡는다.

```promql
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

- `for: 1m`, `severity: warning`을 유지한다.
- restart가 더 늘지 않으면 5분 window가 지난 뒤 조건이 false가 되어
  resolved된다.
- resolved 뒤 새 OOM restart가 생기면 다시 firing한다.
- restart를 하지 않는 one-shot container의 과거 terminated state까지
  잡는 규칙은 이번 범위에 포함하지 않는다.

구현 전에 `promtool check rules`와 실제 kube-state-metrics label set으로 vector
matching을 검증한다. 검증용 Pod는 `restartPolicy: Always`를 사용한다.

## Secret 운영 계약

새 Secret 이름은 `monitoring/alertmanager-slack-config`이고
`alertmanager.yaml` 키 하나만 가진다. 이 파일 안에 global 설정, route,
inhibit rule, receiver와 Incoming Webhook URL을 함께 둔다.

Prometheus Operator가 참조하는 전체 config가 secret이므로 Git의 Helm values에는
Secret 이름만 들어간다. ArgoCD는 Secret을 생성하거나 prune하지 않는다.

운영 절차는 다음을 지킨다.

1. mode 0600 임시 디렉터리에서 payload를 생성한다.
2. webhook 값의 비어 있음과 trailing CR/LF를 값 출력 없이 검증한다.
3. `amtool check-config`로 로컬 설정을 검사한다.
4. Kubernetes Secret은 delete/recreate가 아니라 resourceVersion을 보존한
   create-or-replace로 갱신한다.
5. metadata와 Alertmanager reload 상태만 출력하고 payload는 출력하지 않는다.

기존 `alertmanager-smtp-config`는 Slack smoke가 끝날 때까지 rollback용으로
유지한다. 두 Secret을 동시에 receiver로 활성화해 이중 전송하지 않는다.

## 네트워크, 비용, 책임 경계

`monitoring` namespace에는 deny-by-default NetworkPolicy가 없고 cluster는
Cloud NAT를 통해 외부 HTTPS를 사용할 수 있으므로 이번 변경에 Terraform,
방화벽, IAM, public endpoint를 추가하지 않는다. 실제 전송 실패 시 DNS, NAT,
Slack endpoint 접근과 webhook 유효성을 순서대로 확인한다.

비용이 발생하는 신규 GCP 리소스는 없다. Slack App 설치, webhook 생성,
Kubernetes Secret 변경, ArgoCD sync, 검증 Pod 생성은 외부 운영 상태를
바꾸므로 각각 실행 전에 명시적 승인을 받는다.

## 변경 대상

| 경로 | 변경 |
| --- | --- |
| `deploy/monitoring/values.yaml` | Slack config Secret 참조와 사건형 OOM rule |
| `docs/GRAFANA_OPERATIONS_RUNBOOK.md` | Secret 생성·교체·smoke·rollback |
| `docs/OBSERVABILITY_STRATEGY.md` | Slack 채널, 범위, 반복·억제 정책 |
| `docs/CHANGE_HISTORY.md` | SMTP에서 Slack으로 전환한 운영 결정 요약 |

Terraform과 Airflow DAG는 변경하지 않는다.

## 전환과 검증

1. 현재 firing alert와 namespace/severity label 분포를 read-only로 확인한다.
2. chart를 template해 cluster availability allowlist의 실제 alertname과
   severity를 대조한다.
3. `alertmanager-slack-config`를 로컬 생성하고 `amtool check-config`를 통과시킨다.
4. Helm lint/template과 Secret 값 미노출 검사를 수행한다.
5. 운영자 승인 뒤 Secret 주입과 ArgoCD manual sync를 수행한다.
6. warning test alert로 무멘션 firing과 resolved를 확인한다.
7. critical test alert로 firing `@here`와 무멘션 resolved를 확인한다.
8. 두 severity가 겹치는 test alert로 inhibit 동작을 확인한다.
9. OOM 검증 Pod로 firing → resolved → 새 OOM firing lifecycle을 확인하고
   Pod를 즉시 삭제한다.
10. 최소 한 scheduled 운영 구간을 관찰한 뒤 SMTP Secret 제거를 별도 승인한다.

로컬 검증:

```text
amtool check-config <redacted-local-alertmanager.yaml>
promtool check rules <rendered-rules.yaml>
helm lint deploy/monitoring
helm template <release> deploy/monitoring
git diff --check
```

검증 출력과 diff에 webhook URL, Secret data, 실제 channel ID가 없는지 별도로
확인한다.

## 롤백

1. Slack 전송 또는 config reload가 실패하면 ArgoCD sync를 중단한다.
2. `deploy/monitoring/values.yaml`의 config Secret 참조를 기존
   `alertmanager-smtp-config`로 되돌린다.
3. Alertmanager가 SMTP config를 정상 reload하고 test alert를 전달하는지
   확인한다.
4. `alertmanager-slack-config`는 더 이상 참조되지 않음을 확인한 뒤에만
   제거한다.
5. OOM 식만 문제면 기존 상태형 식으로 일시 복구하되 장기 반복 노이즈를
   운영자에게 명시한다.

## 범위 밖

- Slack Bot Token, thread, message update, interactive action
- PagerDuty·전화 등 별도 on-call escalation
- External Secrets Operator와 Secret Manager 자동 동기화
- monitoring namespace deny-by-default NetworkPolicy
- Airflow DagRun과 모델 이벤트 알림
- expected-success-missing 감지
