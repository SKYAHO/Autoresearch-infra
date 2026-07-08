# Dev GKE 클러스터 접근 가이드

팀원이 로컬 PC에서 dev GKE 클러스터에 `kubectl`로 접근하기 위한 절차를
정리한다. 이 문서는 Airflow 설치자가 클러스터에 접근할 수 있도록 경로를
열어주는 목적이며, Airflow Helm values나 애플리케이션 배포 설정은 각 애플리케이션
저장소에서 관리한다.

## 대상 클러스터

| 항목 | 값 |
|---|---|
| GCP project | `ar-infra-501607` |
| GKE cluster | `autoresearch-dev-gke` |
| location | `asia-northeast3-a` |
| expected context | `gke_ar-infra-501607_asia-northeast3-a_autoresearch-dev-gke` |
| Airflow namespace | `airflow` |

## 접근 전 관리자 확인 사항

아래 조건이 모두 준비되어야 팀원이 로컬에서 `kubectl`을 사용할 수 있다.

1. 팀원 Google 계정이 GCP 프로젝트에 초대되어 있어야 한다.
2. `terraform/admin/gke-team-access`에서 해당 계정에
   `roles/container.viewer`가 부여되어 있어야 한다 (#45: DNS 엔드포인트 접속에
   필요한 `container.clusters.connect` 포함).
