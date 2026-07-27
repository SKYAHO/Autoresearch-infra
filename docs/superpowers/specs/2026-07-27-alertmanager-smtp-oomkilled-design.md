# Alertmanager SMTP 알림과 OOMKilled 감지 설계 (#372)

> 작성: 2026-07-27 | 성격: 운영 알림 경로 추가
> 목적: Airflow scheduler 자체가 중단돼도 Kubernetes 관측 계층이 OOMKilled와
>       CrashLooping을 독립적으로 이메일로 알린다.
> 범위: dev `monitoring` namespace의 kube-prometheus-stack Alertmanager와
>       PrometheusRule. Airflow DAG 콜백 및 SMTP 제공자는 변경하지 않는다.

## 배경

Airflow의 DAG/task 실패 이메일은 scheduler가 실행한다. 따라서 scheduler가
OOMKilled되면 그 프로세스는 자기 장애의 콜백과 이메일 발송을 신뢰성 있게 수행할 수
없다. Prometheus 기본 규칙은 `KubePodCrashLooping` 같은 pod 장애를 감지하지만,
현재 Alertmanager route의 receiver가 `null`이므로 발화한 알림이 모두 폐기된다.

이 변경은 Airflow의 메일을 대체하지 않는다. Airflow는 작업 실패 알림을 계속 맡고,
Prometheus와 Alertmanager는 scheduler를 포함한 Kubernetes workload 장애를 독립적으로
알린다.

## 결정 요약

| 항목 | 결정 | 근거 |
| --- | --- | --- |
| SMTP 설정 저장소 | `monitoring` namespace의 운영자 주입 `alertmanager-smtp-config` Secret | SMTP host, account, password, sender, recipients를 Git과 Terraform state에서 배제 |
| Alertmanager 설정 | 전체 `alertmanager.yaml`을 기존 Secret으로 사용 | Prometheus Operator `AlertmanagerConfig`는 비밀번호만 Secret 참조할 수 있어 나머지 SMTP 값을 Git에 남기게 됨 |
| Secret 공유 | `airflow/airflow-email-alerts`와 같은 SMTP 값을 `monitoring` Secret에 별도 보관 | Kubernetes Secret은 namespace를 넘겨 참조할 수 없음 |
| 라우팅 | `severity=warning` 또는 `critical`만 이메일 발송, `info`는 폐기 | 운영 신호를 전달하되 정보성 알림의 메일 노이즈를 제한 |
| 복구 통지 | `send_resolved: true` | 장애가 해결됐는지 이메일만으로도 확인 가능 |
| OOM 감지 | `ContainerOOMKilled` PrometheusRule 추가 | 기본 `kubernetes-apps` 규칙에 OOM 종료 사유 전용 규칙이 없음 |
| Secret 자동 동기화 | 도입하지 않음 | External Secrets Operator, IAM, Secret Manager 설계는 #372 범위를 초과 |

## 구성과 데이터 흐름

```text
Airflow scheduler 또는 다른 workload가 OOMKilled
  -> kube-state-metrics가 종료 사유 metric을 노출
  -> Prometheus가 ContainerOOMKilled / 기존 CrashLooping 규칙을 평가
  -> Alertmanager가 warning 또는 critical alert를 그룹화
  -> monitoring/alertmanager-smtp-config의 SMTP 설정으로 이메일 발송
  -> alert 해소 시 resolved 이메일 발송
```

`deploy/monitoring/values.yaml`에는 기존 Secret의 이름만 선언한다. Secret의
`alertmanager.yaml`에는 `global` SMTP 설정, root route, warning/critical child
route, email receiver를 모두 포함한다. 이 Secret은 chart 밖에서 운영자가 만들며,
ArgoCD는 관리하거나 prune하지 않는다.

Alertmanager route는 같은 alert를 group-by 키 기준으로 묶고, 최초 발화와 해소를
알린다. 반복 알림 간격은 Alertmanager의 설정에 명시해 같은 장애가 짧은 간격으로
메일 폭주를 일으키지 않게 한다.

## PrometheusRule

chart가 제공하는 `additionalPrometheusRulesMap`에 다음 규칙을 추가한다.

