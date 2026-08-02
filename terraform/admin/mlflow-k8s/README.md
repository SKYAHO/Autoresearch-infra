# terraform/admin/mlflow-k8s

MLflow tracking server의 Kubernetes 경계(별도 state). #91 설계, #94 배포.

- namespace `mlflow` + KSA `mlflow`(Workload Identity → GSA `autoresearch-dev-mlflow`)
- deny-by-default egress NetworkPolicy(Cloud SQL PSA 5432, GCS/API 443, DNS, WI metadata)
- (#236) Model Training 담당자용 namespace 범위 `view` + `pods/portforward` RBAC

chart/앱(MLflow Deployment)은 이 root가 아니라 **ArgoCD Application(`deploy/mlflow`)**이
배포한다. 이 root는 플랫폼 경계만 소유한다("Terraform=경로, ArgoCD=앱").

## apply

```bash
terraform -chdir=terraform/admin/mlflow-k8s init
terraform -chdir=terraform/admin/mlflow-k8s apply \
  -var project_id=<PROJECT_ID> -var private_services_cidr=<PSA_CIDR>
```

## operator secret 주입 (배포 전 필수)

MLflow pod는 Cloud SQL backend에 접속하려면 **host(private IP)와 비밀번호**가 필요하다.
둘 다 공개 저장소 매니페스트에 넣지 않고, 운영자가 K8s Secret `mlflow-db`로 주입한다.
비밀번호는 Secret Manager `autoresearch-dev-mlflow-db-password`에, host는 Terraform
output(`cloud_sql_private_ip_address`)에 있다. 시크릿을 명령행에 노출하지 않도록
`--from-env-file`로 주입한다(#213 패턴).

```bash
umask 077
env_file="$(mktemp)"
trap 'rm -f "$env_file"' EXIT

PW="$(gcloud secrets versions access latest --secret autoresearch-dev-mlflow-db-password --project <PROJECT_ID>)"
HOST="$(terraform -chdir=terraform/envs/dev output -raw cloud_sql_private_ip_address)"
printf 'POSTGRES_PASSWORD=%s\nPOSTGRES_HOST=%s\n' "$PW" "$HOST" > "$env_file"
unset PW

kubectl create secret generic mlflow-db -n mlflow --from-env-file="$env_file"
rm -f "$env_file"; trap - EXIT
```

이후 ArgoCD가 `deploy/mlflow` Application을 sync하면 pod가 이 Secret을 참조해 기동한다.

## operator secret 주입 — mlflow-oauth (#232 UI 인증)

UI 앞단 OAuth2-proxy는 Google OAuth client 자격·cookie 비밀·허용 이메일 목록이
필요하다. 모두 공개 저장소에 두지 않고 K8s Secret `mlflow-oauth`로 주입한다.
값이 명령행·히스토리에 남지 않도록 파일 기반(`--from-file`)으로 만든다.
배포 manifest는 `--authenticated-emails-file`만 이메일 접근 제한으로 사용하며,
목록 밖 Google 계정은 proxy에서 거부된다.

선행: GCP 콘솔에서 OAuth client(웹) 생성, redirect URI
`http://localhost:4180/oauth2/callback` 등록. **발급 직후 client id와 client secret을
Secret Manager에 넣는다** — 이 두 secret이 정본이고, K8s Secret은 그 사본이다.

```bash
# 정본 등록(값은 stdin으로만 전달 → 붙여넣기 후 Enter, Ctrl+D)
gcloud secrets versions add autoresearch-dev-mlflow-oauth-client-id \
  --project "$PROJECT_ID" --data-file=-
gcloud secrets versions add autoresearch-dev-mlflow-oauth-client-secret \
  --project "$PROJECT_ID" --data-file=-
```

주입은 Secret Manager에서 읽어 파일로 떨어뜨린다(`--from-file`). 값이 명령행·셸
히스토리에 남지 않고, runbook에 client id를 하드코딩하지 않으므로 재발급 때 문서와
클러스터가 갈리지 않는다.

```bash
(
set -euo pipefail
umask 077
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT

# client id/secret: Secret Manager 정본에서 내려받기(끝 개행 제거).
# 주의: 파이프의 exit code는 tr 것이라 version이 없어도 조용히 빈 파일이 된다 —
# test -s 가드로 빈 값 주입을 차단한다(terraform은 컨테이너만 만들고 payload는
# 운영자가 versions add로 넣는 구조).
for k in client-id client-secret; do
  gcloud secrets versions access latest \
    --secret "autoresearch-dev-mlflow-oauth-$k" --project "$PROJECT_ID" \
    | tr -d '\n' > "$d/$k"
  test -s "$d/$k" || { echo "ERROR: $k 정본이 비어 있음 — 'gcloud secrets versions add'로 payload 먼저 등록"; exit 1; }
done

# Secret 갱신은 server-side apply를 쓴다. client-side apply는 전체 payload를
# kubectl.kubernetes.io/last-applied-configuration 어노테이션에 그대로 복제해
# 시크릿 사본이 하나 더 생기고 옛 값이 남는다(현재 두 Secret에는 이 어노테이션이
# 없음을 실측 확인).
# cookie 비밀과 allowlist: Secret 없음과 인증/연결 실패를 구분한다.
# 기존 Secret을 재실행할 때는 두 값을 보존한다. 최초 생성 또는 의도적 allowlist 변경만
# ALLOWLIST_FILE에 실제 승인 이메일 파일(한 줄에 하나, 로컬 0600)을 지정한다.
if kubectl -n mlflow get secret mlflow-oauth --ignore-not-found -o name > "$d/existing-secret"; then
  if test -s "$d/existing-secret"; then
    # authenticated-emails는 여기서 읽지 않는다. 목록이 비어 전원 403이 된
    # 상황이 바로 이 절차로 복구해야 하는 경우인데, 무조건 읽고 test -s로
    # 막으면 ALLOWLIST_FILE 분기에 닿기도 전에 죽어 복구가 불가능해진다.
    for k in cookie-secret; do
      kubectl -n mlflow get secret mlflow-oauth -o "jsonpath={.data.$k}" \
        | base64 -d > "$d/$k"
      test -s "$d/$k" || { echo "ERROR: mlflow-oauth.$k 없음"; exit 1; }
    done
  else
    python3 -c 'import os,base64,sys;sys.stdout.write(base64.urlsafe_b64encode(os.urandom(32)).decode())' > "$d/cookie-secret"
  fi
else
  echo "ERROR: mlflow-oauth 존재 여부를 읽지 못함 — context/인증을 확인"; exit 1
fi

# ALLOWLIST_FILE이 지정되면 기존 목록 대신 그 파일을 사용한다. 지정하지 않은
# 재실행은 기존 목록을 보존하며, Secret이 없으면 명시적 파일 없이는 생성하지 않는다.
if test -n "${ALLOWLIST_FILE:-}"; then
  test -f "$ALLOWLIST_FILE" || { echo "ERROR: ALLOWLIST_FILE을 읽을 수 없음"; exit 1; }
  cp "$ALLOWLIST_FILE" "$d/authenticated-emails"
else
  test -s "$d/existing-secret" \
    || { echo "ERROR: 최초 생성에는 ALLOWLIST_FILE=/안전한/경로/approved-emails 지정 필요"; exit 1; }
  kubectl -n mlflow get secret mlflow-oauth -o 'jsonpath={.data.authenticated-emails}' \
    | base64 -d > "$d/authenticated-emails"
  test -s "$d/authenticated-emails" \
    || { echo "ERROR: 기존 authenticated-emails가 비어 있음 — ALLOWLIST_FILE로 명시 지정 필요"; exit 1; }
fi
awk 'BEGIN { ok=1; n=0 } { sub(/\r$/, ""); if ($0 == "" || $0 ~ /^#/) next; if ($0 !~ /^[^[:space:]@,"]+@[^[:space:]@,"]+$/) ok=0; n++ } END { if (!ok || n == 0) exit 1; print "authenticated-emails format OK, entries=" n }' "$d/authenticated-emails" \
  || { echo "ERROR: authenticated-emails는 빈 줄·# 주석 외에 한 줄당 이메일 하나여야 함"; exit 1; }

kubectl create secret generic mlflow-oauth -n mlflow \
  --from-file=client-id="$d/client-id" \
  --from-file=client-secret="$d/client-secret" \
  --from-file=cookie-secret="$d/cookie-secret" \
  --from-file=authenticated-emails="$d/authenticated-emails" \
  --dry-run=client -o yaml | kubectl apply --server-side --force-conflicts -f -
rm -rf "$d"; trap - EXIT

kubectl rollout restart deployment/mlflow-oauth-proxy -n mlflow
kubectl rollout status deployment/mlflow-oauth-proxy -n mlflow --timeout=120s
)
```

client 자격만 갱신할 때는 `ALLOWLIST_FILE` 없이 위 블록을 다시 실행한다. 기존
`authenticated-emails`와 `cookie-secret`이 모두 보존된다. 최초 생성 또는 이메일 목록을
의도적으로 바꿀 때만 승인 이메일만 담은 로컬 비추적 파일을 준비해
`ALLOWLIST_FILE=/안전한/경로/approved-emails`로 지정한 뒤 위 블록을 실행하고
`rollout restart`한다. 파일은 저장소·채팅·명령행 인자에 넣지 않는다.

갱신 시 주의:

- **cookie-secret 보존은 위 블록이 자동 처리한다**(기존 K8s Secret 값 재사용, 최초에만
  생성). 길이가 32바이트가 아니면 oauth2-proxy가 기동에 실패하고, 새로 만들면 전원
  재로그인이 필요하다.
- **client 재발급 시 id/secret 정본을 둘 다 갱신한다.** 재발급은 한 쌍으로 바뀌므로
  secret만 교체하면 `invalid_client`로 로그인이 막힌다 — 이번 정본화(#420)의 계기가
  된 실사고 경로다.
- 반영 확인은 값 노출 없이 **id·secret 두 키 모두** 해시로 대조한다(어긋나기 쉬운 쪽은
  오히려 id였다).

  ```bash
  for k in client-id client-secret; do
    a=$(kubectl -n mlflow get secret mlflow-oauth -o jsonpath="{.data.$k}" \
      | base64 -d | shasum -a 256 | cut -c1-8)
    b=$(gcloud secrets versions access latest \
      --secret "autoresearch-dev-mlflow-oauth-$k" --project "$PROJECT_ID" \
      | tr -d '\n' | shasum -a 256 | cut -c1-8)
    [ "$a" = "$b" ] && echo "$k OK($a)" || echo "$k 불일치: k8s=$a sm=$b"
  done
  ```

허용 목록에서 한 사용자를 제거할 때는 목록을 갱신하고 위 rollout 완료를 확인한다.
oauth2-proxy는 보호된 요청마다 세션 이메일을 새 allowlist로 재검사하므로, 이 경우
cookie-secret을 바꿔 전원 재로그인을 시킬 필요가 없다.

### 전원 세션 무효화 (cookie-secret 회전)

cookie-secret 유출 의심이나 전원 강제 로그아웃이 필요한 경우에만 아래 절차를 쓴다.
기존 client 자격과 허용 이메일은 값 비노출 파일로 보존하고, 새 cookie-secret으로
갱신한다. 대화형 셸 자체가 종료되지 않도록 명령 전체는 subshell에서 실행된다.

```bash
(
set -euo pipefail
umask 077
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
for k in client-id client-secret authenticated-emails; do
  kubectl -n mlflow get secret mlflow-oauth -o "jsonpath={.data.$k}" \
    | base64 -d > "$d/$k"
  test -s "$d/$k" || { echo "ERROR: mlflow-oauth.$k 없음"; exit 1; }
done
python3 -c 'import os,base64,sys;sys.stdout.write(base64.urlsafe_b64encode(os.urandom(32)).decode())' \
  > "$d/cookie-secret"
kubectl create secret generic mlflow-oauth -n mlflow \
  --from-file=client-id="$d/client-id" \
  --from-file=client-secret="$d/client-secret" \
  --from-file=cookie-secret="$d/cookie-secret" \
  --from-file=authenticated-emails="$d/authenticated-emails" \
  --dry-run=client -o yaml | kubectl apply --server-side --force-conflicts -f -
rm -rf "$d"; trap - EXIT
kubectl rollout restart deployment/mlflow-oauth-proxy -n mlflow
kubectl rollout status deployment/mlflow-oauth-proxy -n mlflow --timeout=120s
)
```

완료된 rollout 뒤에는 기존 cookie가 검증되지 않아 모든 사용자가 다시 로그인해야 한다.

## Model Training 담당자 port-forward 권한 (#236)

`mlflow` 네임스페이스에는 기본 RBAC가 없어 Model Training 담당자가
`kubectl port-forward -n mlflow svc/mlflow 5000:5000`으로 UI를 검증(모델 등록,
Stage 승격, GCS artifact 확인)하지 못했다. 최소 권한으로 이를 부여한다.

- 부여 범위: built-in ClusterRole `view`(secret 제외 read) namespace RoleBinding
  + `pods/portforward` create만 담은 전용 Role `mlflow-portforward`.
- 제외: `pods/exec`, write, cluster-admin은 부여하지 않는다(과도 권한 방지).
- 대상 계정은 `mlflow_viewer_user_emails`로 지정한다. **실제 Google 계정은 로컬
  `terraform.tfvars`에만** 두고 저장소에는 placeholder(`terraform.tfvars.example`)만
  둔다.

```bash
# 로컬 terraform.tfvars에 대상 계정 추가 후
terraform -chdir=terraform/admin/mlflow-k8s apply \
  -var project_id=<PROJECT_ID> -var private_services_cidr=<PSA_CIDR>
```

apply는 `#234`와 동일하게 GCS state 버킷 쓰기 권한과 `master_authorized_networks`
허용 네트워크를 가진 운영자만 수행할 수 있다. plan은 대상 계정 수에 따라
`kubernetes_role_v1.mlflow_portforward` 1개 + 계정별 RoleBinding 2개(view,
portforward)만 add로 보여야 한다.

검증(대상 계정 자격으로). subresource는 `pods/portforward` 문자열이 아니라
`--subresource`로 확인한다 — `kubectl auth can-i create pods/portforward`는
문법상 실제 권한과 무관하게 `no`를 반환하므로 오해하지 말 것.

```bash
kubectl auth can-i create pods --subresource=portforward -n mlflow  # → yes
kubectl auth can-i create pods --subresource=exec        -n mlflow  # → no (부여 안 함)
kubectl auth can-i get    secrets                        -n mlflow  # → no (view는 secret 제외)
kubectl port-forward -n mlflow svc/mlflow 5000:5000                 # 접속 성공
```

롤백: 대상 계정을 `mlflow_viewer_user_emails`에서 제거하고 다시 apply하면 해당
RoleBinding이 삭제된다. 전체 제거는 변수를 빈 목록으로 두고 apply한다.

## 정리/롤백

```bash
kubectl delete secret mlflow-db -n mlflow          # 재주입 시
terraform -chdir=terraform/admin/mlflow-k8s destroy # 경계 제거(ArgoCD Application 먼저 제거)
```