3. 공인 IP 등록은 **더 이상 필요 없다** (#45 DNS 기반 엔드포인트). IP 기반
   엔드포인트를 예비 경로로 쓸 때만 `terraform/envs/dev`의
   `master_authorized_networks`에 `/32` CIDR 등록이 필요하다.
4. Airflow 설치를 맡은 팀원은 `terraform/admin/airflow-k8s`의
   `installer_user_emails`에 포함되어 `airflow` namespace 안에서만 admin 권한을
   받아야 한다.

실제 이메일과 공인 IP는 로컬 `terraform.tfvars`에만 넣고 커밋하지 않는다. 개인
정보와 임시 접근 값을 PR diff, issue 댓글, 문서에 남기지 않는다.

## 권한 범위 요약

팀원 권한은 `클러스터 접속`과 `namespace 내부 작업`을 분리한다.

| 권한 구분 | 대상 | 부여 권한 | 가능한 작업 | 제한되는 작업 |
|---|---|---|---|---|
| GCP IAM | 팀원 Google 계정 | `roles/container.viewer` | `get-credentials`(DNS 엔드포인트 포함), 클러스터 정보 조회 | GCP 리소스 생성/수정, 클러스터 설정 변경 |
| Kubernetes RBAC | 팀원 Google 계정 | `airflow` namespace 안의 `admin` RoleBinding | Airflow Helm install/upgrade, Deployment/Service/Secret/ConfigMap/Job/PVC 관리 | 새 namespace 생성, CRD 설치, ClusterRole/ClusterRoleBinding 생성, node/storageclass/persistentvolume 수정, 다른 namespace 작업 |
| Workload Identity | `airflow` namespace의 KSA | Airflow GCP SA 가장 | Airflow pod가 Cloud SQL, GCS, BigQuery, Secret Manager에 필요한 범위로 접근 | 팀원 개인 계정이 직접 secret payload를 읽거나 GCP 데이터 리소스를 관리하는 권한 |

즉, 팀원은 `airflow` namespace 안에서 Airflow를 설치하고 운영할 수 있지만 클러스터 전체
관리자는 아니다. Airflow 외 다른 작업이 필요하면 작업별 namespace와 RoleBinding을 별도
이슈로 추가한다.

## 팀원 로컬 준비물

- Google Cloud CLI
- `gke-gcloud-auth-plugin`
- `kubectl`
- Airflow 설치를 진행할 경우 Helm

macOS에서 Google Cloud CLI를 설치했다면 `gke-gcloud-auth-plugin`은 아래처럼 설치할 수
있다.

```bash
gcloud components install gke-gcloud-auth-plugin
```

설치 방식에 따라 components 명령이 막혀 있으면 패키지 매니저로
`gke-gcloud-auth-plugin`을 별도 설치한다.

## kubeconfig 받기

팀원 본인의 Google 계정으로 로그인한 뒤 클러스터 credentials를 받는다. kubeconfig 파일을
공유받거나 서비스 계정 JSON key를 전달받는 방식은 사용하지 않는다.

```bash
gcloud auth login
gcloud config set project ar-infra-501607

# 기본 경로 (#45): DNS 기반 엔드포인트 — IP 등록 불필요, 어디서든 접속 가능
gcloud container clusters get-credentials autoresearch-dev-gke \
  --zone asia-northeast3-a \
  --project ar-infra-501607 \
  --dns-endpoint
```

`--dns-endpoint` 옵션이 없는 구버전 gcloud라면 `gcloud components update` 후
재시도한다. 예비 경로(IP 기반 엔드포인트)를 쓸 때만 본인 공인 IP가
`master_authorized_networks`에 등록되어 있어야 하며, 이때는 `--dns-endpoint`
없이 같은 명령을 실행한다.

정상 연결 여부를 확인한다.

```bash
kubectl config current-context
kubectl get namespaces
```

`kubectl config current-context` 결과가
`gke_ar-infra-501607_asia-northeast3-a_autoresearch-dev-gke`인지 확인한다. 다른
context라면 작업 전에 반드시 전환한다.

```bash
kubectl config use-context gke_ar-infra-501607_asia-northeast3-a_autoresearch-dev-gke
```

## Airflow 설치 권한 확인

Airflow 설치자는 `airflow` namespace 범위에서만 권한을 확인한다. 클러스터 전체 권한이
필요한 작업은 이 경로의 목적이 아니다.

```bash
kubectl -n airflow get all
kubectl auth can-i create deployments -n airflow
kubectl auth can-i create secrets -n airflow
kubectl auth can-i create rolebindings -n airflow
```

위 권한이 `yes`이면 Helm chart를 `airflow` namespace에 설치하거나 갱신할 수 있다.

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update

helm upgrade --install airflow apache-airflow/airflow \
  --namespace airflow \
  --values <values.yaml>
```

`values.yaml`은 애플리케이션/Airflow 담당 저장소에서 관리한다. 이 인프라 저장소는
namespace, RBAC, Workload Identity, 네트워크 경계를 준비하는 역할만 한다.

## Airflow UI 접근 원칙

Airflow UI는 dev에서도 외부에 공개하지 않는다. 우선 경로는 로컬에서만 열리는
`kubectl port-forward`다.

```bash
kubectl -n airflow port-forward svc/<airflow-webserver-service-name> 8080:8080
```

이후 브라우저에서 `http://localhost:8080`으로 접근한다. 실제 service 이름은 설치한
Helm chart release와 values에 따라 달라질 수 있으므로 아래 명령으로 확인한다.

```bash
kubectl -n airflow get svc
```

## 자주 나는 오류

| 증상 | 주된 원인 | 확인/조치 |
|---|---|---|
| `get-credentials`에서 permission denied | GCP IAM 미부여 또는 다른 Google 계정으로 로그인 | `gcloud auth list` 확인, 관리자에게 `gke-team-access` 적용 여부 확인 |
| `kubectl` timeout 또는 API server 연결 실패 | IP 기반 kubeconfig 사용 중인데 공인 IP가 `master_authorized_networks`에 없음 | `--dns-endpoint`로 credentials 재발급(기본 경로), 또는 IP 등록 요청 |
| DNS 엔드포인트 접속 시 permission denied | `container.clusters.connect` 권한 없음 (구 clusterViewer role) | 관리자에게 `gke-team-access`의 `container.viewer` 반영(#45) 여부 확인 |
| `You must be logged in to the server` 또는 auth plugin 오류 | `gke-gcloud-auth-plugin` 미설치/구버전 | auth plugin 설치 후 `gcloud components update` |
| `Forbidden` | Kubernetes RBAC 미부여 | Airflow 설치자는 `terraform/admin/airflow-k8s`의 `installer_user_emails` 반영 필요 |
| 의도와 다른 클러스터에 명령 실행 | kubeconfig context 혼동 | `kubectl config current-context` 확인 후 전환 |

## 권한 회수

팀원이 프로젝트에서 빠지거나 Airflow 설치 권한이 더 이상 필요 없으면 관리자가 아래 두
곳에서 이메일을 제거하고 apply한다.

- `terraform/admin/gke-team-access/terraform.tfvars`
- `terraform/admin/airflow-k8s/terraform.tfvars`

이미 발급된 access token은 보통 최대 1시간 정도 더 유효할 수 있다. kubeconfig 파일은
팀원 로컬에 남아도 다음 인증부터는 권한이 없어져 403으로 실패한다.

## 보안 원칙

- kubeconfig 파일을 서로 공유하지 않는다.
- 서비스 계정 JSON key를 발급하지 않는다.
- 실제 이메일, 공인 IP, secret 값은 커밋하거나 PR 댓글에 남기지 않는다.
- `terraform.tfvars`, `*.tfplan`, Terraform state 파일은 커밋하지 않는다.
- `kubectl` 명령 전에는 항상 current context를 확인한다.
