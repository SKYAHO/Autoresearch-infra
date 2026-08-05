# Auto Research 실험 Job 운영 Runbook

## 목적과 책임 경계

이 문서는 Issue #484의 dev GKE 실험 실행 경계를 운영하기 위한 절차다. 실험 하나는
Kubernetes Job 하나, Pod 하나, 주 컨테이너 하나로 실행하고 종료한다. 실제 실험 요청
API, Job 생성기, 상태 watcher, 에이전트 실행 코드는 `SKYAHO/Autoresearch`가 소유한다.
이 저장소는 namespace·KSA/GSA·RBAC·Pod Security·NetworkPolicy·결과 저장소를
소유한다.

외부 Ingress, public IP, LoadBalancer는 만들지 않는다. 실험 Job은 GitHub에 push하거나
PR을 생성·병합하지 않으며, Kubernetes Secret·Cloud SQL·Redis·MLflow 접근도 기본으로
갖지 않는다.

## 적용 전 확인

실제 Terraform apply는 별도 승인 후에만 수행한다. 적용 전에는 dev root와 admin root의
계약 값이 일치하는지 확인하고, 실제 `terraform.tfvars`, state, plan 파일, credential을
Git 또는 로그에 남기지 않는다.

```bash
terraform -chdir=terraform/envs/dev output experiment_job_execution_contract
terraform -chdir=terraform/admin/autoresearch-k8s plan -var-file=terraform.tfvars
```

아래 값이 일치해야 한다.

| 항목 | 기본값 |
|---|---|
| namespace | `autoresearch-experiments` |
| Job KSA | `experiment-job` |
| GSA | `autoresearch-dev-exp-job@<project>.iam.gserviceaccount.com` |
| 결과 버킷 | `<project>-autoresearch-dev-experiment-results` |
| 결과 권한 | Job GSA `roles/storage.objectCreator`, 상태 API GSA `roles/storage.objectViewer` |

API KSA의 Job 생성 권한은 `enable_experiment_job_creation=false`가 기본이다. 고정
템플릿, 허용 image digest, admission 검증이 적용되기 전에는 이 값을 변경하지 않는다.
`autoresearch-experiment-job-contract` ValidatingAdmissionPolicy는 create/modify 요청에서
Job KSA, sha256 digest image, `batch-od` nodeSelector/toleration을 서버 측으로 강제한다.

`enable_experiment_job_creation`을 활성화하기 전에는 다음도 선행 조건으로 확인한다
(#497 — RBAC는 admin apply로 반영되지만 상태 조회 egress는 ArgoCD가 관리하는
`deploy/agent-orchestration/network-policy.yaml`로 별도 sync가 필요해, RBAC만 반영되고
egress가 반영되지 않으면 "제출은 되지만 상태를 읽지 못하는" 상태가 남는다).

`172.16.128.1/32`(services CIDR 첫 IP, pre-DNAT 경로용)는 `config/environments/dev/environment.yaml`의
`services_cidr: 172.16.128.0/24`에서 파생된 값이다. `gke_services_cidr`가 바뀌면
`deploy/agent-orchestration/network-policy.yaml`·`docs/TERRAFORM_DEV.md`·이 문서 세 곳을
함께 갱신해야 하며, 갱신을 놓치면 아래 게이트가 옛 값 기준으로 "반영됨"을 오탐 출력할 수
있다. manifest는 pre-DNAT용 services CIDR VIP와 post-DNAT용 control plane CIDR
(`172.16.0.0/28`) 두 ipBlock을 함께 열므로 게이트도 둘 다 확인한다.

```bash
POLICY=$(kubectl -n autoresearch get networkpolicy agent-orchestration-api-egress \
  -o jsonpath='{.spec.egress}' 2>&1)
if [ $? -ne 0 ]; then
  echo "조회 실패 — NetworkPolicy 부재 또는 kubectl 권한(networkpolicies get) 부족: $POLICY"
elif echo "$POLICY" | grep -q '172.16.128.1/32' && echo "$POLICY" | grep -q '172.16.0.0/28'; then
  echo "K8s API egress(services CIDR VIP + control plane CIDR) 반영됨"
else
  echo "NetworkPolicy는 존재하나 egress 규칙 미반영 — ArgoCD sync 선행 필요"
fi
```

