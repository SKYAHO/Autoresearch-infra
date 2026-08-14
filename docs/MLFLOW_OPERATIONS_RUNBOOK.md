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
| 앱 배포 | ArgoCD Application `mlflow`(source `deploy/mlflow`, automated sync #460 — prune 없음) |
| 이미지 | GAR `autoresearch-mlflow`(앱 `deploy/mlflow/Dockerfile`을 인프라 Cloud Build로 빌드) |
| backend | Cloud SQL `autoresearch-dev-pg`, DB `mlflow`, user `mlflow`(private IP) |
| artifact | GCS `autoresearch-505505-autoresearch-mlflow-artifacts`, **proxy 모드**(`--serve-artifacts`) |
| Service | `mlflow.mlflow:5000`(ClusterIP, **내부 전용**) |
| UI 인증(#232) | 앞단 **OAuth2-proxy**(`mlflow-oauth-proxy:4180`), Google 로그인 + 허용 이메일 목록. Secret `mlflow-oauth` |
| 시크릿 | DB 비번=Secret Manager `autoresearch-dev-mlflow-db-password`, pod 주입=K8s Secret `mlflow-db` |

책임 경계: 이미지·런타임은 앱 저장소(`SKYAHO/Autoresearch` `deploy/mlflow`), GCP
리소스·배포는 인프라. GCS 인증은 WI로 MLflow 서버에만(클라이언트 자격 없음).

## 접속 (OAuth2-proxy 인증, #232)

UI/API는 ClusterIP라 외부 노출이 없다. 접근은 **OAuth2-proxy(4180)로 port-forward**
한다. proxy가 Google 로그인 + 허용 이메일 목록으로 인증한 뒤 MLflow로 프록시한다.
목록 밖 Google 계정은 거부된다("정해진 계정만").
허용 목록은 `mlflow-oauth` Secret의 `authenticated-emails` 키에서 주입되며,
MLflow manifest는 이 파일만 이메일 접근 제한으로 사용한다.

MLflow ArgoCD Application은 main 머지 뒤 자동 sync하므로, **PR 머지 전** operator가
Secret 형식과 항목 수만 확인한다(값은 출력하지 않는다). 성공한 `entries=N` 결과만 PR에
기록한다. 실패하면 머지하지 말고 Secret의 `authenticated-emails`를 실제 팀원 이메일
한 줄씩으로 수정한 뒤 다시 확인한다.

```bash
kubectl -n mlflow get secret mlflow-oauth \
  -o jsonpath='{.data.authenticated-emails}' | base64 -d |
  awk 'BEGIN { ok=1; n=0 } { sub(/\r$/, ""); if ($0 == "" || $0 ~ /^#/) next; if ($0 !~ /^[^[:space:]@,"]+@[^[:space:]@,"]+$/) ok=0; n++ } END { if (!ok || n == 0) exit 1; print "authenticated-emails format OK, entries=" n }'
```

이 preflight는 **형식과 항목 수만** 보장한다. 목록이 현재 팀 구성과 일치하는지,
초기 예시 주소(`someone@example.com` 등)가 남아 있지 않은지는 검사하지 않는다.
`--email-domain=*` 제거 이후 이 목록이 유일한 접근 경계이므로, 목록에서 빠진 팀원은
로그인이 막히고 남아 있는 옛 주소는 계속 허용된다. `entries=N`이 예상 인원과 다르면
값을 출력하지 말고 인원수로 대조한 뒤 진행한다. 예시 주소 잔존은 값 노출 없이 아래로
확인한다(`placeholder_like=0`이어야 한다).

```bash
kubectl -n mlflow get secret mlflow-oauth \
  -o jsonpath='{.data.authenticated-emails}' | base64 -d |
  awk 'BEGIN{ph=0;other=0} { sub(/\r$/,""); if($0==""||$0~/^#/) next; if ($0 ~ /@example\.(com|org|net)$/ || $0 ~ /^(someone|user|admin)@/) ph++; else other++ } END{ print "placeholder_like=" ph "  other=" other }'
```

허용 목록에서 사용자를 제거할 때는 `authenticated-emails`를 갱신한 뒤
`mlflow-oauth-proxy` rollout restart와 완료 확인을 수행한다. oauth2-proxy v7.7.1은
보호된 요청마다 세션 이메일을 allowlist로 재검사하므로, 제거된 사용자는 새 목록이
반영된 pod에 다음 요청을 보낼 때 cookie가 삭제되고 403으로 거부된다. 계정 제거에는
cookie-secret 회전이 필요하지 않다. 전체 사용자의 강제 재로그인이나 cookie 유출 대응은
`mlflow-k8s` README의 **전원 세션 무효화** 절차를 따른다.

ArgoCD 자동 sync와 `/ping` probe·rollout 성공은 Google 계정의 실제 인가 결과를
검증하지 않는다. 머지 후에는 허용 계정의 로그인 성공과 미허용 계정의 403을 각각
smoke test로 확인한다. 전원 403을 발견하면 UI로 복구하지 말고, operator가
`mlflow-k8s` README의 `mlflow-oauth` Secret 갱신 절차로 정확한 목록을 복원한 뒤
`kubectl rollout restart/status deployment/mlflow-oauth-proxy -n mlflow`를 실행한다.
Secret은 GitOps 관리 대상이 아니므로 이 복구에 ArgoCD manifest rollback은 필요 없다.

접속 경로는 두 가지다(둘 다 브라우저는 `http://localhost:4180`).

**(A) Bastion 터널 → 내부 ILB (#244, 기본 권장).** Airflow(#48)와 동일 패턴.

```bash
gcloud compute ssh autoresearch-dev-bastion \
  --zone asia-northeast3-a --project autoresearch-505505 --tunnel-through-iap \
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
- OAuth client 자격의 **정본은 Secret Manager**(`autoresearch-dev-mlflow-oauth-client-id`,
  `...-client-secret`)이고 K8s Secret `mlflow-oauth`는 그 사본이다. 주입·갱신 절차는
  `terraform/admin/mlflow-k8s/README.md`의 `mlflow-oauth` Secret 절차를 따르고,
  변경 후 `kubectl rollout restart deployment/mlflow-oauth-proxy -n mlflow`.
- client를 재발급하면 id/secret이 한 쌍으로 바뀐다. Secret Manager에 새 version을 올린
  뒤 K8s Secret까지 전파해야 하며, secret만 바꾸면 `invalid_client`로 로그인이 막힌다.
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
mlflow.set_tracking_uri("http://localhost:5000")   # kubectl -n mlflow port-forward svc/mlflow 5000:5000 기준(#236 RBAC, oauth 미경유)
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
PW="$(gcloud secrets versions access latest --secret autoresearch-dev-mlflow-db-password --project autoresearch-505505)"
HOST="$(scripts/terraform-env --environment dev --root terraform/envs/dev output -raw cloud_sql_private_ip_address)"
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
- **artifact(GCS)**: 버킷 `prevent_destroy` + Object Versioning + **7일 soft delete**.
  실수 삭제 시 7일 내 복구 가능하며, training snapshot은 기본적으로 age 기반
  삭제하지 않는다.

### Content-addressed training snapshot (#464)

학습 CSV의 canonical 저장소는 MLflow artifact bucket 안의 다음 두 객체다. 새
bucket이나 MLflow Model Registry version을 만들지 않는다.

```text
gs://<bucket>/training-snapshots/by-hash/<64자리 hex>/training_dataset.csv
gs://<bucket>/training-snapshots/by-hash/<64자리 hex>/snapshot_manifest.json
```

`snapshot_manifest.json`에는 최소한 `sha256`, CSV object `gs://` URI,
`generation`, `size_bytes`, 생성 시각과 데이터셋 schema/row-count 메타데이터를
기록한다. generation은 GCS object version이며 SHA-256은 다운로드한 CSV bytes의
해시다. consumer는 두 값을 함께 확인해야 하며, 하나라도 manifest와 다르면 해당
학습·비교 실행을 실패시킨다.

publisher 계약은 다음 순서다.

1. CSV bytes의 SHA-256을 계산하고 canonical object 경로를 만든다.
2. CSV와 manifest를 generation `0` 조건으로 create-if-absent 업로드한다.
3. 이미 같은 digest의 객체가 있으면 overwrite하지 말고 기존 object를 읽어
   generation·size·SHA-256을 검증한 뒤 재사용한다.
4. 다른 bytes를 같은 digest 경로에 쓰려는 시도는 `objectCreator`만 가진
   `autoresearch-dev-airflow-batch` GSA에서 거부되어야 한다.

CSV create 이후 manifest create 전에 publisher가 종료될 수 있으므로 두 객체의
publish는 하나의 원자적 GCS 연산으로 간주하지 않는다. 재시도 시 precondition
failure가 발생하면 두 known URI를 직접 조회하여 CSV와 manifest가 모두 존재하고
digest·size·generation 검증을 통과할 때만 idempotent reuse한다. CSV만 존재하거나
manifest가 불일치하면 batch GSA는 overwrite/delete할 수 없으므로 실행을 실패시키고
운영자가 승인된 MLflow GSA 복구 절차로 partial object를 정리한 뒤 재시도한다.
generation `0` precondition으로 동일 bytes를 재업로드해도, 다른 bytes를 재업로드해도
GCS는 모두 `412 Precondition Failed`를 반환하므로 응답만으로 두 경우를 구분할 수
없다. publisher는 그 뒤 CSV와 manifest를 각각 GET하여 digest·size·generation을
검증해야 한다. 둘 다 일치하면 정상 reuse이고, manifest 404·digest 불일치·size
불일치면 오염/partial publish로 실패한다. 403은 권한 오류이므로 reuse 경로로
분류하지 않는다. publisher는 bucket listing이나 metadata reload에 의존하지 않고
known object URI의 GET을 사용한다. partial object 삭제·복구는 현재 bucket-wide
objectAdmin을 가진 MLflow 서버 GSA를 통한 승인된 운영 절차가 필요하다.

검증 consumer도 기존 `airflow/autoresearch-batch` KSA를 사용한다. Terraform output으로
bucket과 prefix를 확인하고, live 검증 승인 후 다음처럼 metadata·generation·hash를
확인한다(명령의 bucket/digest는 실제 값으로 치환한다).

```bash
SNAPSHOT_URI="gs://<bucket>/training-snapshots/by-hash/<digest>/training_dataset.csv"
gcloud storage objects describe "$SNAPSHOT_URI" --format='yaml(name,generation,size,md5Hash,crc32c)'
gcloud storage cp "$SNAPSHOT_URI" "/tmp/training_dataset.csv"
sha256sum /tmp/training_dataset.csv
```

권한 경계 검증은 batch workload에서 canonical prefix 생성·조회는 성공하고,
다른 bucket 또는 `training-snapshots/` 밖의 object 조회·삭제는 실패하는지 확인한다.
실제 GCS upload/delete 테스트는 Terraform apply 및 별도 운영 승인 이후에만 수행한다.

### Retention, 비용, rollback

- `mlflow_training_snapshot_retention_days = 0`이 기본값이다. 양수로 설정한
  환경에만 `training-snapshots/` live object age lifecycle이 적용된다. 재현성
  보존 정책을 합의하기 전에는 값을 변경하지 않는다. GCS `age`는 live object의
  생성 시각을 기준으로 계산하므로, 아직 run/model이 참조하는 오래된 snapshot도
  삭제될 수 있다. Terraform plan은 lifecycle 규칙 변경은 보여주지만 어떤 객체가
  삭제될지는 미리 나열하지 않는다.
- content address로 동일 CSV가 run마다 중복 저장되지 않지만, 기본 영구 보존은
  snapshot byte size × 고유 snapshot 수에 비례하는 GCS 저장 비용을 만든다. 향후
  retention을 줄일 때는 해당 snapshot을 참조하는 MLflow run·모델의 보존 기간을
  먼저 확인한다.
- 최근 삭제 객체는 soft delete 보존 기간 내 GCS restore 절차로 복구한다. Object
  Versioning으로 이전 generation이 남아 있으면 `gs://.../object#GENERATION`을
  source로 별도 복구 객체에 복사한 뒤 SHA-256과 manifest를 재검증한다. 원본
  canonical object를 직접 overwrite하지 않는다.
- Object Versioning은 버킷 전체 MLflow artifact에 적용되므로 noncurrent generation은
  기본 30일 lifecycle로 정리한다. snapshot은 overwrite하지 않는 publish 계약이므로
  정상적인 canonical snapshot generation은 이 정리 규칙에 의해 새로 생성되지 않는다.
- snapshot lifecycle로 삭제된 object를 consumer가 읽으면 known URI GET 단계에서
  404가 발생하고, manifest/해시 검증 단계까지 진행하지 못한다. lifecycle 삭제와
  미게시를 구분하려면 Cloud Audit Logs의 lifecycle/delete 기록과 MLflow run의
  snapshot manifest를 함께 확인한다. retention을 다시 `0`으로 바꾸면 향후
  자동 삭제는 중단되지만 이미 삭제된 object는 복구하지 않으며, 7일 soft delete
  또는 30일 noncurrent generation 복구 창 안에서 별도로 복구해야 한다.

복구 전후에는 다음 조건을 기록한다.

```text
restored object URI + generation + sha256 == snapshot_manifest.json의 값
```

Terraform plan에서는 기존 bucket이 replace/destroy되지 않고 versioning, lifecycle,
두 prefix IAM binding만 의도대로 변경되는지 확인한다. 실제 apply는 이슈 #464의
별도 명시 승인 뒤에만 실행한다.

## 배포·업데이트

이미지·매니페스트는 GitOps로 관리한다.

```bash
# 이미지 갱신: 앱 Dockerfile 변경 시 인프라 Cloud Build로 재빌드 후 deploy/mlflow의
# image digest를 새 값으로 PR → merge → ArgoCD sync.
# 수동 sync 트리거(긴급/선반영용 — 평시엔 main 머지로 자동, #460):
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
