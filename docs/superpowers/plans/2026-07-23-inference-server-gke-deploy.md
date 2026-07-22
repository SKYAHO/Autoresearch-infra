# Inference Server GKE 배포 구현 계획 (#302)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

설계: `../specs/2026-07-23-inference-server-gke-deploy-design.md`

**Goal:** 앱 저장소가 만든 `autoresearch-serving` 이미지를 dev GKE `autoresearch`
namespace에 ArgoCD로 배포하고, 실제 `/healthcheck` → `/rerank` → `/metrics` E2E와
digest 롤백을 검증한다.

**Architecture:** Terraform admin root가 플랫폼 경계(AppProject destination,
ArgoCD Application, NetworkPolicy)를 만들고, infra repo `deploy/serving/`의 plain
manifest를 ArgoCD가 manual sync한다. 이미지 digest는 manifest에 하드코딩해 배포와
롤백이 git 이력으로 완결된다. MLflow(#94)와 동일한 패턴이다.

**Tech Stack:** Terraform(kubernetes/helm provider), ArgoCD, Kubernetes plain
manifest, kube-prometheus-stack ServiceMonitor, Memorystore Redis Cluster, MLflow
Model Registry.

## Global Constraints

- 실제 `terraform apply` / ArgoCD sync / 리소스 생성은 **사용자가 명확히 요청했을 때만**
  수행한다. Task 1~4는 코드·문서 변경만 하고 apply하지 않는다.
- GitHub 원격 작업(push, PR 생성)은 실행 전에 사용자에게 확인받는다.
- 이 저장소는 **public**이다. Redis discovery private IP, CA 본문, secret payload를
  manifest·Terraform state·로그·PR 본문에 넣지 않는다.
- 이미지는 mutable tag가 아니라 **immutable digest**(`@sha256:...`)로만 참조한다.
- IAM을 새로 추가하지 않는다. `gke_app` GSA가 필요 권한을 이미 보유한다.
- 외부 LoadBalancer/Ingress를 만들지 않는다. 접근은 ClusterIP + port-forward.
- 커밋 메시지·PR 본문은 `.github/PULL_REQUEST_TEMPLATE.md`와 `CONTRIBUTING.md`
  컨벤션을 따른다.

## 선행 조건

**Task 3은 앱 저장소 [SKYAHO/Autoresearch#266](https://github.com/SKYAHO/Autoresearch/issues/266)이
`autoresearch-serving` 이미지를 GAR에 push한 뒤에만 시작할 수 있다.** digest가 있어야
manifest를 쓸 수 있다. Task 1·2·4는 그 전에 진행 가능하다.

E2E(Task 6)에는 Redis에 materialize된 실제 user/video ID가 필요하다. #203 검증분을
Task 6 시작 시 재확인한다.

## File Structure

| 파일 | 책임 |
|---|---|
| `deploy/serving/deployment.yaml` (신규) | 서빙 파드 정의 — digest, env, probe, resources |
| `deploy/serving/service.yaml` (신규) | ClusterIP :8000 |
| `deploy/serving/servicemonitor.yaml` (신규) | Prometheus 스크랩 대상 등록 |
| `terraform/admin/argocd-k8s/variables.tf` | `app_namespace`, `serving_target_revision` |
| `terraform/admin/argocd-k8s/main.tf` | AppProject destination + `application_serving` |
| `terraform/admin/autoresearch-k8s/main.tf` | NetworkPolicy MLflow egress |
| `docs/TEAM_OPERATIONS_RUNBOOK.md` | 접근·Secret 주입·E2E·모델 교체 절차 |
| `docs/GITOPS_STRATEGY.md` | 이관 현황표, Rollouts 서술 |
| `terraform/admin/*/README.md` | root별 운영 절차 |
| `docs/CHANGE_HISTORY.md` | 결정 요약 |

---

### Task 1: ArgoCD 배포 경계 (AppProject destination + Application)

AppProject `autoresearch-dev`의 `destinations`에 `autoresearch` namespace가 없어
현재 상태로는 ArgoCD가 이 namespace로의 sync를 거부한다. destination을 추가하고
serving Application을 정의한다.

**Files:**
- Modify: `terraform/admin/argocd-k8s/variables.tf`
- Modify: `terraform/admin/argocd-k8s/main.tf:222-247` (AppProject `destinations`)
- Modify: `terraform/admin/argocd-k8s/main.tf:379` 뒤 (Application 추가)

**Interfaces:**
- Consumes: `var.infra_repo_url`, `kubernetes_manifest.appproject_autoresearch_dev`
- Produces: ArgoCD Application `serving` — source `deploy/serving`, destination
  namespace `var.app_namespace`, manual sync. Task 3이 이 경로에 manifest를 채운다.

- [ ] **Step 1: 현재 AppProject가 `autoresearch`를 거부하는지 확인**

```bash
kubectl -n argocd get appproject autoresearch-dev \
  -o jsonpath='{.spec.destinations[*].namespace}{"\n"}'
```

Expected: `monitoring argo-rollouts kube-system mlflow` — `autoresearch`가 **없음**.
이 상태가 Task 1이 해결하는 문제다.

- [ ] **Step 2: 변수 추가**

`terraform/admin/argocd-k8s/variables.tf` 끝에 추가:

```hcl
variable "app_namespace" {
  description = "#302 Autoresearch 앱 namespace(autoresearch-k8s 소유). ArgoCD destination으로 허용한다."
  type        = string
  default     = "autoresearch"
}

variable "serving_target_revision" {
  description = "Inference Server Application이 추적할 infra repo ref. 최초 sync는 -var로 병합 커밋 SHA를 pin한다."
  type        = string
  default     = "main"
}
```

- [ ] **Step 3: AppProject destination 추가**

`main.tf`의 `destinations` 리스트에서 mlflow 블록 뒤에 추가:

```hcl
        {
          # #302 앱 namespace는 terraform/admin/autoresearch-k8s가 소유(ns/KSA/NP).
          # ArgoCD는 deploy/serving(Deployment/Service/ServiceMonitor)만 배포한다.
          server    = "https://kubernetes.default.svc"
          namespace = var.app_namespace
        },
```

- [ ] **Step 4: Application 추가**

`main.tf`의 `application_mlflow` 블록 뒤에 추가:

```hcl
# #302 Inference Server Application — infra repo의 deploy/serving(plain 매니페스트:
# Deployment/Service/ServiceMonitor)을 배포한다. namespace는 autoresearch-k8s가
# 소유하므로 CreateNamespace=false. manual sync(초기 원칙).
# 이미지는 manifest에 immutable digest로 고정되며, 롤백은 이전 digest 커밋 후 sync다.
resource "kubernetes_manifest" "application_serving" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "serving"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }
    spec = {
      project = kubernetes_manifest.appproject_autoresearch_dev.manifest.metadata.name
      source = {
        repoURL        = var.infra_repo_url
        path           = "deploy/serving"
        targetRevision = var.serving_target_revision
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.app_namespace
      }
      syncPolicy = {
        syncOptions = [
          "CreateNamespace=false",
        ]
      }
    }
  }

  depends_on = [helm_release.argo_cd]
}
```

- [ ] **Step 5: 검증**

```bash
terraform -chdir=terraform/admin/argocd-k8s fmt -check -recursive
terraform -chdir=terraform/admin/argocd-k8s init -backend=false
terraform -chdir=terraform/admin/argocd-k8s validate
```

Expected: 세 명령 모두 성공. `validate`는 `Success! The configuration is valid.`

- [ ] **Step 6: 커밋**

```bash
git add terraform/admin/argocd-k8s/variables.tf terraform/admin/argocd-k8s/main.tf
git commit -m "feat: ArgoCD에 Inference Server Application과 앱 namespace destination 추가 (#302)"
```

---

### Task 2: NetworkPolicy MLflow egress

`RERANK_MODEL_SOURCE=registry`는 MLflow(`mlflow` namespace ClusterIP:5000)에서 alias를
해석하고 artifact를 받는다. 현재 egress 규칙 어디에도 이 경로가 없어 모델 로드가 막힌다.

**Files:**
- Modify: `terraform/admin/autoresearch-k8s/main.tf:160` (마지막 egress 블록 뒤)

**Interfaces:**
- Consumes: `var.cluster_services_cidr` (기본 `172.16.128.0/24`)
- Produces: `autoresearch-egress` NetworkPolicy가 MLflow 5000 egress를 허용.
  Task 5의 파드 기동이 이에 의존한다.

- [ ] **Step 1: 현재 정책에 MLflow 경로가 없음을 확인**

```bash
kubectl -n autoresearch get networkpolicy autoresearch-egress \
  -o jsonpath='{.spec.egress[*].ports[*].port}{"\n"}'
```

Expected: `53 53 5432 6379 11000 80 987 988 443` 계열 — **5000이 없음**.

- [ ] **Step 2: egress 규칙 추가**

`main.tf`의 마지막 egress 블록(`0.0.0.0/0` 443) **뒤**, `spec` 닫기 전에 추가:

```hcl
    # #302 MLflow tracking server: registry alias 해석과 모델 artifact 다운로드.
    # artifact는 mlflow-artifacts:/ 스킴이라 서버를 경유하므로 GCS 직접 egress는
    # 필요 없다. DNS 규칙과 같은 이중 패턴을 쓴다 — Calico가 service 트래픽을 DNAT
    # 이전에 평가하므로 ClusterIP VIP는 services CIDR로 열고, DNAT 이후 평가하는
    # dataplane을 위해 namespace selector 규칙을 함께 둔다.
    egress {
      to {
        ip_block {
          cidr = var.cluster_services_cidr
        }
      }

      ports {
        protocol = "TCP"
        port     = "5000"
      }
    }

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "mlflow"
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = "5000"
      }
    }
```

- [ ] **Step 3: 검증**

```bash
terraform -chdir=terraform/admin/autoresearch-k8s fmt -check -recursive
terraform -chdir=terraform/admin/autoresearch-k8s init -backend=false
terraform -chdir=terraform/admin/autoresearch-k8s validate
```

Expected: 모두 성공.

- [ ] **Step 4: 커밋**

```bash
git add terraform/admin/autoresearch-k8s/main.tf
git commit -m "feat: 앱 egress에 MLflow tracking server 경로 추가 (#302)"
```

---

### Task 3: serving manifest 3종

> **선행 조건**: 앱 저장소 #266이 `autoresearch-serving` 이미지를 push한 뒤 시작한다.

**Files:**
- Create: `deploy/serving/deployment.yaml`
- Create: `deploy/serving/service.yaml`
- Create: `deploy/serving/servicemonitor.yaml`

**Interfaces:**
- Consumes: KSA `autoresearch-app`(autoresearch-k8s 소유), Secret
  `autoresearch-serving-redis`(Task 5에서 운영자 주입), Task 1의 Application
- Produces: Service `autoresearch-serving`(ClusterIP:8000, label
  `app.kubernetes.io/name: autoresearch-serving`). Task 6의 port-forward 대상.

- [ ] **Step 1: 배포할 digest 조회**

앱 저장소 `release.yml`은 `latest` 태그를 만들지 않고 `sha-<SOURCE_SHA>` 태그와
digest만 남긴다. 최신 이미지를 시간순으로 조회한다:

```bash
gcloud artifacts docker images list \
  asia-northeast3-docker.pkg.dev/ar-infra-501607/autoresearch-dev-docker/autoresearch-serving \
  --include-tags --sort-by=~UPDATE_TIME --limit=5 \
  --format='table(DIGEST, TAGS, UPDATE_TIME)'
```

Expected: `sha256:` 로 시작하는 digest 목록. 배포할 대상은 앱 저장소 #266 실행의 job
summary에 출력된 `digest_ref`와 **일치해야 한다** — 목록의 최신 항목을 그대로 믿지
말고 summary와 대조한다. 확정한 값을 아래 `<DIGEST>` 자리에 넣는다.

- [ ] **Step 2: `deploy/serving/deployment.yaml` 작성**

```yaml
# #302 Inference Server. ArgoCD(deploy/serving)가 이 매니페스트를 배포한다.
# 이미지: 앱 저장소 deploy/serving/Dockerfile을 앱 저장소 release.yml이 빌드해 GAR에
# push한 것(SKYAHO/Autoresearch#266). tag가 아니라 immutable digest로 고정하며,
# 롤백은 이 digest를 이전 값으로 되돌리는 커밋 + sync다.
# Redis discovery endpoint(private IP)는 공개 저장소에 넣지 않고 operator 주입 Secret
# `autoresearch-serving-redis`에서 받는다(autoresearch-k8s README 참조).
# Redis TLS CA 본문은 어디에도 두지 않고 REDIS_CA_SECRET_ID로 런타임에 Secret
# Manager에서 읽는다. 인증은 Workload Identity(KSA autoresearch-app)로 처리한다.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: autoresearch-serving
  namespace: autoresearch
  labels:
    app.kubernetes.io/name: autoresearch-serving
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: autoresearch-serving
  template:
    metadata:
      labels:
        app.kubernetes.io/name: autoresearch-serving
    spec:
      serviceAccountName: autoresearch-app
      containers:
        - name: serving
          image: asia-northeast3-docker.pkg.dev/ar-infra-501607/autoresearch-dev-docker/autoresearch-serving@<DIGEST>
          ports:
            - name: http
              containerPort: 8000
          env:
            - name: GCP_PROJECT_ID
              value: "ar-infra-501607"
            # CA 본문이 아니라 secret id만. 실제 통제는 Secret Manager IAM이 한다.
            - name: REDIS_CA_SECRET_ID
              value: "autoresearch-dev-redis-server-ca"
            - name: MLFLOW_TRACKING_URI
              value: "http://mlflow.mlflow.svc.cluster.local:5000"
            - name: RERANK_MODEL_SOURCE
              value: "registry"
            - name: RERANK_REGISTRY_MODEL_NAME
              value: "ctr-model"
            - name: RERANK_REGISTRY_ALIAS
              value: "champion"
            - name: RERANK_FEATURE_REPO_PATH
              value: "feature_repo"
            - name: GCS_REGISTRY_PATH
              value: "gs://ar-infra-501607-feast-registry/registry.db"
            # online 조회에는 쓰이지 않지만 feature_store.yaml이 ${VAR} 치환으로
            # 파싱하므로 없으면 Feast 초기화가 실패한다.
            - name: GCS_STAGING_LOCATION
              value: "gs://ar-infra-501607-feast-staging/"
            - name: BQ_DATASET
              value: "feast_offline_store"
            # discovery endpoint(private IP)는 operator 주입 Secret에서만.
            - name: REDIS_HOST
              valueFrom:
                secretKeyRef:
                  name: autoresearch-serving-redis
                  key: REDIS_HOST
            - name: REDIS_PORT
              valueFrom:
                secretKeyRef:
                  name: autoresearch-serving-redis
                  key: REDIS_PORT
          # 의존성 상태는 readiness가, 프로세스 생존은 liveness가 담당한다.
          # liveness를 /healthcheck에 연결하지 않는다 — 앱이 /healthcheck를 실시간
          # 의존성 조회로 전환할 예정이며, 결합하면 Redis 장애가 재시작 루프로
          # 증폭된다(CrashLoopBackOff 간격 최대 5분). 설계서 "probe 계약" 참조.
          # startupProbe는 반대로 필요하다 — lifespan이 초기화 예외를 삼키고 기동하므로
          # 모델 로드 실패 파드가 Ready 상태로 영구히 503을 반환하는 것을 막는다.
          startupProbe:
            httpGet:
              path: /healthcheck
              port: http
            periodSeconds: 10
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /healthcheck
              port: http
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: http
            periodSeconds: 20
            failureThreshold: 3
          resources:
            requests:
              cpu: 250m
              memory: 1Gi
            limits:
              cpu: 1000m
              memory: 2Gi
```

- [ ] **Step 3: `deploy/serving/service.yaml` 작성**

```yaml
# #302 Inference Server 내부 엔드포인트. ClusterIP = 내부 전용(외부 노출 금지).
# 접근은 kubectl port-forward. 외부 LoadBalancer/Ingress를 만들지 않는다.
apiVersion: v1
kind: Service
metadata:
  name: autoresearch-serving
  namespace: autoresearch
  labels:
    app.kubernetes.io/name: autoresearch-serving
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: autoresearch-serving
  ports:
    - name: http
      port: 8000
      targetPort: http
```

- [ ] **Step 4: `deploy/serving/servicemonitor.yaml` 작성**

```yaml
# #302 /metrics를 기존 kube-prometheus-stack이 수집하도록 등록한다.
# `release: kube-prometheus-stack` 라벨은 필수다. 이 클러스터의 Prometheus는
# serviceMonitorSelector={"matchLabels":{"release":"kube-prometheus-stack"}}이며
# 라벨이 없으면 에러 없이 조용히 무시된다(namespace 제약은 없음).
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: autoresearch-serving
  namespace: autoresearch
  labels:
    app.kubernetes.io/name: autoresearch-serving
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: autoresearch-serving
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

- [ ] **Step 5: manifest 검증**

```bash
kubectl apply --dry-run=server -f deploy/serving/
```

Expected: 3개 리소스 모두 `(server dry run)` 표시와 함께 통과. ServiceMonitor는 CRD가
필요하므로 `--dry-run=client`가 아니라 `server`를 쓴다.

- [ ] **Step 6: 시크릿 누출 검사**

```bash
git diff --cached --check
git grep -nE '10\.10\.|BEGIN CERTIFICATE' -- deploy/serving/ || echo "노출 없음"
```

Expected: `노출 없음`. Redis private IP나 인증서 본문이 manifest에 들어가면 실패다.

- [ ] **Step 7: 커밋**

```bash
git add deploy/serving/
git commit -m "feat: Inference Server manifest 3종 추가 (#302)"
```

---

### Task 4: 문서 갱신

**Files:**
- Modify: `docs/TEAM_OPERATIONS_RUNBOOK.md`
- Modify: `docs/GITOPS_STRATEGY.md:104-106, 125-135`
- Modify: `terraform/admin/autoresearch-k8s/README.md`
- Modify: `terraform/admin/argocd-k8s/README.md`
- Modify: `docs/CHANGE_HISTORY.md`

- [ ] **Step 1: 런북에 운영 절차 추가**

`docs/TEAM_OPERATIONS_RUNBOOK.md`에 Inference Server 절을 추가한다. 포함할 내용:

1. 접근: `kubectl -n autoresearch port-forward svc/autoresearch-serving 8000:8000`
2. Secret 주입 절차(Task 5 Step 2의 명령 그대로)
3. E2E 실행(Task 6 Step 3의 명령 그대로)
4. **모델 교체 함정**: champion alias를 재지정해도 실행 중인 파드는 모델을 바꾸지
   않는다. 모델은 lifespan에서 1회만 로드되고 재조회 경로가 없다. 교체에는
   `kubectl -n autoresearch rollout restart deployment/autoresearch-serving`이
   필요하며, 이는 이미지 digest 롤백과 별개의 축이다.
5. digest 배포·롤백 절차

- [ ] **Step 2: GITOPS_STRATEGY 갱신**

두 곳을 고친다.

`104-106`의 Rollouts 서술에서 "실 서비스 적용은 앱 첫 배포 이슈에서 진행한다"를
갱신한다 — #302에서 **Deployment로 시작**하기로 했고 Rollout은 후속 이슈로 분리한다.
사유: dev replica 1에서 canary 가중치가 무의미하고, 첫 배포의 목표는 E2E 증명이다.

`125-135`의 이관 현황표에 행을 추가한다:

```markdown
| serving (#302) | 배포 구성 | 신규 배포(adopt 아님). `deploy/serving` **plain 매니페스트**(Deployment/Service/ServiceMonitor) + `autoresearch-k8s` root(ns/KSA/NP), ArgoCD Application manual sync. 이미지=앱 저장소 release.yml이 GAR에 push한 digest. Redis endpoint는 operator 주입 Secret |
```

- [ ] **Step 3: root README 갱신**

`terraform/admin/autoresearch-k8s/README.md`에 추가:
- `autoresearch-serving-redis` Secret 주입 절차와 값의 출처(terraform output)
- NetworkPolicy에 MLflow 5000 egress가 추가된 이유

`terraform/admin/argocd-k8s/README.md`에 추가:
- serving Application과 AppProject destination 추가
- `serving_target_revision` pin 방법

- [ ] **Step 4: CHANGE_HISTORY 요약**

`docs/CHANGE_HISTORY.md`에 결정 요약을 추가한다: 이미지 소유 경계(앱 저장소 빌드 /
infra digest 소비), Deployment 우선·Rollout 후속, liveness 분리 계약, IAM 추가 없음.

- [ ] **Step 5: 검증**

```bash
git diff --check
```

Expected: 출력 없음(공백 오류 없음).

- [ ] **Step 6: 커밋**

```bash
git add docs/ terraform/admin/autoresearch-k8s/README.md terraform/admin/argocd-k8s/README.md
git commit -m "docs: Inference Server 배포·E2E·모델 교체 절차 문서화 (#302)"
```

---

### Task 5: 운영 적용 — **사용자 승인 필요**

> 이 Task는 실제 GCP/GKE 리소스를 변경한다. 사용자가 명확히 요청하기 전에 실행하지 않는다.

**Interfaces:**
- Consumes: Task 1~3의 merge된 코드
- Produces: 실행 중인 `autoresearch-serving` 파드. Task 6이 이를 검증한다.

- [ ] **Step 1: plan으로 의도치 않은 replace/destroy가 없는지 확인**

```bash
terraform -chdir=terraform/admin/argocd-k8s plan
terraform -chdir=terraform/admin/autoresearch-k8s plan
```

Expected: `argocd-k8s`는 AppProject in-place update + Application 1개 create.
`autoresearch-k8s`는 NetworkPolicy in-place update. **destroy나 replace가 있으면
중단하고 원인을 조사한다.**

- [ ] **Step 2: Redis 접속 Secret 주입**

```bash
REDIS_HOST=$(terraform -chdir=terraform/envs/dev output -raw redis_discovery_address)
REDIS_PORT=$(terraform -chdir=terraform/envs/dev output -raw redis_discovery_port)
kubectl -n autoresearch create secret generic autoresearch-serving-redis \
  --from-literal=REDIS_HOST="$REDIS_HOST" \
  --from-literal=REDIS_PORT="$REDIS_PORT"
```

Expected: `secret/autoresearch-serving-redis created`.
값을 화면·로그·PR에 출력하지 않는다.

- [ ] **Step 3: Terraform apply**

```bash
terraform -chdir=terraform/admin/autoresearch-k8s apply
terraform -chdir=terraform/admin/argocd-k8s apply
```

NetworkPolicy를 먼저 적용해 파드가 뜰 때 MLflow 경로가 이미 열려 있게 한다.

- [ ] **Step 4: ArgoCD diff 확인 후 manual sync**

```bash
kubectl -n argocd get application serving -o jsonpath='{.status.sync.status}{"\n"}'
```

Expected: `OutOfSync`. ArgoCD UI에서 diff를 검토한 뒤 sync한다. auto-sync·prune·
self-heal은 켜지 않는다.

- [ ] **Step 5: 파드 Ready 확인**

```bash
kubectl -n autoresearch rollout status deployment/autoresearch-serving --timeout=360s
kubectl -n autoresearch get pod -l app.kubernetes.io/name=autoresearch-serving
```

Expected: `1/1 Running`. startupProbe가 최대 5분을 허용하므로 timeout을 360s로 둔다.

실패 시 진단 순서:
```bash
kubectl -n autoresearch logs -l app.kubernetes.io/name=autoresearch-serving --tail=50
kubectl -n autoresearch describe pod -l app.kubernetes.io/name=autoresearch-serving
```
`Reranking runtime initialization failed: phase=model`이면 MLflow 경로(Task 2)를,
`phase=feature_store`면 Redis Secret(Step 2)이나 CA IAM을 의심한다.

- [ ] **Step 6: 실사용 리소스 측정**

```bash
kubectl -n autoresearch top pod -l app.kubernetes.io/name=autoresearch-serving
```

memory가 limit 2Gi에 근접하면 limit을 올리고, 512Mi 미만이면 request를 낮추는 후속
커밋을 만든다. 측정값을 PR 본문에 기록한다.

---

### Task 6: E2E 검증과 롤백 검증 — **사용자 승인 필요**

**Interfaces:**
- Consumes: Task 5의 실행 중인 Service
- Produces: 이슈 #302 완료 조건 12개의 판정 근거

- [ ] **Step 1: materialize된 실제 ID 확인**

임의로 만든 ID는 online store에 피처가 없어 실패한다. 실제 materialize된 ID를 offline
store에서 조회해 쓴다:

2026-07-23 조회로 확인한 실제 피처 테이블은 `user_dynamic_feature`,
`user_static_feature`, `user_category_similarity`, `video_feature` 4종이다.

```bash
bq query --project_id=ar-infra-501607 --use_legacy_sql=false --format=csv \
  'SELECT user_id FROM `ar-infra-501607.feast_offline_store.user_dynamic_feature`
   ORDER BY event_timestamp DESC LIMIT 3'

bq query --project_id=ar-infra-501607 --use_legacy_sql=false --format=csv \
  'SELECT video_id FROM `ar-infra-501607.feast_offline_store.video_feature`
   ORDER BY event_timestamp DESC LIMIT 5'
```

2026-07-23 기준 조회 결과(변할 수 있으므로 실행 시 재조회할 것):

| 종류 | 값 |
|---|---|
| user_id | `vu_0823`, `vu_0948`, `vu_0755` |
| video_id | `X2VMsizee2M`, `sD61ZG10TlQ`, `XMcCN0R_Ifk`, `2AtpQpmpXTc`, `Y9kMIkohLVw` |

**주의: 위는 offline store 기준이다.** online store(Redis)에 materialize되지
않았으면 `/rerank`가 피처를 찾지 못한다. 앱 저장소
`docs/runbooks/2026-07-15-feast-redis-gke-validation.md`의 materialize 확인 절차와
대조하고, #203 검증에서 쓴 ID가 남아 있으면 그것을 우선 사용한다.

- [ ] **Step 2: port-forward**

```bash
kubectl -n autoresearch port-forward svc/autoresearch-serving 8000:8000
```

- [ ] **Step 3: 앱 저장소 검증기 실행**

앱 저장소(`SKYAHO/Autoresearch`) 체크아웃에서:

```bash
python scripts/verify_serving_e2e.py --base-url http://127.0.0.1:8000 \
    --user-id <실제 user id> --video-ids <실제 video id들>
```

Expected: 전 항목 통과. 이 실행이 완료 조건 6개를 판정한다 — `/healthcheck` 200 +
`{"status":"ok"}`, `/rerank` 200, video ID 순서 보존, 각 item의 `video_id`/
`ctr_score`/`model_id`, `/metrics` 계측.

- [ ] **Step 4: `rerank_model_ready` 확인**

```bash
curl -s http://127.0.0.1:8000/metrics | grep -E '^rerank_model_ready'
```

Expected: `rerank_model_ready 1.0`. `0`이면 모델 또는 Feast 초기화가 실패한 것이므로
Task 5 Step 5의 진단 순서를 따른다.

- [ ] **Step 5: Prometheus 수집 확인**

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
curl -s 'http://127.0.0.1:9090/api/v1/targets?state=active' \
  | grep -c autoresearch-serving
```

Expected: 1 이상. 0이면 ServiceMonitor의 `release: kube-prometheus-stack` 라벨을
확인한다(설계서 "관측성" 참조).

- [ ] **Step 6: 재시작 후 재현성 확인**

```bash
kubectl -n autoresearch rollout restart deployment/autoresearch-serving
kubectl -n autoresearch rollout status deployment/autoresearch-serving --timeout=360s
```

port-forward를 다시 걸고 Step 3을 반복한다. Expected: 동일하게 전 항목 통과 —
Workload Identity, CA 조회, 모델 로드, Feast 조회가 재시작 후에도 정상임을 증명한다.

- [ ] **Step 7: digest 롤백 검증**

이전 digest로 되돌리는 커밋을 만들고 sync한 뒤, 파드가 그 digest로 뜨는지 확인한다:

```bash
kubectl -n autoresearch get pod -l app.kubernetes.io/name=autoresearch-serving \
  -o jsonpath='{.items[0].spec.containers[0].image}{"\n"}'
```

Expected: 되돌린 digest와 일치. 확인 후 최신 digest로 복귀한다. 이슈 완료 조건이
"실제로 검증"을 요구하므로 문서화만으로 대체하지 않는다.

> 이전 digest가 없으면(최초 배포) 이 Step은 #266이 두 번째 이미지를 만든 뒤 수행한다.
> 그때까지는 완료 조건 미충족으로 남겨두고 PR 본문에 사유를 기록한다.

- [ ] **Step 8: 결과 기록**

측정한 리소스 사용량, E2E 결과, 롤백 검증 결과를 PR 본문과
`docs/CHANGE_HISTORY.md`에 기록한다.

---

## 검증 체크리스트

- [ ] `fmt -check` / `init -backend=false` / `validate` — argocd-k8s, autoresearch-k8s
- [ ] `kubectl apply --dry-run=server -f deploy/serving/` 통과
- [ ] `git grep`으로 Redis private IP·인증서 본문이 manifest에 없음을 확인
- [ ] (apply 후) plan에 의도치 않은 replace/destroy 없음
- [ ] (apply 후) 파드 `1/1 Running`, `rerank_model_ready 1`
- [ ] (apply 후) `verify_serving_e2e.py` 전 항목 통과
- [ ] (apply 후) 재시작 후 동일 검증 재통과
- [ ] (apply 후) Prometheus active target에 serving 등장
- [ ] (apply 후) 이전 digest 롤백 실제 검증
- [ ] 외부 LoadBalancer/Ingress 미생성 확인 (`kubectl get svc -A --field-selector spec.type=LoadBalancer`)
- [ ] IAM 변경 0건 확인 (`terraform/envs/dev`에 diff 없음)

## 롤백

| 변경 | 되돌리는 방법 |
|---|---|
| 이미지 digest | 이전 digest 커밋 → sync |
| Deployment/Service/ServiceMonitor | `kubernetes_manifest.application_serving` 제거 후 apply |
| AppProject destination | `destinations`에서 `app_namespace` 블록 제거 후 apply |
| NetworkPolicy MLflow egress | 해당 egress 블록 2개 제거 후 apply. 기존 파드 통신 영향 없음 |
| operator Secret | `kubectl -n autoresearch delete secret autoresearch-serving-redis` |

## 비용 영향

requests 250m/1Gi가 `dev-default` 노드 여유(1169m CPU / 5.8Gi memory) 안에 들어가
노드 증설이 없다. 신규 고정비는 사실상 0이며, 기존 GKE·Redis·MLflow를 재사용한다.
Task 5 Step 6의 실측 후 request를 조정하면 여유가 더 확보된다.