이 게이트는 두 CIDR 문자열의 존재만 확인하므로, live 값이 **정확히 핀으로 지정한 커밋
SHA**에서 나왔음을 보증하지 않는다 — 우연히 같은 IP를 포함한 이전 revision의 규칙이
남아 있어도 "반영됨"으로 보고될 수 있다. SHA 수준까지 확인하려면 ArgoCD가 실제로 sync한
커밋을 함께 대조한다.

```bash
kubectl -n argocd get application agent-orchestration -o jsonpath='{.status.sync.revision}'
```

## Job manifest 계약

API는 사용자가 보낸 임의 manifest를 Kubernetes API로 전달해서는 안 된다. 서버가
검증한 값으로 고정 템플릿을 만들고 다음 조건을 강제한다.

- 이름은 `experiment-<정규화된-실험ID>-<시도ID>` DNS-1123 형식이다.
- image는 registry path와 `@sha256:` digest를 포함하며 mutable tag를 허용하지 않는다.
- `serviceAccountName: experiment-job`, `restartPolicy: Never`, `backoffLimit: 0`을 쓴다.
- `activeDeadlineSeconds`와 `ttlSecondsAfterFinished`는 각각 3,600초 이하로 제한한다.
  두 값이 **각각** 상한이므로 한 Job이 슬롯을 잡는 최악 시간은 실행 최대 1시간 +
  완료 후 TTL 최대 1시간 = **최대 2시간**이다. `count/jobs.batch=2`와 결합하면
  최악의 경우 처리량은 2시간당 2개다. 상한이 아니라 실제 처리량을 높이려면 API
  고정 템플릿이 TTL을 짧게(예: 300초) 넣어야 하며, 그 값이 실질 회수 주기를
  결정한다.
- `suspend: true`로 제출하지 않는다. suspend 상태 Job은 Pod를 만들지 않고
  `activeDeadlineSeconds` 타이머도 돌지 않으며 TTL도 적용되지 않아 quota를
  무기한 점유한다. admission 정책이 이를 거부한다.
- 모든 컨테이너에 CPU·메모리 request/limit을 명시하고 namespace의 단일 컨테이너 최대 1 vCPU/2 GiB를 넘기지 않는다.
- `nodeSelector`는 `cloud.google.com/gke-nodepool: batch-od`, toleration은
  `workload=batch-od:NoSchedule`만 사용한다. 일반 앱 pool에는 스케줄하지 않으며,
  admission 검증은 이 두 값을 변경·누락한 Job을 거부해야 한다.
- `hostNetwork`, `hostPID`, `hostIPC`, privileged, hostPath, 추가 Linux capability, root 실행을 사용하지 않는다. Pod Security `restricted` 요구를 충족하는 `runAsNonRoot`, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`, capability drop `ALL`을 설정한다.
- 요청 원문과 credential을 환경변수·label·annotation·로그에 넣지 않는다.
- `autoresearch.io/experiment-id`, source revision, image digest, result URI는 검증된 값만 기록한다.
- 결과는 `gs://<결과-버킷>/experiments/<실험ID>/<시도ID>/` 아래에만 저장한다.
  **경로 재사용을 막는 것은 IAM이 아니라 앱의 precondition이다** — 이 버킷은
  versioning이 켜져 있어 `storage.objects.create`만으로도 같은 경로에 새
  generation을 만들 수 있다(GCS에서 delete 권한이 필요한 overwrite는 versioning이
  꺼진 버킷에 한한다). 따라서 앱이 `ifGenerationMatch=0`(create-if-absent)과 새
  시도 ID prefix로 경로 재사용을 거부해야 하며, IAM이 보장하는 것은 Job이 이전
  결과를 읽거나 삭제할 수 없다는 점이다. 덮어쓰기가 일어나도 이전 generation은
  noncurrent로 보존돼 감사 흔적이 남는다.

결과 메타데이터에는 metric, 평가 기준, 데이터 버전, source revision, image digest,
시작·종료 시각, Job UID를 기록한다. lifecycle은 live object가 90일 후 archive되고,
archived generation은 noncurrent이 된 시점부터 30일을 더 보존한 뒤 영구 삭제한다.
versioning은 운영자 복구·정정으로 생긴 이전 generation의 명시적 복구 창이며, 장기
보존 수단이 아니므로 장기 보관이 필요한 결과는 별도 승인된 경로로 이관한다.

GKE Workload Identity에서 컨테이너의 ADC/GCS client는 GKE metadata server에 token을
요청한다. metadata server는 호출 Pod의 source identity, `experiment-job` KSA annotation,
GSA의 `roles/iam.workloadIdentityUser` binding을 사용해 결과 버킷 쓰기용 GCP access
token을 발급한다. Kubernetes API token mount는 이 교환에 필요하지 않으므로 이 KSA는
명시적으로 `false`다.