```yaml
alert: ContainerOOMKilled
expr: kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
for: 1m
```

규칙에는 `severity: warning`을 포함한다. 기존 `KubePodCrashLooping`,
`KubePodNotReady`, `KubeContainerWaiting`, `KubeJobFailed` 규칙은 변경하지 않고
동일 receiver의 라우팅 대상이 된다.

## Secret 운영 계약

- `alertmanager-smtp-config`에는 `alertmanager.yaml` 키만 둔다.
- Secret payload, 실제 SMTP endpoint, account, recipients는 Git, Terraform 변수,
  command line 인수, 로그, PR 본문에 기록하지 않는다.
- 운영자는 Airflow SMTP Secret과 Alertmanager config Secret을 같은 비공개 입력으로
  생성하거나 교체한다. 한쪽만 변경하면 Airflow와 Alertmanager의 알림 대상 또는
  인증 정보가 달라질 수 있다.
- Secret 생성 전에는 파일 권한을 제한하고 각 값의 비어 있음과 trailing CR/LF만
  payload를 출력하지 않고 검증한다.
- chart sync 전에 Secret이 존재해야 한다. 존재하지 않거나 `alertmanager.yaml`이
  유효하지 않으면 Alertmanager가 정상 설정을 로드하지 못할 수 있다.

## 네트워크와 보안

현재 `monitoring` namespace에는 deny-by-default NetworkPolicy가 없으므로 SMTP
egress를 열기 위한 NetworkPolicy 변경은 포함하지 않는다. 실제 발송 검증에서
SMTP 연결이 실패하면 DNS, NAT, provider 정책을 먼저 확인한다. monitoring namespace에
네트워크 격리를 도입하는 후속 작업에서는 SMTP TCP 587 egress를 최소 범위로 명시해야
한다.

새 GCP 리소스, IAM 권한, 외부 공개 endpoint, 비용 증가를 도입하지 않는다.

## 변경 대상

| 경로 | 변경 |
| --- | --- |
| `deploy/monitoring/values.yaml` | 기존 Alertmanager config Secret 참조와 `ContainerOOMKilled` 규칙 선언 |
| `docs/GRAFANA_OPERATIONS_RUNBOOK.md` | Alertmanager Secret 생성, 교체, 확인, 롤백과 테스트 절차 |
| `docs/OBSERVABILITY_STRATEGY.md` | Alertmanager SMTP 이메일 채널 운영 상태 반영 |

## 검증

1. `helm dependency build deploy/monitoring` 후 `helm lint deploy/monitoring`과
   `helm template`로 values와 PrometheusRule 렌더링을 확인한다.
2. `git diff --check`와 Secret/state/실값이 diff에 없는지 확인한다.
3. 수동 ArgoCD sync 후 Alertmanager가 Ready이고 새 config를 정상 로드하는지 확인한다.
4. 낮은 memory limit의 일회성 dummy Pod를 OOMKilled 상태로 만들어
   `ContainerOOMKilled` 이메일을 실제로 수신한다.
5. alert가 해소된 뒤 resolved 이메일을 수신한다.
6. 기존 `KubePodCrashLooping` 조건도 같은 receiver로 전달되는지 확인한다.
7. 검증용 Pod를 즉시 삭제한다.

## 롤백

1. ArgoCD sync 전 diff에서 예상하지 못한 Alertmanager 변경이 있으면 sync하지 않는다.
2. 배포 후 config 또는 발송이 실패하면 Helm values를 기존 chart 생성 config로 되돌려
   `null` receiver 상태를 복원한다.
3. Alertmanager가 더 이상 참조하지 않는 것을 확인한 뒤에만
   `alertmanager-smtp-config` Secret을 제거한다.
4. `ContainerOOMKilled` 규칙만 문제면 해당 규칙을 제거하고 기존 기본 규칙과
   Alertmanager receiver는 유지한다.

## 범위 밖

- 메모리 사용량이 limit에 근접했을 때의 사전 경고(leading indicator)
- Slack, Discord, PagerDuty 같은 즉시성 채널
- External Secrets Operator 또는 Secret Manager 기반 자동 동기화
- `monitoring` namespace에 deny-by-default NetworkPolicy를 도입하는 작업
