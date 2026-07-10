# Grafana 운영 Runbook

이 문서는 Issue #81 기준 Prometheus/Grafana 설치 후 팀원이 GKE, Airflow, 앱 상태를
확인하는 절차를 정리한다. 설치와 접근 경로는 `terraform/admin/monitoring-k8s`와
`TEAM_OPERATIONS_RUNBOOK.md`를 기준으로 한다.

## 접속 전 확인

Grafana UI는 인터넷에 공개하지 않는다. 먼저 kubeconfig context와 권한을 확인한다.

```bash
kubectl config current-context
kubectl auth can-i create pods/portforward -n monitoring
kubectl -n monitoring get svc kube-prometheus-stack-grafana
```

포트 포워딩을 열고 브라우저에서 접속한다.

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

```text
http://localhost:3000
```

로그인 정보는 `monitoring/grafana-admin-credentials` Secret payload로 관리한다.
실제 비밀번호를 문서, PR, 채팅, Terraform 변수에 남기지 않는다.

## 기본 확인 순서

장애 알림이 없더라도 운영 점검은 아래 순서로 본다.

| 순서 | 확인 영역 | Grafana에서 볼 것 | kubectl fallback |
|---|---|---|---|
| 1 | Cluster 전체 | node ready 수, cluster CPU/memory 사용률 | `kubectl get nodes` |
| 2 | Node | node별 CPU/memory/disk/network, pressure condition | `kubectl describe node <node>` |
| 3 | Namespace | `airflow`, `autoresearch`, `monitoring` namespace별 resource 사용량 | `kubectl top pods -n <namespace>` |
| 4 | Pod | restart count, OOMKilled, pending pod, CPU/memory 상위 pod | `kubectl get pods -A` |
| 5 | PVC | Prometheus/Airflow PVC 사용량과 남은 용량 | `kubectl get pvc -A` |
| 6 | Airflow | scheduler/worker/webserver pod 상태, task 처리 지연 | `kubectl -n airflow get pods` |
| 7 | 앱/배치 | batch pod 성공/실패, restart, 처리 시간 | `kubectl get pods -A \| grep autoresearch` |

Grafana dashboard 검색 키워드:

- `Kubernetes / Compute Resources / Cluster`
- `Kubernetes / Compute Resources / Namespace`
- `Kubernetes / Compute Resources / Pod`
- `Node Exporter`
- `Persistent Volumes`

dashboard 이름은 chart 버전에 따라 조금 달라질 수 있다. 이름이 다르면 위 키워드로
검색한다.

## GKE Node 상태

먼저 node가 Ready인지 확인한다.

```bash
kubectl get nodes
```

Grafana에서는 node별 CPU, memory, disk, network 사용률과 condition을 본다.

주의해서 볼 신호:

- `MemoryPressure`, `DiskPressure`, `PIDPressure`가 true
- 특정 node CPU/memory가 계속 80% 이상
- disk 사용량이 급격히 증가
- node 하나에 Airflow/Prometheus pod가 과도하게 몰림

1차 조치:

- 문제가 특정 node에만 있으면 pod 분포와 node event를 확인한다.
- 모든 node가 높으면 workload 증가, resource request 과소 설정, node pool 크기
  부족을 의심한다.
- dev에서는 즉시 증설보다 원인 workload를 먼저 확인한다.

## Pod CPU/Memory

namespace별로 높은 pod를 찾는다.

```bash
kubectl top pods -A --sort-by=cpu
kubectl top pods -A --sort-by=memory
```

Grafana에서는 namespace와 pod 단위 CPU/memory dashboard를 본다.

주의해서 볼 신호:

- 같은 pod가 계속 재시작
- `OOMKilled`가 반복
- request 대비 실제 사용량이 지속적으로 높음
- Airflow worker나 batch pod가 pending 상태로 오래 머묾

1차 조치:

- `kubectl describe pod -n <namespace> <pod>`로 event를 확인한다.
- OOM이면 Helm values 또는 workload resource request/limit 조정 후보로 기록한다.
- pending이면 quota, node resource, PVC attach 문제를 확인한다.

