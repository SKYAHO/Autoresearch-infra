# MLflow 운영 Runbook

> 이슈 #91~#95 · 설계 `superpowers/specs/2026-07-17-mlflow-operating-design.md`
> 상태: 배포·검증 완료(#94). ArgoCD Application `mlflow` Synced/Healthy.

MLflow tracking server(실험 Tracking + Model Registry)의 접속·운영·백업·장애
대응 절차. 실제 배포된 스택 기준.

## 구성 요약

| 항목 | 값 |
|---|---|
| namespace / KSA | `mlflow` / `mlflow`(Workload Identity → GSA `autoresearch-dev-mlflow`) |
| 경계 소유 | `terraform/admin/mlflow-k8s`(ns/KSA/NetworkPolicy) |
| 앱 배포 | ArgoCD Application `mlflow`(source `deploy/mlflow`, manual sync) |
| 이미지 | GAR `autoresearch-mlflow`(앱 `deploy/mlflow/Dockerfile`을 인프라 Cloud Build로 빌드) |
| backend | Cloud SQL `autoresearch-dev-pg`, DB `mlflow`, user `mlflow`(private IP) |
| artifact | GCS `autoresearch-503903-autoresearch-mlflow-artifacts`, **proxy 모드**(`--serve-artifacts`) |
| Service | `mlflow.mlflow:5000`(ClusterIP, **내부 전용**) |
| UI 인증(#232) | 앞단 **OAuth2-proxy**(`mlflow-oauth-proxy:4180`), Google 로그인 + 허용 이메일 목록. Secret `mlflow-oauth` |
| 시크릿 | DB 비번=Secret Manager `autoresearch-dev-mlflow-db-password`, pod 주입=K8s Secret `mlflow-db` |

책임 경계: 이미지·런타임은 앱 저장소(`SKYAHO/Autoresearch` `deploy/mlflow`), GCP
리소스·배포는 인프라. GCS 인증은 WI로 MLflow 서버에만(클라이언트 자격 없음).

## 접속 (OAuth2-proxy 인증, #232)

UI/API는 ClusterIP라 외부 노출이 없다. 접근은 **OAuth2-proxy(4180)로 port-forward**
한다. proxy가 Google 로그인 + 허용 이메일 목록으로 인증한 뒤 MLflow로 프록시한다.
목록 밖 Google 계정은 거부된다("정해진 계정만").

접속 경로는 두 가지다(둘 다 브라우저는 `http://localhost:4180`).

**(A) Bastion 터널 → 내부 ILB (#244, 기본 권장).** Airflow(#48)와 동일 패턴.

```bash
gcloud compute ssh autoresearch-dev-bastion \
  --zone asia-northeast3-a --project autoresearch-503903 --tunnel-through-iap \
  -- -N -L 4180:mlflow.dev.autoresearch.internal:4180
# 터널 창은 두고, 브라우저: http://localhost:4180 → sign-in → Google 로그인
```

**(B) kubectl port-forward (#236 RBAC 보유자).**

```bash
export PATH="$PATH:/opt/homebrew/share/google-cloud-sdk/bin"   # gke auth plugin
gcloud container clusters get-credentials autoresearch-dev-gke --zone asia-northeast3-a
kubectl port-forward -n mlflow svc/mlflow-oauth-proxy 4180:4180
# 브라우저: http://localhost:4180 → sign-in 페이지 → Google 로그인
```

- redirect URI는 `http://localhost:4180/oauth2/callback`(OAuth client에 등록됨).
- 허용 이메일·client secret 주입은 `terraform/admin/mlflow-k8s/README.md`의
  `mlflow-oauth` Secret 절차. 목록 변경 후 `kubectl rollout restart deployment/mlflow-oauth-proxy -n mlflow`.
- MLflow 클라이언트(SDK)로 직접 쓸 때는 인증 우회가 필요하므로 GKE 내부 워크로드는
  `http://mlflow.mlflow:5000`(proxy 미경유, 내부 전용)을 tracking URI로 쓴다.
- port-forward가 timeout이면 kubeconfig가 IP 엔드포인트를 쓰는 것이다. #279로
  `master_authorized_networks`가 비어 IP 엔드포인트(공인 IP)는 외부 차단된다.
  `gcloud container clusters get-credentials ... --dns-endpoint`로 재발급한다(IAM
  검증, IP 등록 불필요). IP를 allowlist에 추가하는 방식은 동적 IP drift를 유발하므로 쓰지 않는다.
- 팀원 접근(#236): `mlflow` 네임스페이스에 팀원 5명 계정별 namespace RBAC(ClusterRole
  `view` + `pods/portforward` create)를 부여해 cluster-admin 없이 port-forward가
  가능하다. 대상은 `terraform/admin/mlflow-k8s`의 `mlflow_viewer_user_emails`.
  `pods/exec`·secret 읽기·write는 부여하지 않는다.

## 실험/모델 등록 (클라이언트)

클라이언트는 tracking URI만 지정한다. artifact는 proxy 모드라 클라이언트에 GCS
자격이 필요 없다(서버가 대신 기록).

```python
import mlflow
mlflow.set_tracking_uri("http://localhost:5000")   # port-forward 기준
mlflow.set_experiment("my-exp")
with mlflow.start_run():
    mlflow.log_metric("acc", 0.9)
    mlflow.log_artifact("model.pkl")               # 서버가 GCS로 기록
```

GKE 내부 워크로드는 `http://mlflow.mlflow:5000`을 tracking URI로 쓴다.

## 시크릿 주입·로테이션

pod는 DB host(private IP)·비번을 K8s Secret `mlflow-db`에서 받는다. 값은 공개
저장소 매니페스트에 두지 않는다. 주입은 시크릿을 명령행에 노출하지 않도록
`--from-env-file`로 한다(#213 패턴).

```bash
umask 077
env_file="$(mktemp)"; trap 'rm -f "$env_file"' EXIT
PW="$(gcloud secrets versions access latest --secret autoresearch-dev-mlflow-db-password --project autoresearch-503903)"
HOST="$(terraform -chdir=terraform/envs/dev output -raw cloud_sql_private_ip_address)"
printf 'POSTGRES_PASSWORD=%s\nPOSTGRES_HOST=%s\n' "$PW" "$HOST" > "$env_file"; unset PW
kubectl create secret generic mlflow-db -n mlflow --from-env-file="$env_file" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f "$env_file"; trap - EXIT
kubectl rollout restart deployment/mlflow -n mlflow   # pod가 새 값 반영
```

**DB 비번 로테이션**: ① Cloud SQL user 비번 변경(Terraform `random_password` 교체
apply) → ② Secret Manager 새 version → ③ 위 절차로 `mlflow-db` 재주입 →
④ `rollout restart`.

## 백업·복구

- **backend(Cloud SQL)**: `autoresearch-dev-pg`는 자동 백업 + PITR 활성(`cloud_sql.tf`).
  실험/모델 메타데이터는 여기 저장된다. 복구는 인스턴스 PITR/백업 복원.
- **artifact(GCS)**: 버킷 `prevent_destroy` + **7일 soft delete**. 실수 삭제 시 7일 내
  복구 가능. 모델 artifact는 immutable(versioning 없음).

## 배포·업데이트

이미지·매니페스트는 GitOps로 관리한다.

```bash
# 이미지 갱신: 앱 Dockerfile 변경 시 인프라 Cloud Build로 재빌드 후 deploy/mlflow의
# image digest를 새 값으로 PR → merge → ArgoCD sync.
# manual sync 트리거(argocd CLI 없이 kubectl로):
kubectl patch application mlflow -n argocd --type merge \
  -p '{"operation":{"initiatedBy":{"username":"operator"},"sync":{"revision":"main"}}}'
kubectl -n argocd get application mlflow -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
```

앱팀이 자기 파이프라인으로 GAR에 이미지를 올리면 `deploy/mlflow`의 image를 그
경로로 re-point한다(Dockerfile 동일이라 동작 동일).

## 사용량 관측 (#357)

Grafana `AutoResearch / MLflow`(uid `ar-mlflow`)에서 요청률(상태코드별)·p95
지연·컨테이너 CPU/메모리를 본다. 수집 경로: oauth2-proxy
`--metrics-address`(44180) → PodMonitor(`deploy/mlflow/podmonitor.yaml`,
`release: kube-prometheus-stack` 라벨 필수) → kube-prometheus-stack.
oauth2-proxy가 UI/API의 유일한 인입 경로라 전체 사용량이 여기서 관측된다.

폴백 채택 사유(#357): MLflow 서버 자체 `--expose-prometheus`는 이미지에
`prometheus_flask_exporter`가 없어(실측) 앱 저장소 runtime 변경 + Cloud
Build 재빌드 + digest re-point가 필요하다. dev "사용량 확인" 요구에는
proxy 메트릭 + cAdvisor로 충분해 서버 계측은 보류 — 엔드포인트별 정밀
메트릭이 필요해지면 그때 앱 저장소 runtime에 exporter를 추가한다.

메트릭명은 v7.7.1 런타임 실측으로 확정(2026-07-27, 1회용 파드):
`oauth2_proxy_requests_total{code}`, `oauth2_proxy_response_duration_seconds`
(histogram, `method`), `oauth2_proxy_requests_in_flight`. 시리즈는 **첫 요청이
4180을 통과한 뒤에야 생성**되므로 배포 직후 상위 두 패널의 "No data"는 정상.

반영 경로가 두 갈래라 증상으로 원인을 구분한다:

| 증상 | 원인 | 확인 위치 |
|---|---|---|
| 대시보드 자체가 없음 | `monitoring` Application 미sync | ArgoCD app `monitoring` |
| 패널은 있는데 타깃이 목록에 없음 | `mlflow` Application 미sync 또는 PodMonitor `release` 라벨 누락 | **Prometheus UI Status → Service Discovery**에 `podMonitor/mlflow/...` 항목 부재가 가장 빠른 신호 |
| 타깃 up인데 빈 그래프 | 트래픽 0(위 지연 등록) 또는 PromQL 이름 불일치 | proxy로 요청 1회 보낸 뒤 재확인 |

## 장애 대응

| 증상 | 원인·조치 |
|---|---|
| pod `OOMKilled`(exit 137) | 메모리 부족. 현재 limit 1Gi + `--workers 2`. worker/메모리 상향은 `deploy/mlflow/deployment.yaml`에서(#229) |
| pod Ready 안 됨, `/health` 무응답 | 느린 기동은 startupProbe가 흡수. 지속 실패 시 로그 확인: `kubectl logs -n mlflow -l app.kubernetes.io/name=mlflow` |
| Service `mlflow.mlflow` 무응답 | pod not-ready면 endpoint 없음. pod 상태부터 확인 |
| backend 연결 실패(pod crash) | `mlflow-db` Secret의 HOST/PW 확인, Cloud SQL private IP 변동 여부, NetworkPolicy(5432 egress) 확인 |
| artifact 기록 403 | MLflow GSA IAM(objectAdmin + **legacyBucketReader**) 확인(#204 교훈). WI 신원 확인 |
| Application OutOfSync | 누군가 live 리소스를 수동 변경. `deploy/mlflow`가 desired. 위 sync로 재조정 |

## 진단 명령

```bash
kubectl get pod -n mlflow -l app.kubernetes.io/name=mlflow
kubectl logs -n mlflow -l app.kubernetes.io/name=mlflow --tail=50
kubectl get application mlflow -n argocd -o jsonpath='{.status.sync.status}/{.status.health.status}{"\n"}'
# 임시 probe pod로 health/API 확인
kubectl run mlflow-probe -n mlflow --image=curlimages/curl:8.9.1 --restart=Never --command -- sleep 300
kubectl exec -n mlflow mlflow-probe -- curl -s http://mlflow.mlflow:5000/health
kubectl delete pod mlflow-probe -n mlflow
```

## 참고

- 설계·경계: `superpowers/specs/2026-07-17-mlflow-operating-design.md`, [`GITOPS_STRATEGY.md`](GITOPS_STRATEGY.md)
- 경계 root README: `terraform/admin/mlflow-k8s/README.md`
- UI 인증(OAuth2-proxy)은 #232로 완료. 팀원 port-forward RBAC은 #236로 완료.
  내부 ILB 노출(#244)도 구현 — 기본 접속은 Bastion 터널(위 접속 A),
  port-forward도 유지. 설계: `superpowers/specs/2026-07-18-mlflow-internal-ilb-design.md`.
