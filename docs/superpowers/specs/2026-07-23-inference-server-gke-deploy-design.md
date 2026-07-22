# Inference Server GKE 실제 배포·E2E 검증 설계 (#302)

## 배경·목적

`SKYAHO/Autoresearch`의 FastAPI Inference Server를 임시 검증 Pod가 아니라 dev GKE의
상시 관리 대상 workload로 배포한다. 2026-07-23 임시 Pod 검증에서 Workload Identity,
Redis IAM AUTH+TLS, Secret Manager CA 조회, Feast `get_online_features`까지 성공했으나,
GAR에 serving 이미지가 없고 `autoresearch` namespace에 Deployment/Service가 없어
`POST /rerank`의 실제 인프라 E2E를 수행할 수 없다. 이 설계는 이미지 승격, workload,
네트워크, 관측성, 롤백 경로를 IaC와 운영 문서로 고정한다.

애플리케이션 코드는 범위 밖이다. 검증기(`scripts/verify_serving_e2e.py`)는 앱 저장소
PR #264로 이미 merge되어 있어 새로 만들지 않는다.

## 선행 사실 확인 (2026-07-23)

설계 전제를 실물로 확인했다.

| 항목 | 확인 결과 |
|---|---|
| MLflow Model Registry | `ctr-model@champion` → version 3 (READY, run `bf6498fd…`) |
| 모델 artifact 경로 | `model/lgbm_model.joblib`, `features/feature_columns.pkl`, `features/categorical_columns.pkl` 존재 |
| artifact 전송 경로 | `mlflow-artifacts:/` — MLflow 서버 경유. 파드의 GCS 직접 접근 불필요 |
| Redis CA secret | `autoresearch-dev-redis-server-ca` 존재 |
| Feast registry | `gs://ar-infra-501607-feast-registry/registry.db` 존재 |
| Prometheus selector | `serviceMonitorSelector={"matchLabels":{"release":"kube-prometheus-stack"}}`, namespace 제약 없음 |
| dev-default 노드 여유 | CPU 1169m, memory 5.8Gi (2751m/3920m, 7.78Gi/13.6Gi 사용 중) |
| `gke_app` GSA IAM | Redis·CA·Feast registry·WI 전부 기부여 — **추가 불필요** |

`RERANK_MODEL_SOURCE=registry`는 즉시 사용 가능하다. 앱 spec의 "registry alias 로드는
별도 작업" 서술은 pyfunc flavor 로드에 관한 것이고, 구현된 `_load_registry_model`은
alias→run_id 해석 후 기존 run artifact 다운로드를 재사용한다.

## 방식 선택

