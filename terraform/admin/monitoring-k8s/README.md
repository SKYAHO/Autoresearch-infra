# Monitoring Kubernetes 경계

이 admin Terraform root는 dev GKE 클러스터에서 Prometheus/Grafana 설치 기반에
필요한 Kubernetes 측 경계를 관리합니다.

- `monitoring` namespace
- `kube-prometheus-stack` Helm release
- Prometheus/Grafana Helm values 파일 위치

이 root는 `terraform/envs/dev`와 별도 state를 사용합니다. dev root의 일반 PR
plan이 GKE API server에 직접 접근하지 않아도 되도록, Kubernetes 측 변경은
운영자가 의도적으로 apply합니다.

## 관리 범위

| 항목 | 위치 | 비고 |
|---|---|---|
| Namespace | `main.tf` | 기본값 `monitoring` |
| Helm release | `helm_release.kube_prometheus_stack` | chart `kube-prometheus-stack` |
| Helm values | `helm-values/kube-prometheus-stack.values.yaml` | #79 설치 입력값 |
| Terraform state | GCS `autoresearch-dev-tfstate`, prefix `admin/monitoring-k8s/` | dev root와 분리 |

## 사용법

```bash
cd terraform/admin/monitoring-k8s
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars에 실제 project_id를 입력합니다. 이 파일은 커밋하지 않습니다.

kubectl create secret generic grafana-admin-credentials \
  -n monitoring \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<강한 임시 비밀번호>'

terraform init
terraform plan
terraform apply
```

실행 환경과 현재 활성 Google 계정에는 다음 접근 권한이 필요합니다.

- private GKE API endpoint에 도달할 수 있는 네트워크 경로
- dev GKE cluster 조회 권한
- `monitoring` namespace, CRD, ClusterRole, ClusterRoleBinding, DaemonSet,
  StatefulSet 등을 만들 수 있는 Kubernetes 권한
- GCS bucket `autoresearch-dev-tfstate`의
  `admin/monitoring-k8s/` state 객체를 조회하고 갱신할 권한

일반 PR CI가 아니라 위 조건을 충족한 운영자 환경에서만 plan/apply합니다.

## 삭제 보호

`monitoring` namespace에는 Terraform `prevent_destroy`를 적용합니다. 후속 Helm
설치 후 namespace를 삭제하면 Prometheus, Grafana, Alertmanager를 포함한 모든
namespaced 리소스와 PVC 객체가 함께 삭제되기 때문입니다. PersistentVolume의 실제
디스크 보존 여부는 StorageClass의 reclaim policy에 따라 달라지므로, 확인 전에는
데이터 손실로 간주합니다.

의도적으로 namespace를 폐기할 때만 다음 순서를 따릅니다.

1. Helm release와 PVC/PV의 백업 및 삭제 계획을 확인합니다.
2. 사용자 승인을 받은 뒤 `prevent_destroy`를 별도 변경으로 제거합니다.
3. plan에서 전체 삭제 범위를 검토한 뒤 apply합니다.
현재 활성 Google 계정에는 dev GKE cluster 조회 권한과 `monitoring` namespace,
CRD, ClusterRole, ClusterRoleBinding, DaemonSet, StatefulSet 등을 만들 수 있는
Kubernetes 권한이 필요합니다. `kube-prometheus-stack`은 cluster-wide 리소스를
포함하므로 namespace admin만으로는 부족할 수 있습니다.

## Helm values 기준

`helm-values/kube-prometheus-stack.values.yaml`은 Helm 설치에 사용할 기본 values
위치입니다. 이 파일에는 secret 값을 넣지 않습니다.

초기 기준:

- Prometheus retention: 7일
- Prometheus PVC: 30Gi
- Grafana Service: `ClusterIP`
- Grafana PVC: 10Gi
- Alertmanager: enabled
- Prometheus Operator admission webhook: enabled
- Prometheus Operator webhook internal port: `10250`

chart `87.12.1`은 private GKE에서 별도 firewall 없이 동작하도록 webhook internal
port 기본값을 `10250`으로 사용합니다. GKE control plane에서 node로 향하는 자동
관리 firewall rule에 TCP `10250`이 허용되는지 apply 전에 확인합니다.

조직의 custom firewall policy가 control plane-to-node 트래픽을 제한한다면, 먼저
Connectivity Tests와 firewall policy logging으로 차단 원인을 확인합니다. 그 경우
dev GKE root에서 control plane CIDR에서 node tag의 TCP `10250`으로만 허용하는
최소 규칙을 별도 검토합니다. Bastion은 Terraform/Helm 실행자의 GKE API 접근을
제공하지만 control plane의 webhook 접근을 대신하지 않습니다.

## 설치 후 확인

```bash
kubectl get pods -n monitoring
kubectl get svc -n monitoring
kubectl get pvc -n monitoring
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

브라우저에서 `http://localhost:3000`으로 접속해 Grafana dashboard를 확인합니다.

## 보안 기준

- Grafana admin password, OAuth client secret, datasource credential은 Git에
  커밋하지 않고 Terraform state에도 저장하지 않습니다.
- Grafana UI는 public LoadBalancer나 public Ingress로 열지 않습니다.
- Grafana UI는 GKE 접근 권한이 있는 운영자 환경에서 `kubectl port-forward`로
  접속합니다.
- Prometheus metric label에는 사용자 ID, token, raw URL처럼 cardinality와
  민감도 문제가 생기는 값을 넣지 않습니다.