저신뢰 에이전트가 Kubernetes 리소스 조회·수정, Secret 조회, exec, cluster 권한
상승을 할 수 없는 근거는 서로 독립적인 세 겹이다. KSA에 설정한
`automountServiceAccountToken: false`는 이 중 **한 겹이 아니라 Pod가 되돌릴 수 있는
기본값**이라는 점이 중요하다 — Pod spec에서 `true`로 덮어쓸 수 있고 Pod Security
`restricted`도 이 필드를 통제하지 않는다.

1. **admission**: `autoresearch-experiment-job-contract` 정책이
   `spec.template.spec.automountServiceAccountToken`을 `false` 또는 미설정으로만
   허용한다. 손상된 API가 template에서 되돌리는 경로를 서버가 거부한다.
2. **네트워크**: egress NetworkPolicy는 services CIDR에 UDP/TCP **53만** 허용하므로
   같은 대역의 `kubernetes.default.svc:443`에 도달할 수 없고, control plane
   master CIDR도 허용 목록에 없다. token을 손에 넣어도 API를 호출할 경로가 없다.
3. **RBAC**: `experiment-job` KSA에는 이 namespace에 RoleBinding이 하나도 없다
   (`experiment-job-observer`는 API KSA에 바인딩된다). 도달하더라도 부여된 권한이
   없다.

GCP 측에서도 결과 버킷 새 객체 생성 외 권한은 없다. 실제로 열려 있는 자격은
metadata server(egress 허용 대상)를 통한 GSA token이며, 그 권한 범위가 이 워크로드의
실질 신뢰 경계다.

Job 템플릿이 KSA를 누락하면 Kubernetes의 `default` KSA token mount 기본값을 따를 수
있지만, 이 namespace에서는 ValidatingAdmissionPolicy가 해당 Job을 admission에서 거부한다.
또한 default KSA에는 RoleBinding이 없고 namespace egress 정책은 Kubernetes API HTTPS를
허용하지 않아, RBAC와 NetworkPolicy가 추가 방어층으로 남는다.

`roles/storage.objectCreator`만 가진 Job은 업로드한 객체를 다시 GET/list하거나
무결성 검증을 위해 읽을 수 없다. 업로드 요청은 `ifGenerationMatch=0` precondition과
응답의 generation/checksum으로 성공 여부를 확인한다. 같은 경로가 이미 있으면 GCS는
새 generation을 만들지 않고 HTTP 412를 반환하므로 재시도하지 않는다. IAM 거부는 HTTP
403이며 구성·권한 오류로 분류한다. 상태 API GSA만 bucket-scoped `objectViewer`로 결과를
읽고 응답을 인증·감사하며, 사용자에게 버킷 IAM이나 공개 URL을 직접 부여하지 않는다.

## 적용 후 권한 검증

아래 검증은 적용된 cluster에서 운영자가 수행한다. `--as`의 ServiceAccount 형식은
Kubernetes RBAC만 확인하며, GCP IAM 권한을 대신 검증하지 않는다.

```bash
API_SA='system:serviceaccount:autoresearch:agent-orchestration-api'

kubectl auth can-i get jobs -n autoresearch-experiments --as="$API_SA"       # yes
kubectl auth can-i get pods -n autoresearch-experiments --as="$API_SA"       # yes
kubectl auth can-i get pods/log -n autoresearch-experiments --as="$API_SA"   # yes
kubectl auth can-i get events -n autoresearch-experiments --as="$API_SA"     # yes
kubectl auth can-i create jobs -n autoresearch-experiments --as="$API_SA"    # no (기본값)
kubectl auth can-i get secrets -n autoresearch-experiments --as="$API_SA"    # no
kubectl auth can-i create pods/exec -n autoresearch-experiments --as="$API_SA" # no
kubectl auth can-i create clusterroles.rbac.authorization.k8s.io --as="$API_SA" # no
kubectl auth can-i get jobs -n autoresearch --as="$API_SA"                    # no
```

생성 권한을 승인해 활성화한 경우에만 다섯 번째 결과가 `yes`여야 하며, 나머지 거부
결과는 유지되어야 한다. Job KSA에는 RoleBinding이 없어야 한다.

