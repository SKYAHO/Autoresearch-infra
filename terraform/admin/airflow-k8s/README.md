# Airflow Kubernetes 경계

이 admin Terraform root는 dev GKE 클러스터에서 Airflow 설치에 필요한
Kubernetes 측 경계를 관리합니다.

- `airflow` namespace
- Workload Identity annotation이 붙은 Airflow Kubernetes service account
- Airflow 구성요소용 namespace 범위 Role/RoleBinding
- 선택적인 설치 담당자용 namespace 범위 admin RoleBinding
- GitHub Actions deployer GSA용 namespace 범위 admin RoleBinding
- ResourceQuota, LimitRange, NetworkPolicy

이 root는 Kubernetes 리소스를 별도 state와 provider 경계에 두기 위해
`terraform/envs/dev`와 분리되어 있습니다. dev root의 일반 PR plan은 GKE API
server에 직접 접근할 필요가 없고, Kubernetes 측 변경은 운영자가 의도적으로
적용합니다. 과거에는 CI plan runner가 `master_authorized_networks`에도 막혔지만,
현재 control plane은 IAM 기반 DNS endpoint(#45)로 접근할 수 있습니다. 그럼에도
state와 provider 격리를 위해 이 분리 구조를 유지합니다.

## 사용법

```bash
cd terraform/admin/airflow-k8s
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars에 실제 값을 입력합니다. 이 파일은 커밋하지 않습니다.

terraform init
terraform plan
terraform apply
```

이 명령은 GKE `master_authorized_networks`에 이미 허용된 운영자 네트워크에서
실행합니다. 현재 활성 Google 계정에는 namespace 범위 리소스를 만들 수 있는
Kubernetes 권한도 필요합니다.

`airflow-deployer-admin`은 dev root가 생성한
`autoresearch-dev-airflow-cd` GSA에 `airflow` namespace 범위의 `admin`만
부여합니다. GitHub Actions는 GKE DNS endpoint로 접속하며 이 RoleBinding 없이는
Helm 리소스를 변경할 수 없습니다.

`installer_user_emails`는 목록에 있는 각 Google 계정에 `airflow` namespace 안에서만
Kubernetes `admin` ClusterRole을 부여합니다. 이메일을 제거하고 apply하면 해당
RoleBinding이 제거됩니다.

이 권한은 cluster-admin 권한이 아닙니다. 설치 담당자는 `airflow` namespace 안의
일반적인 Airflow Helm 리소스를 관리할 수 있지만, 별도 RBAC binding을 추가하지
않는 한 namespace 생성, CRD 설치, ClusterRole/ClusterRoleBinding 생성, node 수정,
다른 namespace 작업은 할 수 없습니다.

Airflow GCP service account와 Workload Identity IAM binding을 포함한 대응 GCP
리소스는 `terraform/envs/dev`에서 관리합니다.

## NetworkPolicy와 Workload Identity

현재 dev 클러스터는 GKE Standard + Calico를 사용합니다. 엄격한 egress
NetworkPolicy에서 Workload Identity Federation이 동작하려면 GKE metadata
server의 `169.254.169.252/32` TCP 987/988을 허용해야 합니다. Dataplane V2
metadata endpoint인 `169.254.169.254/32` TCP 80 경로도 유지합니다. 두 경로 모두
link-local `/32`와 필요한 TCP 포트만 허용하며 IAM 권한 자체를 변경하지 않습니다.

변경 전에는 다음 검증을 수행합니다.

```bash
terraform -chdir=terraform/admin/airflow-k8s fmt -check
terraform -chdir=terraform/admin/airflow-k8s init -backend=false
terraform -chdir=terraform/admin/airflow-k8s validate

# 실제 backend와 관리자 인증이 준비된 환경에서만 실행합니다.
terraform -chdir=terraform/admin/airflow-k8s init -reconfigure
terraform -chdir=terraform/admin/airflow-k8s plan -lock=false \
  -var-file=terraform.tfvars
```

plan은 `kubernetes_network_policy_v1.airflow_egress` 한 개의 in-place 변경과
`0 to add, 1 to change, 0 to destroy`만 보여야 합니다. add/delete/replace, IAM,
Secret Manager 또는 GKE cluster 변경이 보이면 apply하지 않습니다.

별도 적용 승인 후에는 live NetworkPolicy에서 두 metadata CIDR과 포트를 확인하고,
실제 batch KSA를 사용하는 Pod에서 metadata token endpoint가 HTTP 200을 반환하는지
확인합니다. token 본문은 파일이나 로그에 남기지 않습니다. 이어서 격리된 QA GCS
prefix 읽기/쓰기와 1-micro-work smoke test를 수행합니다.

문제가 발생하면 이 변경에서 추가한 `169.254.169.252/32` TCP 987/988 egress
블록만 제거하고 admin root를 다시 plan/apply합니다. 이 롤백은 NetworkPolicy의
in-place 갱신이어야 하며 노드 재생성을 유발하지 않습니다. 롤백 후에는 Calico
Pod의 Workload Identity 인증이 다시 차단될 수 있으므로 metadata HTTP 상태와
Airflow task 상태를 즉시 확인합니다.

## MLflow tracking egress (#234)

`airflow` 네임스페이스의 Pod(향후 KubernetesPodOperator로 실행될 CTR 학습
Pod)가 `mlflow` 네임스페이스의 tracking server(`mlflow.mlflow:5000`,
ClusterIP)에 접속하려면 egress 허용이 필요합니다. 기존 kube-dns/PostgreSQL과
같은 이유로(Calico가 egress를 DNAT 이전에 평가) `var.cluster_services_cidr`
ipBlock 규칙을 주 경로로 쓰고, DNAT 이후 평가하는 dataplane을 대비해
`mlflow` namespace selector 규칙을 방어적으로 함께 추가했습니다. `mlflow`
네임스페이스 쪽 NetworkPolicy(`terraform/admin/mlflow-k8s`)는 `Egress`
policy_type만 설정돼 있어 ingress는 이미 허용된 상태입니다.

로컬에서 `fmt -check`/`init -backend=false`/`validate`까지 확인했습니다. 이
변경의 실제 `plan`/`apply`는 GKE `master_authorized_networks`에 허용된
운영자 네트워크에서 위 "사용법" 절차대로 실행해야 합니다. plan은
`kubernetes_network_policy_v1.airflow_egress` 한 개의 in-place 변경만
보여야 합니다.

적용 후 검증:

```bash
kubectl run mlflow-egress-probe -n airflow --image=curlimages/curl:8.9.1 \
  --restart=Never --command -- sleep 300
kubectl exec -n airflow mlflow-egress-probe -- curl -s -o /dev/null -w "%{http_code}\n" \
  http://mlflow.mlflow:5000/health
kubectl delete pod mlflow-egress-probe -n airflow
```

`200`이 반환되면 성공입니다. 문제가 발생하면 이 변경에서 추가한 두 egress
블록(ipBlock + namespace_selector, 포트 5000)만 제거하고 admin root를 다시
plan/apply합니다. 다른 egress 규칙(WI metadata, DNS, PostgreSQL 등)에는 영향이
없어야 합니다.

## 최초 Apply 기록

2026-07-08 기준 `airflow` namespace는 클러스터에 이미 존재했습니다. 삭제 후
재생성하지 않고 이 root의 state로 import했습니다.

```bash
terraform import kubernetes_namespace_v1.airflow airflow
```

import 이후 admin root에서 나머지 service account, RBAC, quota, limit range,
network policy 리소스를 적용했습니다. 최종 plan은 변경 없음으로 종료되었습니다.
