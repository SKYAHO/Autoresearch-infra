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

검증(대상 계정 자격으로):

```bash
kubectl auth can-i create pods/portforward -n mlflow   # → yes
kubectl auth can-i create pods/exec        -n mlflow   # → no (부여 안 함)
kubectl auth can-i create secrets          -n mlflow   # → no
kubectl port-forward -n mlflow svc/mlflow 5000:5000    # 접속 성공
```

롤백: 대상 계정을 `mlflow_viewer_user_emails`에서 제거하고 다시 apply하면 해당
RoleBinding이 삭제된다. 전체 제거는 변수를 빈 목록으로 두고 apply한다.

## 정리/롤백

```bash
kubectl delete secret mlflow-db -n mlflow          # 재주입 시
terraform -chdir=terraform/admin/mlflow-k8s destroy # 경계 제거(ArgoCD Application 먼저 제거)
```