API는 Event 전체를 사용자에게 그대로 노출하지 않고, 해당 실험 Job/Pod를
`involvedObject`로 참조하는 Event만 상태 원인에 연결한다. `ImagePullBackOff`,
`FailedScheduling`, `FailedCreate`/quota 초과는 이 Event 읽기 권한으로 관측한다.

```bash
kubectl -n autoresearch-experiments get rolebindings -o yaml
kubectl -n autoresearch-experiments get serviceaccount experiment-job -o yaml
```

## Pod Security, 한도, 네트워크 음성 검증

다음 명령은 서버 측 dry-run이므로 실제 Job을 만들지 않는다. 위험한 manifest는 Pod
Security `restricted`에 의해 거부되어야 한다.

```bash
kubectl -n autoresearch-experiments create --dry-run=server -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: experiment-hostnetwork-negative
spec:
  template:
    spec:
      restartPolicy: Never
      hostNetwork: true
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
EOF
```

`autoresearch-experiment-job-contract` 정책의 거부 경로도 같은 방식으로 확인한다.
아래 네 manifest는 각각 다른 규칙에 걸려야 하며, 모두 admission 단계에서 거부된다.
정책은 `failurePolicy: Fail` + binding `validationActions: ["Deny"]`이므로 규칙
위반과 필드 누락 모두 최종 결과가 deny다. 필드 누락 거부는 CEL 런타임 오류에 기대지
않고 `has()`/`in` 가드로 규칙에 명시돼 있어, 메시지로 사유가 구분된다.

| 음성 케이스 | 기대 거부 사유 |
|---|---|
| `initContainers`에 mutable tag 이미지 | 모든 컨테이너(initContainers 포함) digest 고정 |
| `nodeSelector` 미지정 | nodeSelector로 batch-od 명시 |
| `serviceAccountName` 미지정 | 승인된 serviceAccountName 명시 |
| `tolerations`에 batch-od 외 항목 추가, `tolerations: []`, key/value/effect 누락 | `workload=batch-od:NoSchedule` 하나만 사용 (`operator` 생략은 허용 — Kubernetes 의미상 Equal) |
| 허용 Artifact Registry 밖 이미지(digest는 고정) | 승인된 저장소에서만 pull |
| `activeDeadlineSeconds`/`ttlSecondsAfterFinished` 미지정 또는 3600 초과 | 각 필드 범위 |
| `automountServiceAccountToken: true` | ServiceAccount token mount 금지 |
| `suspend: true` | suspend 상태 제출 금지 |

```bash
kubectl -n autoresearch-experiments create --dry-run=server -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: experiment-initcontainer-negative
spec:
  activeDeadlineSeconds: 3600
  ttlSecondsAfterFinished: 3600
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: experiment-job
      nodeSelector:
        cloud.google.com/gke-nodepool: batch-od
      tolerations:
        - key: workload
          operator: Equal
          value: batch-od
          effect: NoSchedule
      initContainers:
        - name: prep
          image: registry.k8s.io/pause:3.10
      containers:
        - name: run
          image: registry.k8s.io/pause@sha256:0000000000000000000000000000000000000000000000000000000000000000
EOF
```

`activeDeadlineSeconds`와 `ttlSecondsAfterFinished`는 이 정책이 서버 측에서 강제한다.
두 필드가 없으면 완료 Job이 `count/jobs.batch=2` quota를 무기한 점유하는데, 이 root는
API KSA에 `delete`를 부여하지 않고 `enable_experiment_job_creation = false` 롤백도
실행 중 Job을 멈추지 않으므로 회수 경로가 break-glass 관리자 권한만 남는다. 정책이
두 필드를 필수·상한으로 요구하면 그 상태 자체가 만들어지지 않는다.

정상 Job을 승인된 digest로 하나 제출하기 전에는 NetworkPolicy가 다음 통신 외에는
차단하는지 검토한다.

| 허용 대상 | 포트 | 용도 |
|---|---:|---|
| cluster DNS / `kube-system` DNS | UDP/TCP 53 | live dev cluster의 kube-dns Service 경로 |
| GKE metadata | TCP 80, 987, 988 | Workload Identity token 교환 |
| `199.36.153.8/30` | TCP 443 | Private Google APIs를 통한 결과 GCS 업로드 |

Cloud SQL, Redis, MLflow, `0.0.0.0/0:443`, 외부 AI API는 허용 목록에 없다. 새 연결은
별도 보안 검토에서 목적지, 포트, 필요한 GSA IAM과 데이터 유출 위험을 함께 승인한다.

