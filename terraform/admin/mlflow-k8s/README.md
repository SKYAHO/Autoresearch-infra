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

## 정리/롤백

```bash
kubectl delete secret mlflow-db -n mlflow          # 재주입 시
terraform -chdir=terraform/admin/mlflow-k8s destroy # 경계 제거(ArgoCD Application 먼저 제거)
```
