# terraform/admin/mlflow-k8s

MLflow tracking server의 Kubernetes 경계(별도 state). #91 설계, #94 배포.

- namespace `mlflow` + KSA `mlflow`(Workload Identity → GSA `autoresearch-dev-mlflow`)
- deny-by-default egress NetworkPolicy(Cloud SQL PSA 5432, GCS/API 443, DNS, WI metadata)

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

선행: GCP 콘솔에서 OAuth client(웹) 생성, redirect URI
`http://localhost:4180/oauth2/callback` 등록. client id는 공개값, client secret은
비공개.

```bash
umask 077
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT

# client secret: read -s로 입력(화면·히스토리 미노출)
read -rs -p 'client-secret: ' CS; echo
printf '%s' "$CS" > "$d/client-secret"; unset CS

# client id(공개값)
printf '%s' '185508640491-p0rosojfsj118hqn8pc2flhsv3fcqaag.apps.googleusercontent.com' > "$d/client-id"

# cookie 비밀(랜덤 32바이트, oauth2-proxy 권장 생성)
python3 -c 'import os,base64;print(base64.urlsafe_b64encode(os.urandom(32)).decode())' > "$d/cookie-secret"

# 허용 이메일(한 줄에 하나) — 목록 밖 Google 계정은 거부된다
cat > "$d/authenticated-emails" <<'EMAILS'
someone@example.com
EMAILS

kubectl create secret generic mlflow-oauth -n mlflow \
  --from-file=client-id="$d/client-id" \
  --from-file=client-secret="$d/client-secret" \
  --from-file=cookie-secret="$d/cookie-secret" \
  --from-file=authenticated-emails="$d/authenticated-emails"
rm -rf "$d"; trap - EXIT

kubectl rollout restart deployment/mlflow-oauth-proxy -n mlflow
```

이메일 목록·client secret 변경 시 위를 다시 실행(`--dry-run=client -o yaml | kubectl apply -f -`로 갱신) 후 `rollout restart`.

## 정리/롤백

```bash
kubectl delete secret mlflow-db -n mlflow          # 재주입 시
terraform -chdir=terraform/admin/mlflow-k8s destroy # 경계 제거(ArgoCD Application 먼저 제거)
```