`terraform/envs/dev/dns.tf`의 VPC 전용 `googleapis.com.` zone은
`*.googleapis.com`을 `private.googleapis.com` VIP(`199.36.153.8/30`)로 해석시키며,
`vpc.tf`의 Private Google Access route가 해당 VIP 경로를 제공한다. zone/CNAME이
없거나 변경되면 `storage.googleapis.com`은 public IP로 해석되어 NetworkPolicy drop에
따른 HTTPS timeout이 발생한다. DNS 자체가 실패하면 이름 해석 오류로 구분한다.
route가 없거나 방화벽이 차단하면 역시 연결 timeout이 발생한다.

현재 live dev cluster의 NodeLocal DNSCache 상태는 이 실험 PR에서 변경하거나 전제로
삼지 않는다. Cloud DNS for GKE를 사용하지 않는 구성에서는 Pod DNS 목적지가 kube-dns
Service IP다. services CIDR 규칙은 service VIP에 대해 pre-DNAT로 정책을 평가하는
dataplane을, `kube-system` selector는 post-DNAT로 평가하는 dataplane을 각각 대비한다.
Cloud DNS for GKE를 활성화하면 Pod nameserver가
`169.254.20.10`으로 바뀌므로, 그 변경 이슈에서 해당 `/32`의 UDP/TCP 53 egress를
추가하고 dry-run과 실제 DNS 검증을 함께 수행한다.

이 private zone은 `googleapis.com`만 대상으로 한다. `pkg.dev`, `gcr.io`, `run.app`,
외부 AI API와 일반 인터넷 endpoint는 이 VIP로 해석되지 않으며 실험 Pod의 egress
allowlist에도 없다. 이미지 pull은 노드가 수행하는 별도 경로이므로, 실험 이미지와
Artifact Registry 접근은 Job 제출 전에 검증한다.

## 장애 처리와 롤백

1. API에서 새 실험 제출을 중지하고 실행 중 Job의 ID·상태·결과 URI를 기록한다. 현재
   API에는 Job delete 권한이 없으므로 사용자 취소는 지원하지 않으며, 실행 중 Job은
   `activeDeadlineSeconds` 종료를 기다린다.
