# 팀원 운영 접근 Runbook

팀원이 dev GKE 클러스터와 Airflow UI에 접근할 때 필요한 절차와 권한을 한 곳에
정리한다. 이 문서는 팀원에게 공유하는 운영 안내의 단일 원본이다.

## 대상 환경

| 항목 | 값 |
|---|---|
| GCP project | `ar-infra-501607` |
| Region / zone | `asia-northeast3` / `asia-northeast3-a` |
| GKE cluster | `autoresearch-dev-gke` |
| Expected context | `gke_ar-infra-501607_asia-northeast3-a_autoresearch-dev-gke` |
| App namespace | `autoresearch` (#129, apply 대기) |
| Airflow namespace | `airflow` |
| Monitoring namespace | `monitoring` |
| Bastion | `autoresearch-dev-bastion` |
| Airflow internal FQDN | `airflow.dev.autoresearch.internal` |

## 팀원 사전 준비

- Google Cloud CLI
- `gke-gcloud-auth-plugin`
- `kubectl`
- Airflow 설치나 갱신을 맡는 경우 Helm

macOS에서 Google Cloud CLI를 설치했다면 인증 플러그인은 보통 아래 명령으로
설치한다.

```bash
gcloud components install gke-gcloud-auth-plugin
```

Homebrew 등 패키지 설치 방식에 따라 components 명령이 막혀 있으면 패키지 매니저로
`gke-gcloud-auth-plugin`을 별도 설치한다. 플러그인이 설치되어 있어도 PATH에 없으면
`/opt/homebrew/share/google-cloud-sdk/bin`을 PATH에 포함해야 할 수 있다.

## 관리자 준비 사항

팀원이 접근하기 전에 관리자는 아래 항목을 확인한다.

1. 팀원 Google 계정이 GCP 프로젝트에 초대되어 있다.
2. `terraform/admin/gke-team-access`에 팀원 이메일을 넣고 apply했다.
3. Airflow 설치 담당자는 `terraform/admin/airflow-k8s`의
   `installer_user_emails`에 포함되어 있다.
4. Grafana 접근이 필요한 팀원은 `terraform/admin/monitoring-k8s`의
   `monitoring_port_forward_user_emails`에 포함되어 있다.
5. 실제 이메일은 로컬 `terraform.tfvars`에만 넣고 커밋하지 않는다.
6. 일반 앱 배포 전 `terraform/admin/autoresearch-k8s`에서 namespace, KSA,
   NetworkPolicy plan과 기존 리소스 import 필요 여부를 확인한다.

## 팀원별 권한 기록

아래 권한은 2026-07-09 기준 dev 운영을 위해 부여한 권한이다. 실제 Google 계정
이메일은 admin root의 로컬 `terraform.tfvars`로만 관리하고, 저장소 문서에는
커밋하지 않는다.

| 멤버 | GCP IAM | Kubernetes RBAC | 목적 |
|---|---|---|---|
| 박주용 | GKE/Bastion IAM + BigQuery jobUser, analytics·Feast dataset dataEditor | `airflow` namespace admin | GKE 조회/접속, Bastion 터널, Airflow 설치/운영, BigQuery 분석 |
| 성효창 | GKE/Bastion IAM + BigQuery jobUser, analytics·Feast dataset dataEditor | `airflow` namespace admin | GKE 조회/접속, Bastion 터널, Airflow 설치/운영, BigQuery 분석 |
| 이영준 | GKE/Bastion IAM + BigQuery jobUser, analytics·Feast dataset dataEditor | `airflow` namespace admin | GKE 조회/접속, Bastion 터널, Airflow 설치/운영, BigQuery 분석 |
| 유현서 | GKE/Bastion IAM + BigQuery jobUser, analytics·Feast dataset dataEditor | `airflow` namespace admin | GKE 조회/접속, Bastion 터널, Airflow 설치/운영, BigQuery 분석 |
| 최현규 | GKE/Bastion IAM + BigQuery jobUser, analytics·Feast dataset dataEditor | `airflow` namespace admin | GKE 조회/접속, Bastion 터널, Airflow 설치/운영, BigQuery 분석 |

권한 의미:

| 권한 | 범위 | 의미 |
|---|---|---|
| `roles/container.viewer` | 프로젝트 | GKE 클러스터 조회와 DNS endpoint 접속(`container.clusters.connect`). Kubernetes secret payload 읽기 권한은 아니다. |
| `roles/iap.tunnelResourceAccessor` | 프로젝트 | IAP TCP 터널을 통해 Bastion에 SSH 접속 |
| `roles/compute.osLogin` | 프로젝트 | OS Login 기반 Linux 사용자 로그인 |
| `roles/compute.viewer` | 프로젝트 | Bastion 인스턴스 조회와 SSH 대상 확인 |
| `roles/bigquery.jobUser` | 프로젝트 | query/load/export BigQuery job 실행. 데이터 접근·편집 권한은 별도로 필요 |
| `roles/bigquery.dataEditor` | `autoresearch_dev_analytics`, `feast_offline_store` dataset만 | 해당 dataset의 테이블·데이터 생성, 갱신, 삭제. 프로젝트 수준 Data Editor는 부여하지 않음 |
| `airflow` namespace admin | Kubernetes namespace | Airflow Helm install/upgrade와 namespace 내부 리소스 관리 |
| `monitoring` namespace port-forward | Kubernetes namespace | allowlist 팀원의 monitoring 구성요소 접근 |

팀원은 클러스터 전체를 조회할 수 있지만, 변경 권한은 필요한 namespace 내부로
제한된다. Airflow 설치 권한은 `airflow` namespace, Grafana 접속 권한은
`monitoring` namespace port-forward 범위다. 새 namespace 생성, CRD 설치,
ClusterRole/ClusterRoleBinding 생성, node 수정, 다른 namespace 작업은 허용하지
않는다. BigQuery 데이터 편집은 analytics와 Feast offline store 두 dataset으로만
제한하며, query/load job은 `maximum_bytes_billed` 등 job 수준 비용 제한을 사용한다.

## kubeconfig 설정

팀원 본인의 Google 계정으로 로그인한 뒤 클러스터 credentials를 받는다. kubeconfig
파일이나 service account JSON key를 공유하지 않는다.

```bash
gcloud auth login
gcloud config set project ar-infra-501607

gcloud container clusters get-credentials autoresearch-dev-gke \
  --zone asia-northeast3-a \
  --project ar-infra-501607 \
  --dns-endpoint
```

정상 연결을 확인한다.

```bash
kubectl config current-context
kubectl get namespaces
```

다른 context가 선택되어 있으면 전환한다.

```bash
kubectl config use-context gke_ar-infra-501607_asia-northeast3-a_autoresearch-dev-gke
```

## Airflow 설치 권한 확인

Airflow 설치자는 `airflow` namespace 안에서만 권한을 확인한다.

```bash
kubectl -n airflow get all
kubectl auth can-i create deployments -n airflow
kubectl auth can-i create secrets -n airflow
kubectl auth can-i create rolebindings -n airflow
```

모두 `yes`이면 일반적인 Helm install/upgrade 작업을 진행할 수 있다.

```bash
helm repo add apache-airflow https://airflow.apache.org
helm repo update

helm upgrade --install airflow apache-airflow/airflow \
  --namespace airflow \
  --values <values.yaml>
```

`values.yaml`, DAG, Airflow image 설정은
[`SKYAHO/Autoresearch-airflow`](https://github.com/SKYAHO/Autoresearch-airflow)
저장소에서 관리한다. 이 인프라 저장소는 namespace, RBAC, Workload Identity,
내부망 접근 경계만 제공한다.

## Bastion 접속

Bastion은 외부 IP가 없고 IAP 터널로만 접속한다. SSH 단독 접속은 점검용이다.

```bash
gcloud compute ssh autoresearch-dev-bastion \
  --zone asia-northeast3-a \
  --project ar-infra-501607 \
  --tunnel-through-iap
```

## Airflow UI 접속

Airflow UI는 인터넷에 공개하지 않는다. 기본 접속 경로는 Bastion 포트 포워딩이다.

```bash
gcloud compute ssh autoresearch-dev-bastion \
  --zone asia-northeast3-a \
  --project ar-infra-501607 \
  --tunnel-through-iap \
  -- -N -L 8080:airflow.dev.autoresearch.internal:8080
```

터널을 켠 터미널 창은 그대로 두고, 브라우저에서 아래 주소로 접속한다.

```text
http://localhost:8080
```

Google OAuth redirect URI가 `http://localhost:8080/oauth-authorized/google` 기준이라
로그인은 `localhost:8080` 경로에서만 정상 동작한다.

## Grafana UI 접속

Grafana UI는 인터넷에 공개하지 않는다. `kube-prometheus-stack`의 Grafana Service는
`ClusterIP`이며, 기본 접속 경로는 Kubernetes API를 통한 port-forward다.

권한을 먼저 확인한다.

```bash
kubectl auth can-i get services -n monitoring
kubectl auth can-i create pods/portforward -n monitoring
```

모두 `yes`이면 포트 포워딩을 연다.

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

터널을 켠 터미널 창은 그대로 두고, 브라우저에서 아래 주소로 접속한다.

```text
http://localhost:3000
```

로그인은 **"Sign in with Google" 버튼(팀원 개인 계정)이 기본**이다(#155).
사전 생성된 계정만 로그인되며(자동 가입 차단), 계정이 없다는 오류가 나면
운영자에게 계정 생성을 요청한다. admin 계정(`grafana-admin-credentials`
Secret payload)은 비상용으로만 쓰고, 실제 비밀번호를 문서, PR, 채팅에
남기지 않는다.

로그인 후 어떤 dashboard를 볼지는
[`GRAFANA_OPERATIONS_RUNBOOK.md`](GRAFANA_OPERATIONS_RUNBOOK.md)를 기준으로 한다.

## Kibana (로그 검색) 접속

Kibana도 인터넷에 공개하지 않는다. Airflow/앱 로그 검색이 필요하면:

```bash
kubectl -n elastic port-forward svc/autoresearch-kb-http 5601:5601
```

브라우저에서 `https://localhost:5601` (self-signed 경고 허용). 로그인
계정은 운영자에게 요청한다. 검색 방법과 KQL 예시는
[`KIBANA_OPERATIONS_RUNBOOK.md`](KIBANA_OPERATIONS_RUNBOOK.md) 참조.

## SOCKS 프록시 보조 경로

내부 DNS 이름 자체를 브라우저에서 확인해야 할 때만 SOCKS 프록시를 쓴다.

```bash
gcloud compute ssh autoresearch-dev-bastion \
  --zone asia-northeast3-a \
  --project ar-infra-501607 \
  --tunnel-through-iap \
  -- -N -D 1080
```

브라우저에서 SOCKS5 프록시를 `127.0.0.1:1080`으로 설정하고, 원격 DNS 조회를
사용하도록 설정한 뒤 아래 주소를 연다.

```text
http://airflow.dev.autoresearch.internal:8080
```

이 방식은 내부 DNS 확인용 보조 경로다. OAuth redirect URI 제약 때문에 Airflow 로그인
경로로는 `localhost:8080` 포트 포워딩 방식을 우선한다.

## 내부망 접근 전략

현재 dev 운영 경로는 다음과 같다.

| 대상 | 기본 접근 경로 | 비고 |
|---|---|---|
| GKE API server | GKE DNS endpoint + IAM | `--dns-endpoint`, 팀원 IP 등록 불필요 |
| Airflow UI | Bastion IAP 터널 + `-L 8080` | 외부 공개 금지 |
| Grafana UI | `kubectl port-forward` + `localhost:3000` | Service는 `ClusterIP`, 외부 공개 금지 |
| VPC 내부 DNS 확인 | Bastion IAP 터널 + SOCKS5 | 보조 경로 |
| Cloud SQL private IP | GKE 내부 proxy 또는 pod 경유 | 로컬에서 private IP 직접 접속하지 않음 |
| Online Store Redis Cluster | `autoresearch` pod에서 PSC discovery endpoint로 TLS 접속 | app GSA Workload Identity로 IAM token 발급, CA는 Secret Manager 조회, 로컬 직접 접속 금지 (#129, apply 대기) |
| GKE node SSH | IAP tunneling | 디버깅 목적, 최소 사용 |

VPN은 현재 dev 규모에서는 기본 경로가 아니다. 팀원 수가 늘거나 내부 서비스 접속이
상시 업무가 되면 별도 이슈에서 Cloud VPN 또는 더 관리형인 접근 방식을 재평가한다.

## Workload Identity 운영 메모

Airflow 기본 component와 batch pod는 서로 다른 GCP service account를 사용한다.

| Kubernetes service account | GCP service account | 목적 |
|---|---|---|
| `autoresearch/autoresearch-app` | `autoresearch-dev-app@ar-infra-501607.iam.gserviceaccount.com` | 앱 DB secret과 Redis CA 조회, cluster 한정 IAM 연결 token 발급 (#129, apply 대기) |
| `airflow/airflow` | `autoresearch-dev-airflow@ar-infra-501607.iam.gserviceaccount.com` | Airflow metadata DB, DAG/log bucket, OAuth secret |
| `airflow/autoresearch-batch` | `autoresearch-dev-airflow-batch@ar-infra-501607.iam.gserviceaccount.com` | batch API key secret, raw data bucket, Feast GCS/BigQuery, Cloud Run proxy invoker |

`autoresearch-batch` annotation은 아래 값이어야 한다.

```text
iam.gke.io/gcp-service-account=autoresearch-dev-airflow-batch@ar-infra-501607.iam.gserviceaccount.com
```

확인 명령:

```bash
kubectl -n airflow get serviceaccount autoresearch-batch -o yaml
```

Cloud Run proxy 호출은 `autoresearch-dev-airflow-batch` GSA에
`autoresearch-dev-proxy` 서비스 단위 `roles/run.invoker`가 있어야 한다. 이
권한은 #74에서 적용했다. 단, 권한만으로 호출이 완성되지는 않는다. DAG/job
코드는 Cloud Run URL을 audience로 하는 ID token을 발급해 `Authorization`
헤더에 넣고, YouTube API key는 `X-Goog-Api-Key` 헤더로 전달해야 한다. 또한
`INGRESS_TRAFFIC_INTERNAL_ONLY` 설정 때문에 batch pod는 GKE/VPC 내부 경로에서
호출해야 한다.

## 자주 나는 오류

| 증상 | 주된 원인 | 조치 |
|---|---|---|
| `gke-gcloud-auth-plugin not found` | 인증 플러그인이 PATH에 없음 | 플러그인 설치 후 PATH 확인 |
| `get-credentials` permission denied | GCP IAM 미부여 또는 다른 계정 로그인 | `gcloud auth list` 확인, 관리자에게 gke-team-access apply 여부 확인 |
| `kubectl` timeout | IP 기반 kubeconfig 사용 또는 네트워크 경로 오류 | `--dns-endpoint`로 credentials 재발급 |
| `kubectl Forbidden` | Kubernetes RBAC 미부여 | `installer_user_emails` 반영 여부 확인 |
| Airflow UI가 브라우저에서 열리지 않음 | Bastion 터널 미실행 또는 포트 충돌 | `-L 8080` 터널 터미널 유지, 로컬 8080 사용 여부 확인 |
| Grafana UI port-forward 실패 | monitoring namespace RBAC 미부여 또는 로컬 3000 포트 충돌 | `monitoring_port_forward_user_emails` 반영 여부 확인, 다른 포트 사용 |
| SOCKS에서 내부 도메인 접속 실패 | 브라우저가 로컬 DNS를 사용 | SOCKS5 원격 DNS 조회 옵션 확인 |
| OAuth 로그인 실패 | `.internal` 도메인으로 접속 | `http://localhost:8080`으로 접속 |

## 권한 회수

팀원이 프로젝트에서 빠지거나 Airflow 설치 권한이 더 이상 필요 없으면 관리자가 아래
로컬 tfvars에서 이메일을 제거하고 apply한다.

- `terraform/admin/gke-team-access/terraform.tfvars`
- `terraform/admin/autoresearch-k8s/terraform.tfvars`
- `terraform/admin/airflow-k8s/terraform.tfvars`

이미 발급된 access token은 보통 최대 1시간 정도 더 유효할 수 있다. kubeconfig가
로컬에 남아 있어도 다음 인증부터는 권한이 없어 403으로 실패한다.

## 보안 원칙

- kubeconfig 파일을 서로 공유하지 않는다.
- service account JSON key를 발급하거나 전달하지 않는다.
- 실제 secret 값, Terraform state, `terraform.tfvars` 실값을 커밋하지 않는다.
- `kubectl` 명령 전에는 항상 current context를 확인한다.
- 팀원 개인 계정에 Secret Manager payload 직접 읽기 권한을 주지 않는다.
