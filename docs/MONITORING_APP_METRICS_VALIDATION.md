# 애플리케이션 메트릭 e2e 검증 Runbook (monitoring 스택)

> 이슈 #206 · 관련: monitoring ArgoCD 이관(#183), [`OBSERVABILITY_STRATEGY.md`](OBSERVABILITY_STRATEGY.md)

monitoring 스택(kube-prometheus-stack, ArgoCD 관리)에서 **애플리케이션이 노출한
메트릭이 Prometheus로 수집되고 Grafana에서 조회되는 전 경로**를 테스트
워크로드로 검증하는 절차다. 실제 앱 배포 전에 관측 파이프라인이 동작함을
확인하는 용도이며, 재현 가능한 최소 예시를 제공한다.

## 사전 조건

- ArgoCD `monitoring`·`argo-rollouts` Application이 `Synced`/`Healthy`
- Grafana에 Prometheus datasource가 provisioning됨
  (`kube-prometheus-stack-grafana-datasource` configmap, datasource uid `prometheus`)
- 실행 네트워크가 GKE control plane master authorized networks에 등재됨
  (kubectl 접근). `gke-gcloud-auth-plugin` PATH 필요.

핵심 제약: **ServiceMonitor는 라벨 `release: kube-prometheus-stack`이 있어야**
Prometheus `serviceMonitorSelector`에 잡힌다. `serviceMonitorNamespaceSelector`는
`{}`(전체 namespace)이므로 전용 검증 namespace에 두어도 수집된다.

## 검증 절차

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

## 실측 결과 (2026-07-15, #206)

| 단계 | 결과 |
|---|---|
| ArgoCD monitoring/argo-rollouts | `Synced`/`Healthy` |
| 앱 `/metrics` 노출 | `http_request_duration_seconds_count{code="200",handler="found"}=8` (8 요청과 일치) |
| Prometheus target UP | `up{service="metrics-sample"}=1` |
| Prometheus 수집 | 커스텀 메트릭 `count=8` 저장 확인 |
| Grafana datasource | Prometheus(uid `prometheus`) provisioning됨 |
| Grafana 경유 조회 | `status: success`, `up=1`·`count=8` 반환 |

관측 파이프라인(앱 `/metrics` → ServiceMonitor → Prometheus → Grafana) 전 경로가
동작함을 실증했다. 검증 리소스는 삭제했다.

## 범위 밖 (후속)

- **ArgoCD를 통한 임의 애플리케이션 실배포**: git-hosted manifest + AppProject
  destination 설정이 필요한 별도 작업.
- **Vault 시크릿 주입**: Vault는 드랍 결정(Secret Manager로 충분)이라 진행하지 않는다.
- **Argo Rollouts 배포 전환**: canary promote/abort 흐름은
  [`ROLLOUTS_OPERATIONS_RUNBOOK.md`](ROLLOUTS_OPERATIONS_RUNBOOK.md)를 따른다.