2. 이미지 pull 실패, Pending, OOMKilled, deadline 초과, 애플리케이션 exit code를
   구분해 원인을 조사한다. API는 해당 Job/Pod Event에서 `ImagePullBackOff`,
   `FailedScheduling`, `FailedCreate`를 확인한다. `FailedCreate`는 quota 초과
   외에 `experiment_jobs.tf`의 Pod 합계 `LimitRange`(컨테이너 합계가 1 vCPU/2 GiB를
   넘음) 위반으로도 발생할 수 있다 — 이 경우 Pod 자체가 생성되지 않으므로
   `pods`/`requests.cpu` quota는 소비되지 않는다(#523). 실패한 Job을 자동
   재시도하지 않는다.
3. 권한 또는 Job 명세 취약점이 의심되면 `enable_experiment_job_creation`을 `false`로 되돌리는 Terraform 변경을 검토하고, 승인된 apply로 반영한다.
4. 결과 버킷, namespace, KSA, GSA를 삭제하지 않는다. 삭제는 감사·재현·다른 실행의 복구를 훼손할 수 있으므로 별도 변경과 승인 절차가 필요하다.
5. 수정된 템플릿과 digest로 새 시도 ID의 Job을 만든다. 같은 prefix를 재사용하지 않는다.
   단, 완료 Job도 `count/jobs.batch=2` quota를 TTL controller가 삭제할 때까지 점유한다.
   두 개의 완료 Job이 남은 상태에서는 세 번째 create가 `Forbidden` quota 초과로
   거부되며, API는 재시도 가능 상태로 기록해 TTL 정리 후 제출한다. terminal Pod는
   `pods=2` 계산에서 제외될 수 있으므로 운영 병목은 Job 객체 quota다.

`ttlSecondsAfterFinished` 누락 또는 TTL controller 장애로 quota가 회수되지 않으면
API는 새 제출을 차단하고 운영자에게 escalate한다. API는 delete 권한이 없으므로,
운영자는 결과 URI·Job 상태·감사 메타데이터를 확인한 뒤 break-glass cluster 관리자
권한으로 명시적으로 회수한다. 이 권한은 API KSA나 실험 KSA에 부여하지 않는다.
`enable_experiment_job_creation=false` 적용은 새 Job 제출만
막으며, 이미 실행 중인 Job을 취소·중지하지 않는다.

비용 경보나 quota 초과가 발생하면 API 동시 제출 제한을 먼저 낮춘다. namespace quota
상향은 node 여유, 예상 최대 실행 시간, 비용 상한을 문서화한 별도 이슈에서 검토한다.

`batch-od`는 #297 대응으로 만들었지만, 현재 `Autoresearch-airflow`의 어떤 KPO도 이
pool로 스케줄되지 않는다(#523, 2026-08-04 조사). `AutoresearchBatchPodOperator`는
`node_selector`/`tolerations`를 넘기지 않으면 `batch-spot`을 기본값으로 쓰고, 이를
override하는 DAG가 없다 — Action Log KPO를 포함해 모든 KPO가 지금도 `batch-spot`에서
돈다(#297 이후 채택된 완화책은 pool 이전이 아니라 체크포인트 재개 + timeout 연장,
#150). 즉 `batch-od`는 현재 유휴 pool이며 experiment Job이 별도 경합 계획 없이
그대로 써도 된다. 운영 중에는 batch-od node 수, Pending Pod, autoscaler 이벤트,
CPU/memory request를 관측한다. 이후 Airflow나 다른 컴포넌트가 `batch-od`에 실제로
스케줄되도록 바뀌면(예: `node_selector`를 명시적으로 override하는 DAG 변경), 그
시점에 capacity·우선순위 경합 계획을 다시 검토한다.

이 유휴 상태 전제는 이 저장소 밖(`Autoresearch-airflow`)의 상태에 의존하고, 그
저장소의 변경은 이 저장소의 CI·리뷰를 거치지 않는다. 정확한 수치로 다시 쓰면:
pool 전체 allocatable CPU는 노드 2대 기준 약 3860m이고, 실험 namespace quota는
`requests.cpu = 2`(2000m)로 그 일부만 쓴다. `LimitRange` 기본 request는 500m라
실제 experiment 점유는 제출된 Job의 request 값에 따라 다르다. Airflow DAG 하나가
`node_selector`를 `batch-od`로 override하면, 두 워크로드의 request 합이 그 순간
가용 노드 용량을 넘어설 때만 경합이 생긴다. 이 계약에는 `priorityClassName`이
없어 두 워크로드 사이에 선점(preemption) 순서가 없으므로 — 어느 쪽이 Pending으로
남는지는 우선순위가 아니라 어느 Pod가 나중에 제출돼 가용 용량이 이미 소진된
상태에 걸리는지(제출 순서·스케줄 타이밍)로 결정된다. Pending은 자동으로 사라지지
않고, 상대 워크로드의 Pod가 끝나 용량이 비어야 풀린다 — experiment Job 쪽은
admission이 강제하는 `activeDeadlineSeconds`(최대 3600초)로 상한이 있지만, KPO
쪽 재시도·timeout 정책은 이 저장소가 아니라 `Autoresearch-airflow`가 정하므로
이 문서가 그 대기 시간을 보장하지 않는다. 즉 이 문단은 그런 경합에서 #297이
재현되지 않는다고 주장하지 않는다 — 오히려 실제로 이런 경합이 생기면 #297
재현 여부를 포함해 그 시점에 capacity·우선순위 계획을 별도로 다시 승인해야
한다는 것이 위 재검토 요구의 근거다. `batch-od` node/pod Pending 관측(위)을
수동 확인에서 알림으로 승격하는 안(예: `autoresearch-experiments` namespace
밖 Pod가 `batch-od` 노드에 뜨면 알림, 또는 `batch-od` 대상 Pending Pod 알림)을
#523의 후속 체크리스트 항목으로 추적한다.

## Pod Security 버전 갱신

현재 enforce 기준은 live GKE control plane의 `v1.35`로 고정했다. 이 pin은 control
plane이 이후 v1.36 이상으로 올라가도 v1.35 `restricted` 요구만 강제한다. 대신
audit/warn은 `latest`이므로 다음 정책에서 새로 위반되는 Job을 경고·감사 로그로 먼저
드러낸다. GKE upgrade 전에는 새 minor 버전 기준 server-side dry-run을 실행하고, 모든
실험 이미지가 통과한 뒤 `enforce-version`을 의도적으로 올린다. apply 시점의 control
plane이 pin한 minor를 지원하는지는 `gcloud container clusters describe`로 먼저 대조한다.
