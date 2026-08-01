# 팀원 운영 접근 Runbook

팀원이 dev GKE 클러스터와 Airflow UI에 접근할 때 필요한 절차와 권한을 한 곳에
정리한다. 이 문서는 팀원에게 공유하는 운영 안내의 단일 원본이다.

## 대상 환경

| 항목 | 값 |
|---|---|
| GCP project | `autoresearch-503903` |
| Region / zone | `asia-northeast3` / `asia-northeast3-a` |
| GKE cluster | `autoresearch-dev-gke` |
| Expected context | `gke_autoresearch-503903_asia-northeast3-a_autoresearch-dev-gke` |
| App namespace | `autoresearch` (#129, apply·검증 완료) |
| Airflow namespace | `airflow` |
| Monitoring namespace | `monitoring` |
| Bastion | `autoresearch-dev-bastion` |
| Airflow internal FQDN | `airflow.dev.autoresearch.internal` |
| MLflow internal FQDN | `mlflow.dev.autoresearch.internal` |

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
| 박주용 | GKE/Bastion IAM + BigQuery jobUser, analytics·Feast dataset dataEditor + GAR reader, Cloud Build, Cloud SQL viewer, DB password secret accessor | `airflow` admin·`mlflow`·`monitoring` view+port-forward·`autoresearch` view+port-forward+exec | GKE 조회/접속, Bastion 터널, Airflow 설치/운영, 앱/모델·모니터링 파드 디버깅, BigQuery 분석 |
| 성효창 | GKE/Bastion IAM + BigQuery jobUser, analytics·Feast dataset dataEditor + GAR reader, Cloud Build, Cloud SQL viewer, DB password secret accessor | `airflow` admin·`mlflow`·`monitoring` view+port-forward·`autoresearch` view+port-forward+exec | GKE 조회/접속, Bastion 터널, Airflow 설치/운영, 앱/모델·모니터링 파드 디버깅, BigQuery 분석 |
| 이영준 | GKE/Bastion IAM + BigQuery jobUser, analytics·Feast dataset dataEditor + GAR reader, Cloud Build, Cloud SQL viewer, DB password secret accessor | `airflow` admin·`mlflow`·`monitoring` view+port-forward·`autoresearch` view+port-forward+exec | GKE 조회/접속, Bastion 터널, Airflow 설치/운영, 앱/모델·모니터링 파드 디버깅, BigQuery 분석 |
| 유현서 | GKE/Bastion IAM + BigQuery jobUser, analytics·Feast dataset dataEditor + GAR reader, Cloud Build, Cloud SQL viewer, DB password secret accessor | `airflow` admin·`mlflow`·`monitoring` view+port-forward·`autoresearch` view+port-forward+exec | GKE 조회/접속, Bastion 터널, Airflow 설치/운영, 앱/모델·모니터링 파드 디버깅, BigQuery 분석 |
| 최현규 | GKE/Bastion IAM + BigQuery jobUser, analytics·Feast dataset dataEditor + GAR reader, Cloud Build, Cloud SQL viewer, DB password secret accessor | `airflow` admin·`mlflow`·`monitoring` view+port-forward·`autoresearch` view+port-forward+exec | GKE 조회/접속, Bastion 터널, Airflow 설치/운영, 앱/모델·모니터링 파드 디버깅, BigQuery 분석 |

권한 의미(라이브 대조 기준일 2026-07-20, #265):

> 이 표는 실제 GCP IAM 정책·GKE RoleBinding과 대조해 확인한 내용이다. 저장소의
> Terraform 코드만으로는 실제 부여 상태를 알 수 없다(대상 목록이 각 운영자 로컬
> `terraform.tfvars`에만 있음). 권한을 확인할 때는 `gcloud projects get-iam-policy`와
> `kubectl get rolebindings -n <namespace>`로 라이브를 조회한다.

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
| `mlflow` namespace view+port-forward | Kubernetes namespace | secret 제외 read + `pods/portforward`. MLflow UI 접근·검증(#236). exec/write 없음 |
| `autoresearch` namespace view+port-forward+exec | Kubernetes namespace | secret 제외 read + `pods/portforward` + `pods/exec`(#266). 앱 저장소 Feast·Redis GKE 검증 runbook이 파드 내부 실행을 요구. write/delete·cluster-admin 없음 |
| `roles/artifactregistry.reader` | `autoresearch-dev-docker` 저장소만 | 배포된 이미지 목록·digest 조회(#266). push는 WIF SA와 별도 writer 대상만 |
| `roles/cloudbuild.builds.editor` + staging bucket objectAdmin | 프로젝트 / `<project_id>_cloudbuild` 버킷 | `gcloud builds submit`으로 이미지 빌드(#266). 버킷 권한은 source 업로드용 |
| `roles/iam.serviceAccountUser` | 전용 build SA(`autoresearch-cloud-build`)만 | 그 SA로 build를 실행(#269). 빌드 제출 명령과 로그 옵션은 `docs/TERRAFORM_DEV.md` 참조 |
| `roles/cloudsql.viewer` | 프로젝트 | Cloud SQL 인스턴스 상태·private IP 조회(#266). DB 접속·데이터 권한은 아님 |
| `roles/secretmanager.secretAccessor` | `autoresearch-dev-db-password` secret만 | Airflow metadata DB 비밀번호 **값 읽기**(#266). version 추가·rotate 권한은 아니며 프로젝트 수준 Secret Manager 권한도 부여하지 않음 |

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
gcloud config set project autoresearch-503903

gcloud container clusters get-credentials autoresearch-dev-gke \
  --zone asia-northeast3-a \
  --project autoresearch-503903 \
  --dns-endpoint
```

정상 연결을 확인한다.

```bash
kubectl config current-context
kubectl get namespaces
```

다른 context가 선택되어 있으면 전환한다.

```bash
kubectl config use-context gke_autoresearch-503903_asia-northeast3-a_autoresearch-dev-gke
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

## VPA 관측 확인 (#373)

`admin-apply` 승인 workflow로 Task 4의 namespace-scoped `airflow-vpa` Role과 RoleBinding을
먼저 적용하고 완료를 확인한다. 이 단계는 GKE addon `dev-apply`보다 먼저 끝나야 하며, GKE
addon 내부 RBAC나 `admin` ClusterRole aggregation이 필요한 VPA 권한을 제공한다고 가정하지
않는다. `admin-apply` 완료 후에만 `dev-apply`를 DAG가 실행 중이지 않은 운영 창에서
승인한다. GKE VPA addon 변경은 비동기 GKE operation이므로 workflow 성공만으로 readiness
검사를 시작하지 말고, 해당 operation 완료를 먼저 확인한다.

CRD가 아직 없으면 condition-only `kubectl wait`는 즉시 NotFound으로 실패한다. 생성,
Established, served API discovery를 아래 순서로 확인한다. 대화형 shell을 종료하지 않도록
polling은 `bash -c` 서브셸에서 실행한다.

```bash
bash -c '
  set -euo pipefail
  kubectl wait --for=create --timeout=120s \
    crd/verticalpodautoscalers.autoscaling.k8s.io
  kubectl wait --for=condition=Established --timeout=120s \
    crd/verticalpodautoscalers.autoscaling.k8s.io
  deadline=$((SECONDS + 120))
  while ! kubectl api-resources --request-timeout=5s \
    --api-group=autoscaling.k8s.io \
    | awk "\$1 == \"verticalpodautoscalers\" { found = 1 } END { exit !found }"
  do
    if (( SECONDS >= deadline )); then
      printf "%s\\n" "VPA served API discovery timed out after 120 seconds." >&2
      exit 1
    fi
    sleep 5
  done
'
```

첫 대기는 CRD 생성 자체를, 두 번째 대기는 Established 상태를 확인한다. 이어지는 polling은
`kubectl api-resources --request-timeout=5s --api-group=autoscaling.k8s.io` 출력에
`verticalpodautoscalers`가 나타날 때까지 총 120초 동안 기다리고, 각 API 요청은 5초로
제한해 API server 또는 네트워크 hang이 polling deadline을 넘기지 않게 한다. timeout이면
실패한다.

실제 Helm deployer WIF context의 생성과 검증은 로컬 runbook 책임이 아니다. 정본은
Autoresearch-airflow#159의 `deploy-gke-dev.yml` preflight이며, 이 workflow가 GitHub Actions
WIF deployer GSA 자격증명으로 인증한 context에서 VPA lifecycle 모든 동사를 확인한다.
운영자 개인 kubeconfig로 WIF identity를 흉내 내거나 `--as` impersonation을 사용하지 않는다.
이 preflight는 `refs/heads/main`의 main push 배포 workflow에서 실행되므로 Airflow PR merge 전
gate가 아니라 merge 후 deployment gate다. 따라서 Role/RoleBinding은 Airflow merge 전에
`admin-apply`로 적용·검토되어야 한다.

```bash
set -e
for verb in get list watch create update patch delete; do
  kubectl auth can-i --quiet "$verb" verticalpodautoscalers.autoscaling.k8s.io --namespace airflow
done
```

하나라도 권한이 없거나 명령 오류가 발생하면 `set -e`가 preflight를 즉시 실패시킨다. Helm
배포를 중단하고 Task 4 Role/RoleBinding을 수정하며, 권한 오류를 cluster-wide RBAC로
우회하지 않는다.

Autoresearch-airflow#159가 `airflow-scheduler` VPA CR을 배포한 후에는 해당 VPA와
recommendation을 확인한다.

```bash
kubectl get vpa airflow-scheduler --namespace airflow
kubectl describe vpa airflow-scheduler --namespace airflow
```

실제 workload 데이터가 충분히 누적되기 전에는 recommendation이 비어 있을 수 있다.
초기 VPA는 observation-only `updateMode: "Off"`이므로 이 절차는 scheduler resource를
자동 변경하지 않는다.

## Bastion 접속

Bastion은 외부 IP가 없고 IAP 터널로만 접속한다. SSH 단독 접속은 점검용이다.

```bash
gcloud compute ssh autoresearch-dev-bastion \
  --zone asia-northeast3-a \
  --project autoresearch-503903 \
  --tunnel-through-iap
```

## Airflow UI 접속

Airflow UI는 인터넷에 공개하지 않는다. 기본 접속 경로는 Bastion 포트 포워딩이다.

```bash
gcloud compute ssh autoresearch-dev-bastion \
  --zone asia-northeast3-a \
  --project autoresearch-503903 \
  --tunnel-through-iap \
  -- -N -L 8080:airflow.dev.autoresearch.internal:8080
```

터널을 켠 터미널 창은 그대로 두고, 브라우저에서 아래 주소로 접속한다.

```text
http://localhost:8080
```

Google OAuth redirect URI가 `http://localhost:8080/oauth-authorized/google` 기준이라
로그인은 `localhost:8080` 경로에서만 정상 동작한다.

## MLflow UI 접속

MLflow UI도 인터넷에 공개하지 않는다(#244). 앞단 OAuth2-proxy가 Google 로그인 +
허용 이메일로 인증한다. 기본 접속 경로는 Bastion 터널이며(Airflow와 동일 패턴),
`#236` RBAC 보유자는 port-forward도 쓸 수 있다.

```bash
gcloud compute ssh autoresearch-dev-bastion \
  --zone asia-northeast3-a \
  --project autoresearch-503903 \
  --tunnel-through-iap \
  -- -N -L 4180:mlflow.dev.autoresearch.internal:4180
```

터널을 켠 터미널 창은 그대로 두고, 브라우저에서 아래 주소로 접속한다.

```text
http://localhost:4180
```

sign-in 페이지에서 Google 로그인하면 허용 이메일 목록에 있는 계정만 통과한다
(목록 밖 계정은 거부). redirect URI가 `http://localhost:4180/oauth2/callback`
기준이라 로그인은 `localhost:4180` 경로에서만 정상 동작한다. GKE 내부 워크로드
(모델 학습 등)는 인증 없이 `http://mlflow.mlflow:5000`을 tracking URI로 쓴다.

port-forward 대안(#236 RBAC 보유자):

```bash
kubectl port-forward -n mlflow svc/mlflow-oauth-proxy 4180:4180
```

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
kubectl -n elastic port-forward svc/kibana-oauth-proxy 4181:4180
```

브라우저에서 `http://localhost:4181` → Google 로그인(허용 이메일 목록, #294).
이것이 단일 표준 경로다. `svc/autoresearch-kb-http 5601` 직결 + elastic 계정
로그인은 break-glass(운영자 전용)로만 쓴다(#394부터 Kibana 자체 TLS 비활성 — http).
검색 방법과 KQL 예시는
[`KIBANA_OPERATIONS_RUNBOOK.md`](KIBANA_OPERATIONS_RUNBOOK.md) 참조.

## Inference Server 운영 (#302)

FastAPI Inference Server(`autoresearch-serving`)는 인터넷에 공개하지 않고
`autoresearch` namespace에 ClusterIP로만 둔다. 접근은 port-forward만 사용한다.

```bash
kubectl -n autoresearch port-forward svc/autoresearch-serving 8000:8000
```

**Redis 접속 정보 Secret 주입**: 파드가 Feast Online Store(Redis)에 접속하려면
operator가 주입하는 `autoresearch-serving-redis` Secret이 있어야 한다(Git·
Terraform state 어디에도 값이 없음). 값은 dev root output에서 그대로 가져온다.

```bash
# 값이 명령행·히스토리에 남지 않도록 env 파일 경유(#213 컨벤션)
umask 077
env_file="$(mktemp)"; trap 'rm -f "$env_file"' EXIT
{
  printf 'REDIS_HOST=%s\n' "$(terraform -chdir=terraform/envs/dev output -raw redis_discovery_address)"
  printf 'REDIS_PORT=%s\n' "$(terraform -chdir=terraform/envs/dev output -raw redis_discovery_port)"
} > "$env_file"
kubectl -n autoresearch create secret generic autoresearch-serving-redis \
  --from-env-file="$env_file" --dry-run=client -o yaml | kubectl apply -f -
rm -f "$env_file"; trap - EXIT
```

값을 화면·로그·PR 본문에 출력하지 않는다. 이 저장소는 public이다.

**E2E 검증**: 검증기는 앱 저장소(`SKYAHO/Autoresearch`)의
`scripts/verify_serving_e2e.py`를 그대로 쓰며, 인프라 저장소에서 새로 만들지
않는다.

```bash
kubectl -n autoresearch port-forward svc/autoresearch-serving 8000:8000
# 앱 저장소 체크아웃에서
python scripts/verify_serving_e2e.py --base-url http://127.0.0.1:8000 \
    --user-id <실제 user id> --video-ids <실제 video id들>
```

`--user-id`/`--video-ids`는 materialize된 실제 값을 써야 한다. 임의로 만든
ID는 online store에 피처가 없어 실패한다.

**모델 교체 함정**: MLflow Model Registry의 `ctr-model@champion` alias를
재지정해도 **실행 중인 파드는 모델을 바꾸지 않는다.** 모델은 FastAPI
lifespan에서 1회만 로드되고 재조회 경로가 없기 때문이다. 새 모델을 반영하려면
파드를 재시작해야 한다.

```bash
kubectl -n autoresearch rollout restart deployment/autoresearch-serving
```

이는 **이미지 digest 롤백과 별개의 축**이다 — digest를 바꾸지 않고 champion
alias만 재지정한 경우에도 재시작이 없으면 이전 모델이 계속 서빙된다.

**digest 배포·롤백**: 이미지는 tag가 아니라 immutable digest로
`deploy/serving/deployment.yaml`에 고정한다.

| 구분 | 절차 |
|---|---|
| 배포 | 앱 저장소 `release.yml`이 이미지를 GAR에 push해 digest 확보 → infra repo PR로 `deployment.yaml`의 digest 갱신 → merge → ArgoCD에서 diff 확인 후 manual sync |
| 롤백 | 이전 digest로 되돌리는 커밋 → merge → ArgoCD manual sync. git 이력이 곧 배포 이력이다 |

## Rerank serving 부하테스트 격리 (#482)

부하테스트는 운영 `autoresearch` 파드와 같은 namespace에서 실행하지 않고
`loadtest` namespace의 단기 Job으로 실행한다. 앱 저장소의
`.github/workflows/rerank-loadtest.yml`만 정확히 다음 WIF workflow ref를 통해
두 GSA를 가장할 수 있다.

```text
SKYAHO/Autoresearch/.github/workflows/rerank-loadtest.yml@refs/heads/main
```

runner GSA는 `loadtest` namespace의 RoleBinding으로 ConfigMap·Job·Pod/log와
진단 Event만 다루며, snapshot-reader GSA는 `monitoring` namespace의
`kube-prometheus-stack-prometheus` Service proxy `get`만 수행한다. 두 GSA에는
`roles/container.clusterViewer`만 GCP 프로젝트 권한으로 부여한다. Job KSA는
`rerank-loadtest`이고 서비스 계정 토큰 자동 마운트를 끈다.

앱 저장소 workflow의 `vars.RERANK_LOADTEST_RUNNER_SA`와
`vars.RERANK_PROMETHEUS_SNAPSHOT_READER_SA`에는 아래 Terraform output의
`runner`와 `snapshot_reader` 값을 각각 등록한다. WIF provider ID와 GKE cluster
변수도 기존 dev 운영 값과 동일하게 유지한다.

### 적용 전 읽기 전용 확인

아래 확인은 현재 kubeconfig가 가리키는 dev 클러스터에서만 실행한다. API가
`403 Forbidden`이면 apply나 부하테스트를 진행하지 않고 차단 사유로 기록한다.

```bash
kubectl -n autoresearch get service autoresearch-serving \
  -o jsonpath='{.spec.type}{" "}{.spec.clusterIP}{" "}{.spec.ports[?(@.port==8000)].port}{"\n"}'
kubectl -n kube-system get service kube-dns \
  -o jsonpath='{.spec.type}{" "}{.spec.clusterIP}{"\n"}'
kubectl -n monitoring get service kube-prometheus-stack-prometheus \
  -o jsonpath='{.metadata.name}{" "}{.spec.ports[?(@.port==9090)].port}{"\n"}'
```

serving/kube-dns Service가 모두 `ClusterIP`이고 각각 예상 포트를 반환해야 한다.
어느 하나라도 없거나 다른 type이면 NetworkPolicy 적용을 중단한다.

### 적용 후 읽기 전용 확인

namespace label과 quota/limit을 적용 후 확인한다.

```bash
kubectl get namespace loadtest \
  -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}{"\n"}'
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n loadtest get resourcequota rerank-loadtest-quota
kubectl -n loadtest get limitrange rerank-loadtest-limits
```

Service proxy와 RBAC의 최소 권한은 Terraform output을 직접 읽어 확인한다. 실제
GSA email은 토큰 payload가 아니므로 출력해도 되지만, 토큰 자체는 출력하지 않는다.

```bash
runner_gsa="$(terraform -chdir=terraform/envs/dev output -json rerank_loadtest_github_actions_identities | jq -r '.runner')"
snapshot_gsa="$(terraform -chdir=terraform/envs/dev output -json rerank_loadtest_github_actions_identities | jq -r '.snapshot_reader')"

kubectl auth can-i create jobs -n loadtest --as="$runner_gsa"          # yes
kubectl auth can-i patch configmaps -n loadtest --as="$runner_gsa"     # yes
kubectl auth can-i get pods/exec -n loadtest --as="$runner_gsa"        # no
kubectl auth can-i delete jobs -n loadtest --as="$runner_gsa"          # no
kubectl auth can-i get services --subresource=proxy \
  --resource-name=kube-prometheus-stack-prometheus \
  -n monitoring --as="$snapshot_gsa"                                   # yes
kubectl auth can-i get services --subresource=proxy \
  --resource-name=other-service -n monitoring --as="$snapshot_gsa"     # no
```

### 실행과 비용 경계

Workflow는 VU `1 → 2 → 4 → 8`을 순차 실행한다. 각 k6 Job은
`activeDeadlineSeconds=600`, `backoffLimit=0`, `ttlSecondsAfterFinished=86400`을
사용한다. 설정 ConfigMap은 실행 Job UID를 ownerReference로 가지므로 Job TTL
회수 시 함께 정리된다. namespace quota는 Job/Pod 보존 수를 16개(candidate 24/200
× baseline/optimized 전체 비교), 기본 container를
250m/256Mi request와 500m/512Mi limit, 최대 container를 1 CPU/1Gi로 제한한다.
이 quota/limit은 namespace에서 실제로 강제된다. 반면 deadline/TTL 값 자체는
현재 ValidatingAdmissionPolicy가 아니라 정확한 workflow manifest의 계약이므로,
Job 생성 GSA의 WIF workflow ref를 변경하지 않는 것을 함께 검증한다. 별도 node
pool, LoadBalancer, Ingress, Redis/Cloud SQL 직접 연결을 만들지 않으므로 신뢰된
workflow의 비용 상한은 최대 16개 Job의 600초 실행과 기존 dev 노드의 추가
CPU·메모리 사용량으로 계산한다. deadline을 admission 단계에서 강제해야 하면
별도 정책 이슈로 다룬다.

실제 처리속도·오류율·비용은 실행 후 artifact와 Prometheus raw snapshot으로만
기록한다. 다음 패널을 `AutoResearch / Rerank load test` 대시보드에서 같은 시간
범위로 확인한다.

- `rerank_phase_duration_seconds_bucket`: phase별 p50/p95
- `rerank_outcomes_total`: 성공/실패 outcome별 처리율
- `rerank_in_flight`: 최대 동시 처리량
- serving pod CPU, RSS, CFS throttling

### 실패·회수·롤백

실패 시 workflow를 취소하고 `loadtest` Job/Pod describe와 logs, ConfigMap
metadata를 artifact에서 확인한다. `kubectl delete`로 결과를 임의 삭제하지 않고
TTL과 ownerReference 회수를 우선 기다린다. 권한이나 네트워크 경계가 잘못된 경우
다음 순서로 되돌린다.

1. 부하테스트 workflow 재실행을 중지한다.
2. Infra PR에서 RoleBinding/NetworkPolicy/WIF 변경을 되돌리는 Terraform plan을
   검토한다. `terraform destroy`나 운영 serving 파드 강제 종료는 기본 rollback이
   아니다.
3. merge 후 ArgoCD 및 Terraform state가 원하는 namespace/RBAC/정책 상태인지
   읽기 전용 명령으로 확인한다.

실제 GKE 적용은 이 문서의 명령을 복사해 실행하기 전에 해당 Infra PR의 별도
승인을 받아야 한다.

## SOCKS 프록시 보조 경로

내부 DNS 이름 자체를 브라우저에서 확인해야 할 때만 SOCKS 프록시를 쓴다.

```bash
gcloud compute ssh autoresearch-dev-bastion \
  --zone asia-northeast3-a \
  --project autoresearch-503903 \
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
| Online Store Redis Cluster | `autoresearch` pod에서 PSC discovery endpoint로 TLS 접속 | app GSA Workload Identity로 IAM token 발급, CA는 Secret Manager 조회, 로컬 직접 접속 금지 (#129, apply·검증 완료) |
| MLflow UI | Bastion IAP 터널 `-L 4180` 또는 `kubectl -n mlflow port-forward svc/mlflow-oauth-proxy 4180:4180` | Google 로그인(#232), 외부 공개 금지 |
| Kibana UI | `kubectl -n elastic port-forward svc/kibana-oauth-proxy 4181:4180` | Google 로그인(#294), 외부 공개 금지 |
| GKE node SSH | IAP tunneling | 디버깅 목적, 최소 사용 |

VPN은 현재 dev 규모에서는 기본 경로가 아니다. 팀원 수가 늘거나 내부 서비스 접속이
상시 업무가 되면 별도 이슈에서 Cloud VPN 또는 더 관리형인 접근 방식을 재평가한다.

## Workload Identity 운영 메모

Airflow 기본 component와 batch pod는 서로 다른 GCP service account를 사용한다.

| Kubernetes service account | GCP service account | 목적 |
|---|---|---|
| `autoresearch/autoresearch-app` | `autoresearch-dev-app@autoresearch-503903.iam.gserviceaccount.com` | 앱 DB secret과 Redis CA 조회, cluster 한정 IAM 연결 token 발급 (#129, apply·검증 완료) |
| `airflow/airflow` | `autoresearch-dev-airflow@autoresearch-503903.iam.gserviceaccount.com` | Airflow metadata DB, DAG/log bucket, OAuth secret |
| `airflow/autoresearch-batch` | `autoresearch-dev-airflow-batch@autoresearch-503903.iam.gserviceaccount.com` | batch API key secret, raw data bucket, Feast GCS/BigQuery, Cloud Run proxy invoker |

`autoresearch-batch` annotation은 아래 값이어야 한다.

```text
iam.gke.io/gcp-service-account=autoresearch-dev-airflow-batch@autoresearch-503903.iam.gserviceaccount.com
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
- `terraform/admin/monitoring-k8s/terraform.tfvars` (`monitoring_port_forward_user_emails`)
- `terraform/admin/mlflow-k8s/terraform.tfvars` (`mlflow_viewer_user_emails`, #236)

이미 발급된 access token은 보통 최대 1시간 정도 더 유효할 수 있다. kubeconfig가
로컬에 남아 있어도 다음 인증부터는 권한이 없어 403으로 실패한다.

## 보안 원칙

- kubeconfig 파일을 서로 공유하지 않는다.
- service account JSON key를 발급하거나 전달하지 않는다.
- 실제 secret 값, Terraform state, `terraform.tfvars` 실값을 커밋하지 않는다.
- `kubectl` 명령 전에는 항상 current context를 확인한다.
- 팀원 개인 계정에 Secret Manager payload 직접 읽기 권한을 주지 않는다.