## PVC 사용량

Prometheus와 Airflow는 PVC 용량이 부족하면 직접 장애로 이어질 수 있다.

```bash
kubectl get pvc -A
```

Grafana에서는 `Persistent Volumes` 또는 storage 관련 dashboard에서 사용률을 본다.

운영 기준:

| 사용률 | 판단 | 조치 |
|---|---|---|
| 70% 이상 | 증설 검토 | 증가 속도와 retention 확인 |
| 85% 이상 | 즉시 대응 | PVC 증설 또는 retention 축소 검토 |
| 95% 이상 | 장애 위험 | 쓰기 실패 가능성 확인 |

Prometheus PVC가 빠르게 차면 metric cardinality를 의심한다. 사용자 ID, raw URL,
request id처럼 값 종류가 계속 늘어나는 label이 metric에 들어가면 저장량이 급격히
늘 수 있다.

## Airflow 확인

Airflow 장애를 볼 때는 아래 순서로 확인한다.

```bash
kubectl -n airflow get pods
kubectl -n airflow get events --sort-by=.lastTimestamp
```

Grafana에서 볼 것:

- scheduler pod restart
- worker pod pending/OOMKilled
- webserver pod CPU/memory
- Airflow namespace 전체 memory 사용량

Grafana만으로 DAG 실패 원인이 보이지 않으면 Airflow UI와 task log를 함께 본다.
Airflow UI 접속은 `TEAM_OPERATIONS_RUNBOOK.md`의 Airflow UI 접속 절차를 따른다.

## 앱/배치 확인

앱 또는 batch 장애는 먼저 pod 상태와 최근 event를 확인한다.

```bash
kubectl get pods -A | grep -E 'autoresearch|batch|collector'
kubectl get events -A --sort-by=.lastTimestamp | tail -n 50
```

Grafana에서 볼 것:

- batch pod 생성/종료 추이
- restart count
- CPU/memory 급증
- node 또는 namespace resource 부족

YouTube 수집 장애처럼 외부 API 호출과 관련된 문제는 Grafana metric만으로 원인이
끝나지 않을 수 있다. Cloud Run proxy, Airflow task log, 앱 로그를 함께 확인한다.

## 1차 장애 대응 순서

1. 장애 범위가 cluster 전체인지 특정 namespace인지 확인한다.
2. node pressure와 node ready 상태를 본다.
3. pending, restarting, OOMKilled pod를 찾는다.
4. PVC 사용률을 확인한다.
5. 최근 Kubernetes event를 시간순으로 본다.
6. Airflow UI 또는 앱 로그에서 업무 단위 실패 원인을 확인한다.
7. resource 조정, retry, rollback, scale 변경 중 어떤 조치가 필요한지 기록한다.

## 자주 나는 오류

| 증상 | 주된 원인 | 조치 |
|---|---|---|
| Grafana 접속이 안 됨 | port-forward 터미널 종료 또는 로컬 3000 포트 충돌 | 터널 재실행, `3001:80`처럼 다른 포트 사용 |
| `forbidden: pods/portforward` | monitoring namespace RBAC 미부여 | `monitoring_port_forward_user_emails` 반영 여부 확인 |
| 로그인 실패 | Secret payload 오류 또는 비밀번호 착오 | 관리자에게 Secret 재생성 요청 |
| dashboard가 비어 있음 | Prometheus target 미수집 또는 pod 미기동 | `kubectl -n monitoring get pods` 확인 |
| PVC 사용량이 급증 | metric cardinality 증가 | 신규 metric label 검토 |

## 변경 관리

- dashboard JSON, alert rule, values 변경은 PR로 리뷰한다.
- secret payload는 PR에 넣지 않는다.
- chart upgrade 전에는 release note와 CRD 변경 여부를 확인한다.
- apply 후에는 pod 상태, Grafana 접속, node/pod/PVC dashboard를 확인한다.