| 결정 지점 | 채택 | 기각 |
|---|---|---|
| 이미지 build/push | **앱 저장소 GitHub Actions** (`release.yml` + `application_pusher` SA, #187 재사용) | 인프라 Cloud Build(MLflow 방식) — 앱 파이프라인 이전이 전제된 잠정 경로 |
| workload 형태 | **Deployment + ArgoCD manual sync** | Argo Rollout — replica 1에서 canary 가중치가 무의미. 후속 이슈로 분리 |
| | | Terraform 직접 관리 — GITOPS_STRATEGY 책임 경계와 충돌 |
| manifest·digest 소유 | **infra repo `deploy/serving/`에 digest 하드코딩** | app repo 이관 — 앱 PR이 replica/resources를 바꿀 수 있게 됨. #302의 "배포는 이 저장소 소유"와 충돌 |
| | | kustomize `images` 분리 — 단일 이미지라 당장 이득 없이 복잡도만 추가 |
| Redis 접속 정보 | **operator 주입 Secret** | manifest 평문 — public 저장소이며 MLflow가 Cloud SQL private IP를 Secret으로 뺀 선례와 어긋남 |
| liveness | **`tcpSocket :8000`** | `httpGet /healthcheck` — 아래 "probe 계약" 참조 |

이미지 tag가 아니라 immutable digest를 배포 입력으로 쓴다. GitOps 전제상 digest는 git에
있어야 ArgoCD가 drift를 판정할 수 있고, 롤백이 git 이력으로 완결된다.

## 구성

```
앱 저장소 release.yml ──build/push──> GAR autoresearch-serving@sha256:...
                                          │ digest
                                          ▼
infra repo deploy/serving/ ──ArgoCD(manual sync)──> autoresearch ns
                                          │
      ┌───────────────────────────────────┼───────────────────────────┐
      ▼                                   ▼                           ▼
  MLflow svc:5000                    Redis PSC                 Secret Manager
  (alias 해석 + artifact)         (IAM AUTH + TLS)              (CA 번들)
```

### 신규 — `deploy/serving/`

| 파일 | 내용 |
|---|---|
| `deployment.yaml` | replica 1, digest 고정, KSA `autoresearch-app`, probe 3종 |
| `service.yaml` | ClusterIP :8000. 외부 LoadBalancer/Ingress 없음 |
| `servicemonitor.yaml` | `release: kube-prometheus-stack` 라벨 필수, path `/metrics` |

### 수정

| 파일 | 변경 |
|---|---|
| `terraform/admin/argocd-k8s/main.tf` | AppProject `destinations`에 `autoresearch` 추가(없으면 sync 거부) + `application_serving` |
| `terraform/admin/argocd-k8s/variables.tf` | `app_namespace`, `serving_target_revision` |
| `terraform/admin/autoresearch-k8s/main.tf` | NetworkPolicy에 MLflow egress |

## 설정과 시크릿 분리

**operator 주입 Secret `autoresearch-serving-redis`** — Git·Terraform state 어디에도 없음

| 키 | 출처 |
|---|---|
| `REDIS_HOST` | `terraform output redis_discovery_address` |
| `REDIS_PORT` | `terraform output redis_discovery_port` |

둘 다 같은 output에서 나오고 한 명령으로 생성되므로 함께 둔다. MLflow는 host만 Secret에
뒀으나, 여기서 분리하면 절차만 늘고 불일치 위험이 생긴다.

**manifest 평문** (비민감)

| 변수 | 값 |
|---|---|
| `GCP_PROJECT_ID` | `ar-infra-501607` |
| `REDIS_CA_SECRET_ID` | `autoresearch-dev-redis-server-ca` — id일 뿐이며 통제는 IAM |
| `MLFLOW_TRACKING_URI` | `http://mlflow.mlflow.svc.cluster.local:5000` |
| `RERANK_MODEL_SOURCE` | `registry` |
| `RERANK_REGISTRY_MODEL_NAME` | `ctr-model` |
| `RERANK_REGISTRY_ALIAS` | `champion` |
| `RERANK_FEATURE_REPO_PATH` | `feature_repo` |
| `GCS_REGISTRY_PATH` | `gs://ar-infra-501607-feast-registry/registry.db` |
| `GCS_STAGING_LOCATION` | `gs://ar-infra-501607-feast-staging/` |
| `BQ_DATASET` | `feast_offline_store` |

`BQ_DATASET`·`GCS_STAGING_LOCATION`은 online 조회에 쓰이지 않지만 `feature_store.yaml`이
`${VAR}` 치환으로 파싱하므로 없으면 초기화가 실패한다.

**어디에도 없음**: Redis TLS CA 본문. `REDIS_TLS_CA_PATH`를 비우면 앱이
`REDIS_CA_SECRET_ID`로 런타임에 Secret Manager에서 읽는다(`feature_repo/bootstrap.py`).

## probe 계약

```yaml
startupProbe:   httpGet /healthcheck   periodSeconds 10  failureThreshold 30   # 최대 5분
readinessProbe: httpGet /healthcheck   periodSeconds 10
livenessProbe:  tcpSocket :8000        periodSeconds 20  failureThreshold 3
```

**불변식: 의존성 상태는 readiness가, 프로세스 생존은 liveness가 담당한다.**
liveness를 `/healthcheck`에 연결하지 않는다.

근거는 두 가지다.

첫째, 앱이 `/healthcheck`를 실시간 의존성 조회로 전환할 예정이다(2026-07-23 확인).
그 시점에 liveness가 결합돼 있으면 Redis 장애가 재시작 루프로 증폭된다. 재시작이
반복되면 CrashLoopBackOff가 간격을 최대 5분까지 벌리므로, 의존성이 복구돼도 파드가
backoff 대기 중이면 복귀가 그만큼 늦어진다. readiness는 다음 검사(10초 이내)에 복귀한다.
같은 장애에서 복구가 10초 대 최대 5분이고, 후자는 재시작마다 모델을 다시 받으므로
Redis 장애를 MLflow 부하로 전파한다.

둘째, startupProbe는 별개의 문제를 막는다. lifespan이 초기화 예외를 삼키고 그대로
`yield`하므로(`except Exception: logger.error(...)`), 모델 로드가 실패해도 프로세스는
`Running`·`Ready` 상태로 영구히 503만 반환하고 재시도 경로가 없다. startupProbe가 이를
재시작으로 전환해 가시화하고, 재시작이 곧 재시도가 된다. startupProbe는 최초 성공 이후
재실행되지 않으므로 후속 장애에서 루프를 만들지 않는다.

liveness를 `httpGet /livez`로 바꾸려면 앱에 의존성 무관 endpoint가 필요하다. 현재는
`tcpSocket`이 앱 저장소 변경 없이 같은 분리를 얻으므로 채택하고, 필요해지면 한 줄로
교체한다.

## 네트워크

기존 egress는 Redis PSC, GKE metadata, DNS, Cloud SQL, 443, 동일 namespace를 허용한다.
MLflow는 `mlflow` namespace의 ClusterIP:5000이라 **어느 규칙에도 걸리지 않으므로**
`RERANK_MODEL_SOURCE=registry`에서 모델 로드가 막힌다. 기존 DNS 규칙과 동일한 이중
패턴으로 추가한다 — 이 클러스터의 Calico는 service 트래픽을 DNAT 이전에 평가하므로
ClusterIP VIP는 services CIDR(`172.16.128.0/24`)로 열고, DNAT 이후 평가하는 dataplane을
위해 namespace selector 규칙을 함께 둔다.

services CIDR:5000을 여는 범위는 해당 포트를 쓰는 서비스가 MLflow뿐이라 수용한다.

`policy_types = ["Egress"]`이므로 ingress는 제한되지 않는다. Prometheus 스크랩과
port-forward에 추가 규칙이 필요 없다.

## 관측성

ServiceMonitor에 **`release: kube-prometheus-stack` 라벨이 반드시 필요하다.** Prometheus
설정을 직접 조회해 확인했다. namespace 제약은 없으나 라벨이 없으면 에러 없이 조용히
무시되며, 완료 조건의 `rerank_model_ready 1` 확인이 여기서 막힌다.

## 결정

- **IAM 추가 없음.** `gke_app` GSA가 Redis `redis.connection`, CA secretAccessor, Feast
  registry objectUser+legacyBucketReader, WI를 이미 보유한다. 모델 artifact가 MLflow
  경유라 GCS 직접 권한도 불필요하다. "최소 권한" 조건을 아무것도 추가하지 않음으로써
  충족한다.
- **replica 1, requests 250m/1Gi, limits 1000m/2Gi.** requests가 기존 노드 여유
  (1169m/5.8Gi) 안이라 노드 증설이 없고 신규 고정비는 사실상 0이다. 이 컨테이너는
  Python 3.12에 lightgbm·pandas·pyarrow·feast·mlflow 클라이언트와 모델을 올려
  MLflow(실사용 442Mi)보다 무거우므로, #229 OOM 재현을 피하려 limit을 2Gi로 둔다.
  첫 배포 후 `kubectl top`으로 측정해 조정한다.
- **sync는 manual, prune·self-heal off.** GITOPS_STRATEGY 초기 원칙.
- **외부 노출 없음.** ClusterIP만 두고 접근은 port-forward. public endpoint는 범위 밖이며
  필요 시 인증·인가·rate limit·비용을 포함한 별도 이슈로 분리한다.

## 운영 함정

**champion alias를 재지정해도 실행 중인 파드는 모델을 바꾸지 않는다.** 모델은 lifespan에서
1회만 로드되고 재조회 경로가 없다. 모델 교체에는 파드 재시작이 필요하며, 이는 이미지
digest 롤백과 별개의 축이다. 런북에 명시한다.

## 배포·검증·롤백

| 구분 | 절차 |
|---|---|
| 배포 | 앱 `release.yml`이 이미지 push → digest 확보 → infra repo PR로 `deployment.yaml` digest 갱신 → merge → ArgoCD diff 확인 후 manual sync |
| 롤백 | 이전 digest로 되돌리는 커밋 → sync. git 이력이 곧 배포 이력 |
| 비상 | Application 제거(Terraform) 또는 replica 0 |

E2E는 앱 저장소 검증기를 그대로 쓴다.

```bash
kubectl -n autoresearch port-forward svc/autoresearch-serving 8000:8000
# 앱 저장소에서
python scripts/verify_serving_e2e.py --base-url http://127.0.0.1:8000 \
    --user-id <materialized> --video-ids <materialized...>
```

완료 조건 12개 중 6개(`/healthcheck` 200, `/rerank` 200, video ID 순서 보존, 각 item의
`video_id`/`ctr_score`/`model_id`, `rerank_model_ready 1`)가 이 실행으로 판정된다. 파드
재시작 후 1회 더 실행해 재현성 조건을 덮는다. materialize된 실제 user/video ID는 #203
검증분을 구현 단계에서 재확인한다.

## 리스크·영향

| 항목 | 평가 |
|---|---|
| 비용 | 노드 증설 없음. 신규 고정비 사실상 0 |
| OOM | 실사용 미지. limit 2Gi로 완화하고 배포 후 측정·조정 |
| MLflow 의존 | MLflow 장애 시 신규 파드 기동 불가(startup 실패 → CrashLoop). 기존 파드는 모델을 메모리에 보유해 영향 없음 |
| IAM | 추가 없음 — 권한 확대 0 |
| 외부 노출 | 없음 |

## 롤백

| 변경 | 되돌리는 방법 |
|---|---|
| 이미지 digest | 이전 digest 커밋 → sync |
| Deployment/Service/ServiceMonitor | ArgoCD Application 제거(Terraform) 후 apply |
| AppProject destination | `destinations`에서 `autoresearch` 제거 후 apply |
| NetworkPolicy MLflow egress | 해당 egress 블록 제거 후 apply. 기존 파드 통신에는 영향 없음 |
| operator Secret | `kubectl delete secret autoresearch-serving-redis` |

## 후속 분리 항목

- Argo Rollout 적용(canary 수동 promote) — replica 2 이상이 전제
- 앱 저장소 `release.yml`의 serving 이미지 빌드 추가(동반 이슈)
- digest 갱신 자동화 — 배포 빈도가 올라간 뒤 판단
- 앱 `/healthcheck` 실시간 의존성 조회 전환 시 probe 재검토

## 문서 갱신 (같은 PR)

- `docs/TEAM_OPERATIONS_RUNBOOK.md` — 접근·Secret 주입·E2E·모델 교체 절차
- `docs/GITOPS_STRATEGY.md` — 이관 현황 표에 serving 추가, Rollouts 서술 갱신
- `terraform/admin/autoresearch-k8s/README.md` — Secret 주입, NetworkPolicy 변경
- `terraform/admin/argocd-k8s/README.md` — Application 추가
- `docs/CHANGE_HISTORY.md` — 결정 요약
