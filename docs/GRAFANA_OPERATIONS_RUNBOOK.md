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

로그인은 **Google OAuth(팀원 개인 계정)가 기본**이다(#155). admin 계정
(`monitoring/grafana-admin-credentials` Secret payload)은 비상용으로만
유지한다. 실제 비밀번호를 문서, PR, 채팅, Terraform 변수에 남기지 않는다.

## Google OAuth 로그인 (#155)

로그인 페이지의 "Sign in with Google"로 팀원 개인 계정 로그인한다.
`allow_sign_up=false`라 **사전 생성된 계정만** 로그인할 수 있다 —
gmail은 도메인 제한이 불가능하므로(gmail.com 허용 = 전 세계 허용) 자동
가입을 막고 계정 매칭으로만 허용하는 구조다. 팀원 이메일 allowlist는
Git/문서가 아닌 Grafana DB(계정)에만 존재한다.

### 최초 구성 (운영자 1회)

1. **OAuth client 발급** (GCP 콘솔 → APIs & Services → Credentials →
   Create OAuth client ID):
   - Application type: Web application
   - Authorized redirect URI: `http://localhost:3000/login/google`
   - 기존 OAuth consent screen(Airflow #54와 공용)을 사용한다
2. **Secret 주입** (client secret은 어디에도 기록하지 않는다):

시크릿을 명령행 인수(셸 히스토리·프로세스 목록에 노출)에 두지 않도록,
`read -s`로 입력받아 권한 제한 임시 파일(`--from-env-file`)로 주입한다.

```bash
umask 077                                   # 이후 생성 파일은 0600
env_file="$(mktemp)"
trap 'rm -f "$env_file"' EXIT               # 오류 포함 종료 시 폐기

# read -s: 화면·셸 히스토리에 값이 남지 않는다. 값은 변수로만 다룬다.
read -rs -p 'GOOGLE_CLIENT_ID: '     GCID;  echo
read -rs -p 'GOOGLE_CLIENT_SECRET: ' GCSEC; echo
printf 'GF_AUTH_GOOGLE_CLIENT_ID=%s\nGF_AUTH_GOOGLE_CLIENT_SECRET=%s\n' \
  "$GCID" "$GCSEC" > "$env_file"
unset GCID GCSEC

kubectl -n monitoring create secret generic grafana-google-oauth \
  --from-env-file="$env_file"

rm -f "$env_file"; trap - EXIT              # 즉시 삭제
```

3. monitoring-k8s root apply (values의 `envFromSecret`가 이 Secret을
   전제로 하므로 **주입 없이는 Grafana pod가 기동하지 못한다** —
   `grafana-admin-credentials`와 동일 선례)

### 팀원 계정 사전 생성 (운영자)

admin으로 로그인 → Administration → Users → New user:
- Email에 팀원 gmail을 **Google 계정에 표시되는 문자열 그대로** 입력한다
  (점/plus 별칭 변형 금지). OAuth 매칭은 이메일 정확 일치 기준이며,
  불일치 시 Grafana가 신규 가입을 시도하다 allow_sign_up=false에 막혀
  로그인이 거부된다(안전한 실패).
- 초기 비밀번호는 **강한 랜덤 값**으로 넣는다(`openssl rand -base64 24`)
  — 기본 로그인 폼(/login)이 admin 비상용으로 열려 있어, 약한 임시
  비밀번호는 OAuth allowlist를 우회하는 brute-force 표적이 된다(리뷰
  반영). 랜덤 값은 기록·공유하지 않는다(해당 계정의 폼 로그인은 사실상
  봉인되고, 팀원은 Google 버튼만 사용).
- 권한은 기본 Viewer(대시보드 편집 담당만 Editor).
- 팀원 목록은 이 문서에 기록하지 않는다(이메일 비노출 원칙)

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

## 앱 메트릭 e2e 검증 (#206, 2026-07-15)

monitoring 스택(kube-prometheus-stack, ArgoCD 관리)에서 **애플리케이션이 노출한
메트릭이 Prometheus로 수집되고 Grafana에서 조회되는 전 경로**를 테스트
워크로드로 검증하는 절차다. 실제 앱 배포 전에 관측 파이프라인이 동작함을
확인하는 용도이며, 재현 가능한 최소 예시를 제공한다.

### 사전 조건

- ArgoCD `monitoring`·`argo-rollouts` Application이 `Synced`/`Healthy`
- Grafana에 Prometheus datasource가 provisioning됨
  (`kube-prometheus-stack-grafana-datasource` configmap, datasource uid `prometheus`)
- 실행 네트워크가 GKE control plane master authorized networks에 등재됨
  (kubectl 접근). `gke-gcloud-auth-plugin` PATH 필요.

핵심 제약: **ServiceMonitor는 라벨 `release: kube-prometheus-stack`이 있어야**
Prometheus `serviceMonitorSelector`에 잡힌다. `serviceMonitorNamespaceSelector`는
`{}`(전체 namespace)이므로 전용 검증 namespace에 두어도 수집된다.

### 1. 테스트 워크로드 + ServiceMonitor 배포

`/metrics`(Prometheus 형식)를 노출하는 최소 앱(`prometheus-example-app`)을
전용 namespace에 배포한다.

```bash
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring-e2e-test
  labels: { purpose: monitoring-validation }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metrics-sample
  namespace: monitoring-e2e-test
  labels: { app: metrics-sample }
spec:
  replicas: 1
  selector: { matchLabels: { app: metrics-sample } }
  template:
    metadata: { labels: { app: metrics-sample } }
    spec:
      containers:
        - name: app
          image: quay.io/brancz/prometheus-example-app:v0.5.0
          ports: [ { name: http, containerPort: 8080 } ]
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits: { cpu: 50m, memory: 32Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: metrics-sample
  namespace: monitoring-e2e-test
  labels: { app: metrics-sample }
spec:
  selector: { app: metrics-sample }
  ports: [ { name: http, port: 8080, targetPort: http } ]
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: metrics-sample
  namespace: monitoring-e2e-test
  labels: { release: kube-prometheus-stack }   # serviceMonitorSelector 매칭 필수
spec:
  selector: { matchLabels: { app: metrics-sample } }
  namespaceSelector: { matchNames: [ monitoring-e2e-test ] }
  endpoints: [ { port: http, path: /metrics, interval: 15s } ]
YAML

kubectl wait --for=condition=Available deploy/metrics-sample -n monitoring-e2e-test --timeout=120s
```

검증용 curl pod:

```bash
kubectl run curl-probe -n monitoring-e2e-test --image=curlimages/curl:8.9.1 \
  --restart=Never --command -- sleep 3600
kubectl wait --for=condition=Ready pod/curl-probe -n monitoring-e2e-test --timeout=60s
```

### 2. 앱이 `/metrics`로 Prometheus 형식 메트릭을 노출하는지 확인

```bash
# 요청을 몇 번 보내 counter 증가
for i in $(seq 1 8); do
  kubectl exec -n monitoring-e2e-test curl-probe -- \
    curl -s -o /dev/null http://metrics-sample.monitoring-e2e-test:8080/
done
kubectl exec -n monitoring-e2e-test curl-probe -- \
  curl -s http://metrics-sample.monitoring-e2e-test:8080/metrics | grep http_request
```

기대: `http_request_duration_seconds_*`(histogram) 등 노출, `_count`가 요청 수와 일치.

### 3–4. Prometheus scrape(target UP) + 수집 확인

```bash
PROM="http://kube-prometheus-stack-prometheus.monitoring:9090"
# target UP (ServiceMonitor 발견까지 최대 ~30s)
kubectl exec -n monitoring-e2e-test curl-probe -- \
  curl -s --get "$PROM/api/v1/query" \
  --data-urlencode 'query=up{namespace="monitoring-e2e-test",service="metrics-sample"}'
# 커스텀 메트릭 수집
kubectl exec -n monitoring-e2e-test curl-probe -- \
  curl -s --get "$PROM/api/v1/query" \
  --data-urlencode 'query=http_request_duration_seconds_count{namespace="monitoring-e2e-test"}'
```

기대: `up` 값 `1`, 커스텀 메트릭 result 존재.

### 5–6. Grafana datasource 연결 + 조회

Grafana admin 자격은 operator 주입 시크릿 `grafana-admin-credentials`에 있다.

```bash
GADMIN=$(kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-user}' | base64 -d)
GPASS=$(kubectl get secret grafana-admin-credentials -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d)
GRAF="http://kube-prometheus-stack-grafana.monitoring:80"

# datasource 목록에서 Prometheus uid 확인 (uid: prometheus)
kubectl exec -n monitoring-e2e-test curl-probe -- curl -s -u "$GADMIN:$GPASS" "$GRAF/api/datasources"

# Grafana datasource proxy로 Prometheus 쿼리
kubectl exec -n monitoring-e2e-test curl-probe -- \
  curl -s -u "$GADMIN:$GPASS" --get \
  "$GRAF/api/datasources/proxy/uid/prometheus/api/v1/query" \
  --data-urlencode 'query=up{namespace="monitoring-e2e-test",service="metrics-sample"}'
```

기대: `"status":"success"`, Grafana 경유로 동일 메트릭(`up=1`) 반환.

### 7. 정리

```bash
kubectl delete namespace monitoring-e2e-test
```

### 실측 결과 (2026-07-15, #206)

| 단계 | 결과 |
|---|---|
| ArgoCD monitoring/argo-rollouts | `Synced`/`Healthy` |
| 앱 `/metrics` 노출 | `http_request_duration_seconds_count{code="200",handler="found"}=8` (8 요청과 일치) |
| Prometheus target UP | `up{service="metrics-sample"}=1` |
| Prometheus 수집 | 커스텀 메트릭 `count=8` 저장 확인 |
| Grafana datasource | Prometheus(uid `prometheus`) provisioning됨 |
| Grafana 경유 조회 | `status: success`, `up=1`·`count=8` 반환 |

관측 파이프라인(앱 `/metrics` → ServiceMonitor → Prometheus → Grafana) 전 경로가
동작함을 실증했다. 검증 리소스는 삭제했다. Argo Rollouts canary promote/abort
흐름은 [`ROLLOUTS_OPERATIONS_RUNBOOK.md`](ROLLOUTS_OPERATIONS_RUNBOOK.md)를 따른다.

## 변경 관리

- dashboard JSON, alert rule, values 변경은 PR로 리뷰한다.
- secret payload는 PR에 넣지 않는다.
- chart upgrade 전에는 release note와 CRD 변경 여부를 확인한다.
- apply 후에는 pod 상태, Grafana 접속, node/pod/PVC dashboard를 확인한다.
