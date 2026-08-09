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
| 결과 권한 | Job GSA `roles/storage.objectCreator` + `roles/storage.objectViewer`, 상태 API GSA `roles/storage.objectViewer` |

Job이 읽는 학습 입력은 같은 전용 버킷의 아래 사전 게시 객체다.

```text
gs://<project>-autoresearch-dev-experiment-results/training-snapshots/by-hash/<sha256>/training_dataset.csv
gs://<project>-autoresearch-dev-experiment-results/training-snapshots/by-hash/<sha256>/snapshot_manifest.json
```

실험 결과 버킷은 다른 용도의 객체를 담지 않으므로 Job GSA의 viewer는 bucket-level로
관리한다. 프로젝트 수준 권한, `objectAdmin`, 삭제 권한은 없다.

Job 생성 권한은 고정 템플릿, 허용 image digest, admission 검증, batch-od
용량 계획, NetworkPolicy sync 재확인, negative dry-run 4종 재실행까지 선행 조건이
모두 충족돼 `enable_experiment_job_creation=true`로 전환됐다(#523, 2026-08-05).
**#539에서 이 권한의 주체가 API KSA에서 launcher KSA로 바뀌었다** — API는 상태
조회만 하고 Job을 만들지 않는다. 자세한 내용은
[실험 브랜치 launcher 운영](#실험-브랜치-launcher-운영-539)을 본다.
`autoresearch-experiment-job-contract` ValidatingAdmissionPolicy는 create/modify 요청에서
Job KSA, sha256 digest image, `batch-od` nodeSelector/toleration을 서버 측으로 강제하고,
#539에서 branch-bootstrap Pod 형태 계약 7종이 추가됐다.

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

> **#539 이후 이 절의 주체가 바뀌었다.** 이 절은 #484/#523 시점에 "API가 실험 Job을
> 만든다"는 전제로 쓰였다. Phase 1에서 이 namespace에 Job을 만드는 주체는 launcher
> 하나이고 API에는 생성 권한이 없다. 아래 조건 대부분(digest, KSA, `backoffLimit`,
> deadline/TTL, suspend 금지, nodeSelector/toleration, Pod Security, 시크릿 비노출)은
> 주체와 무관하게 그대로 유효하며, 지금은 launcher의 고정 템플릿과 admission 정책이
> 함께 강제한다. **Job 이름 규칙만 Phase 1에서 다르다** — 아래 첫 항목이 아니라
> [실험 브랜치 launcher 운영](#실험-브랜치-launcher-운영-539)의
> `ar-branch-<experiment UUID hex>`가 현재 유일하게 생성되는 Job 이름이다.

Job을 만드는 주체는 사용자가 보낸 임의 manifest를 Kubernetes API로 전달해서는 안
된다. 서버가 검증한 값으로 고정 템플릿을 만들고 다음 조건을 강제한다.

- 이름은 `experiment-<정규화된-실험ID>-<시도ID>` DNS-1123 형식이다(#484 실험 실행
  Job 기준. Phase 1의 branch-bootstrap Job은 위 안내대로 다른 규칙을 쓴다).
- image는 registry path와 `@sha256:` digest를 포함하며 mutable tag를 허용하지 않는다.
- `serviceAccountName: experiment-job`, `restartPolicy: Never`, `backoffLimit: 0`을 쓴다.
- `activeDeadlineSeconds`는 60,000초 이하, `ttlSecondsAfterFinished`는 3,600초
  이하로 제한한다. 두 값이 **각각** 상한이므로 한 Job이 슬롯을 잡는 최악 시간은
  실행 최대 16시간 40분 + 완료 후 TTL 최대 1시간 = **최대 17시간 40분**이다.
  `count/jobs.batch=2`와 결합하면 완료 Job도 TTL까지 quota를 점유하므로 Stage 1
  budget을 쓰는 최대 처리량은 17시간 40분당 2개다. 이는 batch-od 비용과 대기 시간을
  늘리는 의도된 상한이다. 더 빠른 회수가 필요하면 API 고정 템플릿이 TTL을
  짧게(예: 300초) 넣어야 하며, 그 값이 실질 회수 주기를 결정한다.
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
GSA의 `roles/iam.workloadIdentityUser` binding을 사용해 결과 버킷 객체 생성·게시
snapshot 읽기용 GCP access token을 발급한다. Kubernetes API token mount는 이 교환에
필요하지 않으므로 이 KSA는 명시적으로 `false`다.

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

GCP 측에서도 결과 버킷 객체 생성과 게시 snapshot 읽기 외 권한은 없다. 실제로 열려
있는 자격은 metadata server(egress 허용 대상)를 통한 GSA token이며, 그 권한 범위가
이 워크로드의 실질 신뢰 경계다.

### 학습 snapshot IAM 적용 후 확인

Terraform apply 뒤에는 viewer가 대상 버킷에 붙었는지와 알려진 manifest를 읽을 수
있는지를 확인한다. 아래 명령은 apply 권한을 부여하지 않는다.

```bash
gcloud storage buckets get-iam-policy \
  gs://<project>-autoresearch-dev-experiment-results --format=json

gsutil cat gs://<project>-autoresearch-dev-experiment-results/training-snapshots/by-hash/<sha256>/snapshot_manifest.json
```

권한 문제로 학습이 실패하면 launcher CronJob을 먼저 suspend하고, 승인된 Terraform
revert로 viewer binding과 snapshot root 좌표를 되돌린다. 버킷·GSA·KSA는 삭제하지 않는다.

Job 템플릿이 KSA를 누락하면 Kubernetes의 `default` KSA token mount 기본값을 따를 수
있지만, 이 namespace에서는 ValidatingAdmissionPolicy가 해당 Job을 admission에서 거부한다.
또한 default KSA에는 RoleBinding이 없고 namespace egress 정책은 Kubernetes API HTTPS를
허용하지 않아, RBAC와 NetworkPolicy가 추가 방어층으로 남는다.

`experiment-job` GSA는 결과 버킷에서 객체를 만들고 게시 snapshot을 읽을 수 있지만
삭제·overwrite 권한은 없다. 업로드 요청은 `ifGenerationMatch=0` precondition과
응답의 generation/checksum으로 성공 여부를 확인한다. 같은 경로가 이미 있으면 GCS는
새 generation을 만들지 않고 HTTP 412를 반환하므로 재시도하지 않는다. IAM 거부는 HTTP
403이며 구성·권한 오류로 분류한다. 상태 API GSA는 같은 bucket-scoped `objectViewer`로
결과를 읽고 응답을 인증·감사하며, 사용자에게 버킷 IAM이나 공개 URL을 직접 부여하지 않는다.

## 적용 후 권한 검증

아래 검증은 적용된 cluster에서 운영자가 수행한다. `--as`의 ServiceAccount 형식은
Kubernetes RBAC만 확인하며, GCP IAM 권한을 대신 검증하지 않는다.

```bash
API_SA='system:serviceaccount:autoresearch:agent-orchestration-api'

kubectl auth can-i get jobs -n autoresearch-experiments --as="$API_SA"       # yes
kubectl auth can-i get pods -n autoresearch-experiments --as="$API_SA"       # yes
kubectl auth can-i get pods/log -n autoresearch-experiments --as="$API_SA"   # yes
kubectl auth can-i get events -n autoresearch-experiments --as="$API_SA"     # yes
kubectl auth can-i create jobs -n autoresearch-experiments --as="$API_SA"    # no (#539)
kubectl auth can-i get secrets -n autoresearch-experiments --as="$API_SA"    # no
kubectl auth can-i create pods/exec -n autoresearch-experiments --as="$API_SA" # no
kubectl auth can-i create clusterroles.rbac.authorization.k8s.io --as="$API_SA" # no
kubectl auth can-i get jobs -n autoresearch --as="$API_SA"                    # no
```

**API의 `create jobs`는 `enable_experiment_job_creation` 값과 무관하게 항상 `no`다.**
#539에서 그 권한을 launcher KSA로 옮겼기 때문이다. 여기서 `yes`가 나오면 옛
`experiment-job-creator` RoleBinding이 apply로 정리되지 않고 남은 것이므로 조사한다.

launcher는 별도로 확인한다. 아래 다섯 결과가 모두 기대와 같아야 한다.

```bash
LAUNCHER_SA='system:serviceaccount:autoresearch:agent-orchestration-launcher'

kubectl auth can-i create jobs -n autoresearch-experiments --as="$LAUNCHER_SA"  # yes
kubectl auth can-i get jobs -n autoresearch-experiments --as="$LAUNCHER_SA"     # yes
kubectl auth can-i list jobs -n autoresearch-experiments --as="$LAUNCHER_SA"    # yes
kubectl auth can-i delete jobs -n autoresearch-experiments --as="$LAUNCHER_SA"  # no
kubectl auth can-i get secrets -n autoresearch-experiments --as="$LAUNCHER_SA"  # no
```

`enable_experiment_job_creation=false`로 되돌리면 위 세 `yes`가 모두 `no`가 된다.
`delete`가 `yes`로 나오면 최소 권한 계약이 깨진 것이므로 즉시 조사한다 — 회수는
`activeDeadlineSeconds`와 TTL controller가 담당하고 어떤 KSA도 delete를 갖지 않는다.

executor Job KSA(`experiment-job`)에는 RoleBinding이 없어야 한다.

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
| `activeDeadlineSeconds` 미지정 또는 60000 초과, `ttlSecondsAfterFinished` 미지정 또는 3600 초과 | 각 필드 범위 |
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

## 실험 브랜치 launcher 운영 (#539)

Phase 1에서 이 namespace에 Job을 만드는 주체는 `autoresearch` namespace의 1분 주기
CronJob **launcher** 하나다. API는 Job을 만들지 않고 상태만 조회한다. launcher는 DB
에서 `CREATED` Experiment를 선점해 `RUNNING`으로 바꾸고, 봉인된 좌표
(`experiment_id`, `issue_number`, `issue_branch`, `base_dev_sha`)만 담은 executor Job
을 만든다. executor Pod가 GitHub Git refs API로 exp 브랜치를 만든다.

| 구분 | 값 |
|---|---|
| launcher KSA | `autoresearch/agent-orchestration-launcher` |
| launcher GSA | `autoresearch-dev-orch-launch@<project>.iam.gserviceaccount.com` |
| launcher RBAC | `autoresearch-experiments`의 `experiment-job-launcher` (Jobs `create/get/list`) |
| executor KSA | `autoresearch-experiments/experiment-job` (Kubernetes RBAC 없음) |
| Job 이름 | `ar-branch-<experiment UUID hex>` |
| 동시 실행 상한 | `ORCH_MAX_CONCURRENT_EXPERIMENTS=2` (namespace quota와 같은 값) |

### Phase 1 release provenance (#551)

launcher·executor·API는 애플리케이션 PR `SKYAHO/Autoresearch#547`의 squash merge
SHA `e81d7f7cafa8c2834f75bd36f9cebacebee4e5e6`을 source로 한 release run
`SKYAHO/Autoresearch/actions/runs/31069140098`에서 게시했다. mutable tag는 사용하지
않으며 배포와 롤백은 아래 digest 전체 참조를 사용한다.

| 역할 | immutable image |
|---|---|
| launcher | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher@sha256:44ca561e7cd8f6df7b00c6a6d7c1d7ee971107d3e3234e5eb02086c90ca57cc7` |
| executor | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:fe0002e097ac750c90a083519cc6ac86420e84a44c1aa7aa6c7d0ff9120b707c` |
| API | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-api@sha256:36507859b830032aedaa7a6fbf1b77e69466ceec7b56af084dc694e21c51ecde` |

### Phase 2 실패 관측 release provenance (#579)

launcher·executor는 애플리케이션 PR `SKYAHO/Autoresearch#583`의 squash merge SHA
`7f908a571938c910a3549e103df5f3e903708d32`를 source로 한 release run
`SKYAHO/Autoresearch/actions/runs/31158995427`에서 게시했다.

| 역할 | 이번 승격 digest | 직전 rollback digest |
|---|---|---|
| launcher | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher@sha256:b6fde46c1bb20daea28665d060005486580f3862eb837896423a2d90712e39c1` | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher@sha256:4aa7fba653c32a408b77b833dcc11963c5543becf03e3d7608d9095c466f5a2e` |
| executor | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:fb785a28cffab21dac4817d0b6cffaf0c2cd4026e54a3fabc6d19cff4439a347` | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:00664bc9f0b711fcf7a161e76a02d7c5bc482803ae0faf93d7b81d1568ca9dd9` |

### Phase 2 구현 지시 release provenance (#585)

executor는 애플리케이션 PR `SKYAHO/Autoresearch#587`의 squash merge SHA
`6fef4715e145a3d11f0074fff574a41e1ba7d01c`를 source로 한 release run
`SKYAHO/Autoresearch/actions/runs/31162026581`에서 게시했다. launcher와 TTL은
바꾸지 않고 executor digest만 승격한다.

| 역할 | 이번 승격 digest | 직전 rollback digest |
|---|---|---|
| executor | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:b92f0e6f7b4128686208900baf7dcf0c9b65945b60538bb9f4463a4b916a588f` | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:fb785a28cffab21dac4817d0b6cffaf0c2cd4026e54a3fabc6d19cff4439a347` |

### Phase 2 raw GitHub Issue 실행 release provenance (#582)

launcher·executor는 애플리케이션 PR `SKYAHO/Autoresearch#594`의 merge SHA
`2d0c942d6f926f8f1a38357b2dc6d1ea6da9787a`를 source로 한 release run
`SKYAHO/Autoresearch/actions/runs/31176094314`에서 게시했다. 두 image는 같은
source를 사용하며 raw GitHub Issue를 Codex 입력으로 넘기는 실행 계약을 함께
구현한다.

| 역할 | 이번 승격 digest | 직전 rollback digest |
|---|---|---|
| launcher | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher@sha256:2818f29a658b36c14199bd7e2d195e56921cf876217b6504af3fbc5634627837` | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher@sha256:b6fde46c1bb20daea28665d060005486580f3862eb837896423a2d90712e39c1` |
| executor | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:7999677d238f29202fa5720700e86943937bb3d0536cdb3269231c01a14c2475` | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:fb785a28cffab21dac4817d0b6cffaf0c2cd4026e54a3fabc6d19cff4439a347` |

rollback은 launcher CronJob을 먼저 suspend한 뒤 위 표의 launcher·executor
`직전 rollback digest`를 **한 쌍으로** 되돌린다. 한쪽 digest만 되돌리지 않는다.

### Phase 2 학습 배선 v0.9.0 release provenance (#605/#606)

애플리케이션 [PR #606](https://github.com/SKYAHO/Autoresearch/pull/606)의 merge SHA
`53e273c3858e28d70df346e75f9d8b27b7ab6b4d`를 source로 한
[v0.9.0 release](https://github.com/SKYAHO/Autoresearch/releases/tag/v0.9.0)의
학습 배선과 API image를 dev Agent Orchestration manifest에 반영한다. launcher와
executor는 학습 경로가 들어간 v0.9.0 digest를 사용하고, API도 같은 release의 digest로
승격한다. UI와 runner application image는 현재 digest를 유지한다.

| 역할 | v0.9.0 적용 digest | 이 변경의 직전 rollback digest |
|---|---|---|
| launcher | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher@sha256:24bf725cab23ff2b1e54086a5366538f23aea408aae7f6e12073e19454e6b04e` | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher@sha256:2818f29a658b36c14199bd7e2d195e56921cf876217b6504af3fbc5634627837` |
| executor | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:a3ee4aff0266ee2781608b2172c78f9def70ff7aa73c657df97c361566075808` | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:7999677d238f29202fa5720700e86943937bb3d0536cdb3269231c01a14c2475` |
| API | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-api@sha256:4d7d156cd08d1e5ebfa0c0283026d72ea7504dfaa40aa837edc917627b107c24` | `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-api@sha256:e8886396c00a6c919cb28d49c7ad4de836b0de07a685da5db7a166384e72f066` |

launcher는 아래 값을 literal env로 executor Job에 전달한다. URI가 비어 있으면 학습이
꺼지고 기존 경로만 실행되므로, URI와 함께 v0.9.0이 필수로 읽는 세 timeout을 항상
공급한다. `ORCH_TRAINING_DATASET_PATH`는 사용하지 않으며 정적 contract가 재유입을
거부한다.

| 이름 | 값 |
|---|---|
| `ORCH_TRAINING_DATASET_URI` | `gs://autoresearch-503903-autoresearch-dev-experiment-results/training-snapshots/by-hash/d3d273e66324042cd8e547068c194231cf1812d53cb68236edba56b067055293/` |
| `ORCH_TRAINING_TIMEOUT_SEC` | `1800` |
| `ORCH_TRAINING_DOWNLOAD_TIMEOUT_SEC` | `600` |
| `ORCH_UV_SYNC_TIMEOUT_SEC` | `900` |

이 release는 이전 변경으로 부여한 `experiment-job` GSA의 결과 버킷
`roles/storage.objectViewer`와 현재 executor 자원 제한을 전제로 하며, IAM·GCP
resource·resource request/limit·CronJob `suspend`는 바꾸지 않는다. ArgoCD sync가
완료된 뒤 현재 의도적으로 정지한 launcher의 `suspend=false` 복귀와 새 Experiment
발행, `candidate_sha`·ROC-AUC 검증은 애플리케이션 담당자가 수행한다.

적용 후에는 다음 값이 live CronJob에 반영됐는지 확인한다.

```bash
kubectl -n autoresearch get cronjob agent-orchestration-launcher \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n autoresearch get cronjob agent-orchestration-launcher \
  -o jsonpath='{range .spec.jobTemplate.spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
  | grep -E '^(ORCH_EXECUTOR_IMAGE|ORCH_TRAINING_|ORCH_EXPERIMENT_RESULTS_ROOT|ORCH_ACTIVE_DEADLINE_SEC|ORCH_CODEX_TIMEOUT_SEC)'
kubectl -n autoresearch get deployment agent-orchestration-api \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="api")].image}{"\n"}'
kubectl -n autoresearch get job agent-orchestration-api-migration \
  agent-orchestration-deployment-verification --ignore-not-found \
  -o jsonpath='{range .items[*].spec.template.spec.containers[*]}{.image}{"\n"}{end}'
```

### Stage 1 결과 게시와 실행 시간 (#604)

Stage 1 executor는 아래 세 literal env를 launcher에서 전달받아 측정 결과를
`experiments/{issue_number}/{experiment_id}/` 아래에 게시한다. 결과 버킷의 기존
`roles/storage.objectCreator`와 executor의 `if_generation_match=0` precondition이
기존 live 객체 교체를 막으므로 같은 experiment prefix를 재사용하지 않는다. 이 작업은
새 IAM·project-level binding·NetworkPolicy를 추가하지 않는다.

| 이름 | 값 |
|---|---|
| `ORCH_EXPERIMENT_RESULTS_ROOT` | `gs://autoresearch-503903-autoresearch-dev-experiment-results` |
| `ORCH_ACTIVE_DEADLINE_SEC` | `60000` |
| `ORCH_CODEX_TIMEOUT_SEC` | `6000` |

시간 변수의 적용 단위는 서로 다르다. `ORCH_ACTIVE_DEADLINE_SEC`는 8-container
executor Job 전체의 상한이다. `ORCH_CODEX_TIMEOUT_SEC`는 `codex-worker` 한 container가
실행하는 단일 `codex exec` subprocess의 상한이며 8개 container 각각에 복사되지 않는다.
`ORCH_TRAINING_TIMEOUT_SEC=1800`은 baseline/candidate 각 조건의 seed 하나
`train-model` 실행과 측정 단계의 seed 하나 `evaluate-model` 실행에 각각 적용된다.
다운로드 timeout `600`은 baseline snapshot 1회(이후 같은 Pod에서 재사용), `uv sync`
timeout `900`은 candidate 의존성 변경 시 1회다. 따라서 6000은 8-container 수에서
계산한 값이 아니라 애플리케이션 spec이 정한 단일 Codex 호출 운영 상한이다.

#### 적용 순서: admin admission을 먼저, ArgoCD manifest를 나중에

`terraform/admin/autoresearch-k8s`는 ArgoCD가 관리하지 않는 별도 Terraform state이고,
`agent-orchestration` ArgoCD Application은 `main` 변경을 자동 sync한다. 따라서 이
변경에서는 **launcher를 멈춘 상태에서 admission 계약을 먼저 올린 뒤 manifest를
sync해야 한다.** `launcher-cronjob.yaml`에는 `spec.suspend`를 정본으로 넣지 않았으므로,
아래 suspend는 일시적인 live 운영 게이트다. 이 순서를 지키지 않고 새 env가 먼저
반영되면 live VAP의 3600초 상한이 60000초 Job을 `FailedCreate`로 거부한다.

1. #604를 merge하기 **전에** launcher CronJob을 suspend하고 값이 `true`인지 확인한다.
   이 단계에서 권한이나 값 확인이 실패하면 merge/sync를 진행하지 않는다.

   ```bash
   kubectl -n autoresearch patch cronjob agent-orchestration-launcher \
     --type=merge -p '{"spec":{"suspend":true}}'
   kubectl -n autoresearch get cronjob agent-orchestration-launcher \
     -o jsonpath='{.spec.suspend}{"\n"}'
   ```

2. PR merge 뒤 `apply` workflow를 `scope=admin`으로 dispatch한다. 승인된 plan에서
   `autoresearch-experiment-job-contract`의 active deadline validation 변경을 확인한
   뒤 admin apply를 완료한다. 이 PR만으로는 Terraform apply를 수행하지 않는다.

3. live VAP가 `activeDeadlineSeconds <= 60000`을 허용하고 TTL 상한은 계속
   `ttlSecondsAfterFinished <= 3600`인지 확인한다. `activeDeadlineSeconds <= 3600`이
   남아 있으면 다음 단계로 진행하지 않는다.

   ```bash
   kubectl get validatingadmissionpolicy autoresearch-experiment-job-contract -o yaml \
     | grep -A2 -E 'activeDeadlineSeconds|ttlSecondsAfterFinished'
   ```

4. ArgoCD가 `main` revision을 sync할 때까지 기다린다. Application이 `Synced`/적용
   성공인지 확인하고, 그 뒤 live CronJob에서 세 env가 모두 새 값인지 확인한다.

   ```bash
   kubectl -n argocd get application agent-orchestration \
     -o jsonpath='{.status.sync.status}{" "}{.status.sync.revision}{" "}{.status.operationState.phase}{"\n"}'
   kubectl -n autoresearch get cronjob agent-orchestration-launcher \
     -o jsonpath='{range .spec.jobTemplate.spec.template.spec.containers[?(@.name=="launcher")].env[*]}{.name}={.value}{"\n"}{end}' \
     | grep -E '^(ORCH_EXPERIMENT_RESULTS_ROOT|ORCH_ACTIVE_DEADLINE_SEC|ORCH_CODEX_TIMEOUT_SEC)='
   ```

5. VAP와 CronJob env를 다시 확인한 뒤에만 live suspend를 해제하고 실험 한 건을
   발행한다. ArgoCD desired manifest에는 suspend 필드가 없으므로, sync가 끝나기
   전에 `false`로 바꾸지 않는다. sync 후에도 `true`가 유지되는지 확인하고, 이후
   해제 결과가 `false`인지 확인한다.

이 순서 중 어느 단계에서든 새 executor Job이 `FailedCreate`가 되면 즉시 launcher를
다시 suspend하고, 실패 Job의 admission Event를 보존한 채 2~4단계를 완료한다. 이미
생성된 실패 Job은 자동 재시도하지 않으며, 원인을 확인하기 전 삭제하지 않는다.

#### 장시간 Job 관측과 회수

`launcher` suspend는 새 제출만 막고 이미 생성된 executor Job을 멈추지 않는다. 일반
`experiment-job` KSA와 launcher/API KSA에는 Job delete 권한이 없으므로, 무한 대기나
노드 장애를 정상 운영 권한으로 즉시 회수하는 경로는 없다. 자동 회수는
`activeDeadlineSeconds` 만료(최대 16시간 40분)와 TTL controller뿐이다. 그 전에
다음 신호를 주기적으로 확인한다.

```bash
kubectl -n autoresearch-experiments get jobs \
  -l app.kubernetes.io/component=experiment-executor \
  -o custom-columns='NAME:.metadata.name,ACTIVE:.status.active,SUCCEEDED:.status.succeeded,FAILED:.status.failed,START:.status.startTime,COND:.status.conditions[0].type'
kubectl -n autoresearch-experiments get pods \
  -l app.kubernetes.io/component=experiment-executor \
  -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount'
kubectl -n autoresearch-experiments get events --sort-by=.lastTimestamp | tail -n 40
kubectl -n autoresearch-experiments logs job/<executor-job> -c workspace-preparer --since=15m
kubectl -n autoresearch-experiments logs job/<executor-job> -c codex-worker --since=15m
kubectl -n autoresearch-experiments logs job/<executor-job> -c candidate-finalizer --since=15m
```

stage 시작·종료, `training_timeout`, `evaluation_timeout`, `codex_timeout`, GCS
`publish_failed`, API 보고 사유는 container 로그에 남는다. Pod metrics가 설치된 경우에는
`kubectl top pod`로 CPU/memory 포화도 함께 본다. 현재 이 변경은 별도 heartbeat/알림을
추가하지 않으므로, 위 신호가 진행 정지나 `FailedCreate`를 보이면 즉시 launcher를
suspend하고 로그·Event·결과 URI를 보존한다.

`batch-od`는 최대 2개 노드이고 namespace `count/jobs.batch=2`와 함께 실험 두 건이
동시에 최대 16시간 40분 동안 두 슬롯을 점유할 수 있다. 현재 확인된 Airflow KPO는
`batch-spot` 기본값이라 이 변경 시점에는 같은 pool 경쟁자가 없지만, 이후 workload가
`batch-od`로 이동하면 이 장시간 점유·비용·대기 상한을 다시 계산해야 한다. 정상 권한으로
회수할 수 없는 stuck Job은 break-glass cluster 관리자만 결과·Event를 보존한 뒤 명시적으로
삭제할 수 있다.

```bash
gcloud storage ls \
  gs://autoresearch-503903-autoresearch-dev-experiment-results/experiments/<issue_number>/<experiment_id>/metrics.json
```

`metrics.json`이 없으면 executor 로그의 `results_root_unset`, GCS 권한 오류와 실제
executor Job env를 조사한다. 같은 `base_dev_sha`의 두 실행에서는 baseline seed별 값이
일치하는지, 워크벤치의 `metric_summary`가 null이 아닌지도 함께 확인한다.

학습 배선 또는 이미지 문제가 생기면 launcher를 먼저 suspend하고, 위 표의 launcher와
executor digest를 **한 쌍으로** 직전 값으로 되돌리면서 네 학습 env를 함께 제거한다.
API v0.9.0 문제가 생기면 같은 순서로 API image 7개 참조를 위 표의 직전 digest로
함께 되돌린다. snapshot bucket viewer IAM은 롤백하지 않는다.

**launcher CronJob의 DB bootstrap initContainer는 launcher image가 아니라 API
image를 쓴다.** `agent_orchestration/bootstrap_secrets.py`는 애플리케이션 저장소
최상위 모듈인데 `launcher.Dockerfile`이 이를 COPY하지 않아 launcher image에 없다.
launcher image로 실행하면 initContainer가 `ModuleNotFoundError`로 죽고
`backoffLimit: 0`이라 1분마다 실패 Job만 쌓인다(`api-migration-job.yaml`이 쓰는 것과
같은 패턴이다). launcher image가 자체 bootstrap을 갖게 하려면 Dockerfile에 해당
모듈을 추가하는 애플리케이션 변경이 선행돼야 한다.

manifest가 어떤 image로 어떤 모듈을 실행하는지는 `--dry-run=server`나 digest 조회로
검증되지 않는다. 둘 다 image **안**을 열어보지 않기 때문이다. digest를 바꾸거나
컨테이너의 `command`를 바꿀 때는 아래처럼 실제 image에서 import를 확인한다.

```bash
kubectl -n autoresearch run bootstrap-probe --rm -it --restart=Never \
  --image=<해당 digest> --command -- \
  python -c "import agent_orchestration.bootstrap_secrets; print('OK')"
```

release workflow가 세 image의 OCI revision·비루트 실행·import를 검증했고, API
digest를 직접 실행한 `alembic -c agent_orchestration/alembic.ini heads` 결과는
`0004_experiment_branch_bootstrap (head)`다. 이전 API digest
`sha256:0471c6ea3f7e73c0bbe5e077088432a701ed26eb5f32b4f72dc7425c95ddb197`가
rollback 좌표다. launcher CronJob을 먼저 suspend한 뒤 세 참조를 함께 되돌린다.

이 Phase는 Job 완료·실패를 DB status로 회수하지 않는다. Job이 `Complete`가 되어도
Experiment는 `RUNNING`에 남는다. 이는 의도된 경계이며 reconciler는 후속 이슈다.

### branch-writer GitHub App 자격 증명 등록

executor는 branch-writer GitHub App(`SKYAHO/Autoresearch` 한 저장소, `Contents:
Read and write` **하나만**)으로 브랜치를 만든다. API가 쓰는 baseline-reader
App(`Contents: Read-only`, [GKE runbook](2026-07-30-agent-orchestration-gke.md))과
**다른 App**이다. 두 App을 합치면 SHA를 읽기만 하는 경로가 쓰기 권한을 갖는다.

private key는 Terraform·Git·manifest 어디에도 넣지 않는다. Secret은 **두 namespace에
각각** 필요하며 담는 key가 다르다.

| namespace | Secret 이름 | key | 쓰임 |
|---|---|---|---|
| `autoresearch-experiments` | `autoresearch-experiment-branch-writer-app` | `private-key.pem` | executor Job의 initContainer가 volume으로 mount |
| `autoresearch` | `autoresearch-experiment-branch-writer-app` | `app-id`, `installation-id` | launcher CronJob이 env로 읽어 Job manifest에 리터럴로 넣음 |

private key가 `autoresearch` namespace에 필요 없고 두 ID가 실험 namespace에 필요
없는 이유는 경로가 다르기 때문이다 — 키는 executor Pod의 initContainer까지만 가고,
두 ID는 launcher가 Job manifest를 조립할 때 필요하다. **실험 namespace의 Secret에는
`private-key.pem` 외의 key를 넣지 않는다.**

`set -eu`가 없으면 `cp`가 실패해도 다음 명령이 그대로 진행된다. 그 경로에서는
private key Secret만 빠진 채 두 ID Secret이 만들어지고, 마지막 `shred -u`가 원본
`.pem`을 지워 **복구 불가능한 반쪽 상태**가 된다. 실제로 #562 작업 중 같은 형태의
사고가 났다.

```bash
set -eu
umask 077
sdir="$(mktemp -d)"
trap 'rm -rf "$sdir"' EXIT

printf '%s' '<App ID>'          > "$sdir/app-id"
printf '%s' '<installation ID>' > "$sdir/installation-id"
cp /path/to/branch-writer.pem     "$sdir/private-key.pem"
[ -s "$sdir/private-key.pem" ]  # 비어 있으면 여기서 멈춘다

kubectl -n autoresearch-experiments create secret generic \
  autoresearch-experiment-branch-writer-app \
  --from-file=private-key.pem="$sdir/private-key.pem" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n autoresearch create secret generic \
  autoresearch-experiment-branch-writer-app \
  --from-file=app-id="$sdir/app-id" \
  --from-file=installation-id="$sdir/installation-id" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -rf "$sdir"; trap - EXIT
# 원본을 다른 곳에 보관하지 않았다면 이 줄은 실행하지 않는다. App private key는
# GitHub에서 재발급만 가능하고 기존 키를 되살릴 수 없다.
shred -u /path/to/branch-writer.pem
```

Secret 이름은 admission 정책이 서버 측에서 검사한다
(`experiment_branch_writer_secret_name`). 이름을 바꾸면 Terraform 변수와 함께
바꿔야 하며, 어긋나면 **모든 Job이 거부된다.**

### Phase 2 executor Secret 등록 (#562)

Phase 2는 위 branch-writer Secret 외에 두 개를 더 요구한다. 둘 다 실험 namespace에
두고, 값은 Terraform·Git·manifest 어디에도 넣지 않는다.

| Secret 이름 | key | mount하는 컨테이너 | 쓰임 |
|---|---|---|---|
| `autoresearch-experiment-codex-auth` | `auth.json` | `codex-worker` **만** | Codex 인증 |
| `autoresearch-experiment-executor-api-token` | `token` | `candidate-finalizer` **만** | candidate SHA 보고 |

Codex 인증은 PVC가 아니라 Secret이다. `standard-rwo` PVC는 단일 노드 attach라 여러
Pod의 동시 시작을 막을 수 있고, 작은 read-only `auth.json`에는 각 Pod가 독립으로
mount하는 Secret이 맞다(애플리케이션 `#566`).

**`auth.json` 외의 key를 넣지 않는다.** 어드미션 계약이 volume의 `items`를
`auth.json` 하나로 고정하지만, Secret 자체에 다른 key가 있으면 이후 계약 변경 시
그것까지 노출될 여지가 생긴다.

Codex 인증 파일은 보통 `~/.codex/auth.json`이다. **그 경로를 그대로 쓸 때는
`shred`를 실행하지 않는다** — 지우면 로컬 Codex 로그인이 깨진다. 별도 머신에서
복사해온 임시 파일일 때만 마지막 줄을 쓴다.

```bash
set -eu
umask 077
sdir="$(mktemp -d)"
trap 'rm -rf "$sdir"' EXIT

cp ~/.codex/auth.json "$sdir/auth.json"
[ -s "$sdir/auth.json" ]                    # 비어 있으면 여기서 멈춘다
python3 -c 'import json;json.load(open("'"$sdir"'/auth.json"))'  # JSON 형식 확인
printf '%s' '<executor API token>' > "$sdir/token"

kubectl -n autoresearch-experiments create secret generic \
  autoresearch-experiment-codex-auth \
  --from-file=auth.json="$sdir/auth.json" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n autoresearch-experiments create secret generic \
  autoresearch-experiment-executor-api-token \
  --from-file=token="$sdir/token" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -rf "$sdir"; trap - EXIT
# 임시로 복사해온 파일일 때만:
# shred -u /path/to/copied-auth.json
```

등록 뒤에는 값이 아니라 **key 이름만** 확인한다.

```bash
for s in autoresearch-experiment-codex-auth autoresearch-experiment-executor-api-token; do
  printf '%-45s ' "$s"
  kubectl -n autoresearch-experiments get secret "$s" \
    -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}{{"\n"}}'
done
# 기대: codex-auth → auth.json / executor-api-token → token
```

`auth.json` 외의 key가 들어가면 안 된다. 어드미션 계약이 volume의 `items`를
`auth.json` 하나로 고정하지만, Secret 자체를 깨끗하게 두는 편이 이후 계약 변경에
안전하다.

두 이름은 admission 정책(`experiment_codex_home_secret_name`,
`experiment_executor_api_token_secret_name`)과 launcher manifest의
`ORCH_CODEX_HOME_SECRET_NAME`·`ORCH_EXECUTOR_API_TOKEN_SECRET_NAME` 양쪽이 같은
값을 갖는다. 셋 중 하나만 바꾸면 **모든 executor Job이 거부된다.**

#### executor API token의 API namespace 사본 (#575)

candidate 보고 인증은 **양쪽이 같은 token을 가져야** 성립한다.

| 주체 | namespace | 읽는 방식 |
|---|---|---|
| 발신 `candidate-finalizer` | `autoresearch-experiments` | volume mount → `/var/run/executor-api-token/token` |
| 수신 API Pod | `autoresearch` | env `ORCH_EXECUTOR_API_TOKEN` (단일 key `secretKeyRef`) |

Kubernetes Secret은 namespace-scoped라 한 객체를 두 Pod가 공유할 수 없다. **같은
payload를 가진 Secret이 두 namespace에 각각 하나씩** 있어야 한다.

새 API image는 이 값을 필수로 읽는다. 없으면 Pod가 startup에서
`ValueError: Required environment variable 'ORCH_EXECUTOR_API_TOKEN' is not set.`
로 죽고 `CrashLoopBackOff`에 머문다. 이때 Service는 **직전 이미지의 Pod를 Ready로
유지**하므로 배포가 성공한 것처럼 보인다 — candidate endpoint만 조용히 없다.

이미 executor namespace에 등록돼 있다면, 값을 화면에 띄우지 않고 그대로 복제한다.

```bash
set -eu
umask 077

kubectl -n autoresearch-experiments get secret \
  autoresearch-experiment-executor-api-token \
  -o jsonpath='{.data.token}' \
| base64 -d \
| kubectl -n autoresearch create secret generic \
    autoresearch-experiment-executor-api-token \
    --from-file=token=/dev/stdin \
    --dry-run=client -o yaml \
| kubectl apply -f -
```

파이프로만 흘려보내므로 token이 셸 히스토리·터미널·파일에 남지 않는다.

#### 토큰 값 요건

애플리케이션이 startup에서 세 조건을 강제한다(`app/config.py`). 어기면 API가
`ValueError`로 죽는다.

| 조건 | 위반 시 |
|---|---|
| **32자 이상** | `must be at least 32 characters long` |
| `ORCH_API_TOKEN`과 다를 것 | `must differ` |
| `ORCH_RUNNER_TOKEN`과 다를 것 | `must differ` |

32자는 **디코딩된 값** 기준이다. `-o go-template`의 `{{len $v}}`는 base64
인코딩 길이를 세므로 그 값으로 판단하면 안 된다(#575에서 실제로 오독해, 20자
토큰을 28자로 착각하고 요건 충족으로 넘어갔다).

새로 만들 때는 여유 있게 48자를 쓴다.

```bash
bash -c '
set -eu
umask 077
t=$(openssl rand -base64 64 | tr -d "\n=+/" | cut -c1-48)
[ ${#t} -ge 32 ] || { echo "토큰 길이 부족"; exit 1; }
for ns in autoresearch autoresearch-experiments; do
  printf %s "$t" | kubectl -n "$ns" create secret generic \
    autoresearch-experiment-executor-api-token \
    --from-file=token=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -
done
unset t
'
```

값을 변수에만 담고 파일·화면에 남기지 않는다.

#### 등록 확인

확인은 key 이름과 **디코딩 길이**까지만 한다. **값이나 hash를 출력해 동일성을
증명하지 않는다** — 로그·PR에 남으면 그 자체가 유출이다.

```bash
for ns in autoresearch autoresearch-experiments; do
  printf '%-28s decoded=' "$ns"
  kubectl -n "$ns" get secret autoresearch-experiment-executor-api-token \
    -o jsonpath='{.data.token}' | base64 -d | wc -c
done
# 기대: 양쪽 모두 같은 값이며 32 이상
```

길이가 같아도 값이 같다는 증명은 아니다. 실제 일치는 **새 API가 Ready가 되고
candidate smoke가 401 없이 통과하는 것**으로만 확인된다.

두 사본이 어긋나면 candidate 보고가 401로 실패한다. **회전은 실행 중 Experiment가
없는 시점에** 양쪽을 함께 갱신하고 API를 재시작한다.

#### 롤아웃 순서

**Secret을 먼저 만들고 그 다음 launcher를 배포한다.** 순서가 뒤집히면 kubelet이
volume mount를 완료하지 못해 Pod가 `Pending`에 머물고, Job은
`activeDeadlineSeconds`(60000초) 뒤에야 `Failed`가 된다. 즉 실패를 최대 16시간 40분 뒤에 알게
된다. 판별 근거는 Pod event의 `FailedMount`와 Job의 `DeadlineExceeded`다.

```bash
kubectl -n autoresearch-experiments get events --sort-by=.lastTimestamp | grep FailedMount
```

`subPath` mount는 실행 중 Secret 갱신을 전파하지 않으므로, Secret을 교체해도 이미
도는 Job에는 적용되지 않는다. 새 Experiment부터 반영된다.

### 운영 smoke 배포 게이트 (#562 / #575)

아래 네 조건이 모두 충족되기 **전에는 Experiment를 등록하지 않는다.** 어느 하나가
빠져도 실패가 곧바로 드러나지 않고, 최대 60000초 뒤 `DeadlineExceeded`나 401로만 나타나
원인 판별이 어려워진다.

| # | 게이트 | 확인 |
|---|---|---|
| 1 | 두 namespace에 executor token Secret | 위 절차의 key·길이 대조 |
| 2 | API Deployment의 `ORCH_EXECUTOR_API_TOKEN` `secretKeyRef` | manifest 계약 검사(CI) |
| 3 | 새 API Pod rollout 완료·Ready | 아래 명령 |
| 4 | candidate endpoint 노출 | 아래 명령 |

```bash
# 3 — 새 digest의 Pod만 Ready여야 한다. 옛 digest Pod가 Ready로 남아 있으면
#     새 Pod가 startup에서 죽고 Service가 옛 Pod로 버티는 상태다.
kubectl -n autoresearch get pods -l app.kubernetes.io/name=agent-orchestration-api \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[0].ready,\
RESTARTS:.status.containerStatuses[0].restartCount,IMAGE:.spec.containers[0].image'

# 4 — Service를 거쳐 OpenAPI에 candidate endpoint가 있는지
kubectl -n autoresearch run openapi-probe --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  -s http://agent-orchestration-api.autoresearch.svc.cluster.local:8000/openapi.json \
| grep -o '/internal/executor/experiments/{experiment_id}/candidate' || echo '❌ candidate endpoint 없음'
```

3번이 특히 중요하다. 새 Pod가 죽어도 **Service는 직전 이미지 Pod를 Ready로 유지**해
배포가 성공한 것처럼 보인다. `READY=false`인 Pod가 재시작을 쌓고 있는지 반드시
본다.

### ArgoCD PostSync 자동 배포 검증 (#574)

infra `main` merge 뒤 ArgoCD는 `agent-orchestration-deployment-verification` Job을
PostSync hook으로 실행한다. 이 Job은 같은 namespace의 API Service OpenAPI에서
candidate 보고 endpoint를 확인한다. GitHub Actions runner에 cluster 권한을 주지
않으며, Job도 Secret·Kubernetes API token을 갖지 않는다.

Job 내부 probe는 candidate endpoint가 확인되면 `SystemExit(0)`으로 성공하고,
`Exception`이 아닌 `BaseException` 계열이므로 retry `except Exception`에 잡히지 않는다.
endpoint가 deadline까지 없으면 문자열을 가진 `SystemExit`로 exit code 1을 반환한다.

`backoffLimit=1`은 image pull·node eviction 같은 Pod 단위의 일시 실패를 한 번
흡수한다. 반면 `activeDeadlineSeconds=300`은 Job 전체 상한이라 deadline을 넘으면
남은 retry와 무관하게 `DeadlineExceeded`로 실패한다. 이때 종료된 Pod log가 없을 수
있으므로 Job condition과 Pod event를 함께 확인한다.

Job이 실패하면 ArgoCD sync operation이 실패한다. Application에는 `retry`와
`selfHeal`이 없으므로 같은 Git revision의 실패를 automated sync가 계속 재시도하지
않는다. 새 revision 또는 운영자의 수동 sync가 다음 PostSync를 시작할 때
`BeforeHookCreation`이 직전 실패 Job을 삭제한다. manifest를 revert로 제거해도
`prune=false`이므로 기존 실패 Job은 삭제되지 않는다. 기존 `KubeJobFailed` 경보와
함께 다음을 확인한다.

```bash
kubectl -n autoresearch get job agent-orchestration-deployment-verification
kubectl -n autoresearch logs job/agent-orchestration-deployment-verification
kubectl -n autoresearch get pods -l app.kubernetes.io/component=deployment-verifier
kubectl -n autoresearch get events --sort-by=.lastTimestamp | tail -n 30
kubectl -n argocd get application agent-orchestration \
  -o jsonpath='{.status.operationState.phase}{" "}{.status.operationState.message}{"\\n"}'
```

candidate endpoint가 없는 이전 API digest로 긴급 롤백하면 Deployment는 먼저 그
digest로 실제 적용되지만, 뒤이은 verifier가 실패해 ArgoCD operation은 실패로
기록된다. ArgoCD는 이를 이전 digest로 자동 rollback하지 않는다. 따라서 이 경우
`deployment-verification-job.yaml`과 `agent-orchestration-deployment-verifier`
NetworkPolicy, API ingress의 `deployment-verifier` 규칙을 같은 revert PR에서 함께
제거하는 것은 선택 사항이 아니라 롤백 완료 조건이다.

#### 실패 증거 보존 TTL (#579)

Autoresearch #582 실패 관측 image를 승격하는 단일 smoke에서는 launcher에
`ORCH_TTL_AFTER_FINISHED_SEC=3600`을 주입한다. 이 값은 launcher가 새 executor Job의
`ttlSecondsAfterFinished`에 복사하며, 완료된 Job·Pod event와 container 로그를 조사할
시간을 확보한다. 권한·egress·active deadline은 바꾸지 않는다.

1. launcher CronJob을 suspend한 상태에서 새 launcher/executor digest와 TTL 3600
   manifest를 적용한다.
2. rollout과 설정을 확인한 뒤 suspend를 해제하고 새 Experiment 하나만 발행한다.
3. 평가 중 (`EVALUATING`) 완주 또는 정제된 `stage`·`error_type`·`reason` 실패 로그와
   보존된 Job event를 수집한다.
4. 완주 증거를 수집하면 manifest의 TTL을 `30`으로 되돌린다. 이때
   `scripts/check-experiment-launcher-manifest-contract.rb`의 기대 리터럴과
   `scripts/test-check-experiment-launcher-manifest-contract.rb`의 음성 self-test도
   같은 PR에서 함께 되돌려야 `lint` required check가 통과한다.
5. 회수 PR을 병합하고 TTL 30 manifest를 다시 적용한 뒤 live CronJob 값을 확인한다.

TTL 3600을 상시값으로 남기면 완료 Job이 최대 한 시간 누적되므로 smoke 종료 후 회수를
완료 조건으로 취급한다. 로그가 Kubernetes API 또는 목적지 egress 차단을 구체적으로
증명할 때만 별도 최소 권한 변경을 검토한다.

### Phase 1 ↔ Phase 2 전환과 롤백 (#562)

애플리케이션 `launcher/main.py`에는 **Phase 1/2를 고르는 스위치가 없다.**
`ensure_executor_job`만 호출하므로 launcher image digest를 올리는 순간 전량
Phase 2로 전환되고, 점진 배포 경로가 없다.

따라서 롤백은 **launcher image digest를 위 provenance 표의 직전 rollback digest로
되돌리고 manifest를 다시 적용하는 것**이다. 그때 생성되는 Job은 다시
`branch-bootstrap` 형태이며, 어드미션
계약에 그 종류가 보존돼 있어 그대로 통과한다. **`branch-bootstrap` 계약을 정리
대상으로 보고 지우면 롤백 경로가 막힌다.**

| 대상 | 롤백 절차 |
|---|---|
| launcher 전환 | launcher와 executor image digest를 위 provenance 표의 직전 rollback digest로 되돌리고 manifest 재적용 |
| 어드미션 계약 | Terraform revert 후 apply. Phase 1 계약이 보존돼 있어 되돌린 launcher가 통과한다 |
| NetworkPolicy | `experiment-jobs-executor-egress`만 삭제. Phase 1 정책은 손대지 않았다 |
| executor namespace Secret 2종 | launcher를 **먼저** 되돌린 뒤 삭제한다. 반대로 하면 진행 중인 Job이 `FailedMount`로 매달린다 |
| API namespace token 사본 (#575) | API Deployment를 token 비필수 직전 digest로 되돌려 Ready를 확인한 뒤 env 참조와 Secret을 제거한다. 진행 중인 Phase 2 Job이 있으면 그 종료 결과를 먼저 확정한다 |

어드미션 계약 변경은 `failurePolicy: Fail` + `Deny`라 잘못되면 실험 Job이 **전부**
거부된다. apply 직후 dry-run으로 회귀를 확인한다.

#### 계약 변경 검증용 dry-run manifest 만들기

`--dry-run=server`는 Job을 API 서버까지 보내 어드미션 판정만 받고 저장하지 않는다.
Pod가 생성되지 않으므로 private key·네트워크·Codex가 관여하지 않고, 몇 초 만에
끝난다. 계약을 고칠 때마다 반복해도 비용이 없다.

manifest는 **손으로 쓰지 않는다.** 손으로 쓴 YAML의 실수가 계약 위반으로 오인되기
때문이다. 애플리케이션 저장소의 정본 빌더(`launcher/jobs.py`의
`build_executor_job`·`build_branch_job`)를 그대로 호출해 생성한다.

```bash
# 애플리케이션 저장소를 배포 중인 source SHA로 체크아웃한 뒤
python - <<'PY'
import dataclasses, sys, types, uuid, yaml
from kubernetes.client import ApiClient

# jobs.py가 launcher.repository에서 쓰는 것은 ClaimedExperiment 하나뿐인데
# 그 모듈이 FastAPI·SQLAlchemy까지 끌어오므로 데이터클래스만 stub한다.
stub = types.ModuleType("agent_orchestration.launcher.repository")
@dataclasses.dataclass(frozen=True)
class ClaimedExperiment:
    experiment_id: uuid.UUID; issue_number: int; issue_branch: str
    base_dev_sha: str; issue_body_sha256: str; job_name: str
stub.ClaimedExperiment = ClaimedExperiment
sys.modules["agent_orchestration.launcher.repository"] = stub

from agent_orchestration.launcher.config import LauncherSettings
from agent_orchestration.launcher.jobs import build_executor_job
# settings 값은 deploy/agent-orchestration/launcher-cronjob.yaml의 env와 동일하게 채운다.
PY
```

세 가지를 확인한다. 셋째가 핵심이다.

| manifest | 기대 |
|---|---|
| Phase 1 branch-bootstrap | **통과** — 거부되면 롤백 경로가 막힌 것이므로 즉시 revert |
| Phase 2 executor | **통과** |
| executor의 `codex-worker`에 `github-app-private-key` mount를 붙인 변형 | **거부**, 사유가 "…volume은 … 만 mount할 수 있습니다" |

셋째가 통과하면 자격 증명 allowlist가 동작하지 않는 것이므로 진행을 멈춘다.
컨테이너 개수 규칙에서 먼저 걸려 거부되는 것으로는 부족하다 — 거부 **사유**가
자격 증명 규칙이어야 한다.

### 자격 증명 회수

키 유출이 의심되면 순서대로 수행한다.

1. GitHub App 설정에서 private key를 즉시 폐기한다(revoke). 발급된 installation
   token은 최대 1시간 뒤 만료되며 이 단계로 즉시 무효화되지는 않는다.
2. launcher CronJob을 정지해 새 Job 제출을 막는다.
   `kubectl -n autoresearch patch cronjob agent-orchestration-launcher -p '{"spec":{"suspend":true}}'`
3. 실행 중 executor Job을 확인한다. `activeDeadlineSeconds`(300초)로 자동 종료되며,
   더 빨리 끊어야 하면 break-glass 관리자 권한으로 회수한다 — launcher에는 delete
   권한이 없다.
4. 새 키를 발급해 위 절차로 두 Secret을 갱신한다.
5. 대상 저장소의 최근 ref 생성 이력을 대조해 의도하지 않은 브랜치가 없는지 확인한다.

token은 memory volume(`medium: Memory`)의 파일로만 존재하므로 Pod가 사라지면 함께
사라진다. 노드 디스크나 Kubernetes API에는 남지 않는다.

### branch-bootstrap 계약 negative dry-run

`autoresearch-experiment-job-contract` 정책은 `failurePolicy: Fail`이라, 규칙이
잘못되면 정상 Job까지 조용히 거부된다. apply 후 **반드시** 아래를 실행해 각 규칙이
의도한 사유로 거부하는지 확인한다. 정책은 동시 위반 시 규칙 평가 순서에 따라 하나의
메시지만 반환하므로(#523 실측), 한 번에 한 가지씩 어긴 manifest로 확인한다.

승인된 형태의 Job manifest 하나를 기준으로 두고, 아래 항목을 하나씩 변형해
`kubectl -n autoresearch-experiments create --dry-run=server -f -`로 제출한다.

| 변형 | 기대 거부 사유 |
|---|---|
| initContainer 이름을 다른 값으로 | initContainer는 `github-token-minter` 하나만 |
| initContainer 2개 | 위와 같음 |
| app 컨테이너 이름을 다른 값으로 | 컨테이너는 `branch-bootstrap` 하나만 |
| volume 3개(임의 `emptyDir` 추가) | Secret volume과 token volume 두 개만 |
| Secret volume의 `secretName`을 다른 이름으로 | 위와 같음 |
| token volume에서 `medium: Memory` 제거 | 위와 같음 |
| private key volume을 app 컨테이너에도 mount | private key는 initContainer에만 readOnly |
| private key mount의 `readOnly: false` | 위와 같음 |
| app 컨테이너 token mount의 `readOnly: false` | 본 컨테이너는 token을 readOnly로만 |
| app 컨테이너에 `env[].valueFrom.secretKeyRef` 추가 | 환경 변수로 Secret 주입 불가 |
| app 컨테이너에 `envFrom` 추가 | 위와 같음 |
| Pod template label 제거 | `app.kubernetes.io/component=branch-bootstrap` 필요 |

**마지막으로 승인된 형태 그대로를 제출해 통과하는지 확인한다.** 거부만 확인하고
끝내면 "전부 거부하는 정책"을 정상으로 오인할 수 있다.

### GitHub egress 음성 검증

`experiment-jobs-branch-bootstrap-egress`는 label이 붙은 Pod에만 공개 443을
허용한다. 기본 경계 정책은 그대로 남고 이 정책이 합집합으로 더해진다.

```bash
kubectl -n autoresearch-experiments get networkpolicy \
  experiment-jobs-branch-bootstrap-egress -o jsonpath='{.spec.egress}'
```

`0.0.0.0/0`과 `except`의 6개 대역(`10/8`, `172.16/12`, `192.168/16`, `100.64/10`,
`169.254/16`, `127/8`)이 모두 보여야 한다. 실제 도달성은 smoke Job의 성공으로
확인하고, 음성 대조군이 필요하면 이 정책만 일시 삭제한 뒤 Job이 timeout으로
실패하는지 보고 즉시 원복한다(#535와 같은 방식).

이 정책의 `except`는 이 규칙의 범위만 좁힌다. 기본 경계 정책이 이미 허용한 metadata
server(`169.254.169.254:80`, `169.254.169.252:987/988`)는 그대로 유지된다.

### smoke 검증 항목

apply와 Secret 주입을 마친 뒤 실험 하나로 아래를 모두 확인한다.

```text
DB base_dev_sha == 이슈 발행 전 dev SHA
DB executor_job_name == ar-branch-<experiment UUID hex>
Experiment status == RUNNING (이 Phase에서 자동 전이하지 않음)
Job Pod == initContainer 1 + app container 1
Job status == Complete
exp branch tip == DB base_dev_sha
GitHub Actions branch 생성 workflow run 없음
Pod env·log에 token·private key 없음
```

마지막 항목은 `kubectl -n autoresearch-experiments get pod <name> -o json`의
`spec.containers[].env`와 `kubectl logs`로 확인한다. 설계상 token은 파일로만
전달되고 로그에는 experiment ID·issue number·branch·base SHA와 `created` boolean만
남는다.

## 장애 처리와 롤백

1. 새 Job 제출을 먼저 멈춘다. #539 이후 제출 주체는 launcher이므로 CronJob을
   suspend하는 것이 가장 빠른 차단 수단이다.
   `kubectl -n autoresearch patch cronjob agent-orchestration-launcher -p '{"spec":{"suspend":true}}'`
   그다음 실행 중 Job의 ID·상태·결과 URI를 기록한다. launcher에도 API에도 Job
   delete 권한이 없으므로 사용자 취소는 지원하지 않으며, 실행 중 Job은
   `activeDeadlineSeconds` 종료를 기다린다. suspend는 이미 만들어진 Job을 멈추지
   않는다.
2. 이미지 pull 실패, Pending, OOMKilled, deadline 초과, 애플리케이션 exit code를
   구분해 원인을 조사한다. API는 해당 Job/Pod Event에서 `ImagePullBackOff`,
   `FailedScheduling`, `FailedCreate`를 확인한다. `FailedCreate`는 quota 초과
   외에 `experiment_jobs.tf`의 Pod 합계 `LimitRange`(컨테이너 합계가 1 vCPU/2 GiB를
   넘음) 위반으로도 발생할 수 있다 — 이 경우 Pod 자체가 생성되지 않으므로
   `pods`/`requests.cpu` quota는 소비되지 않는다(#523). 실패한 Job을 자동
   재시도하지 않는다.
3. 권한 또는 Job 명세 취약점이 의심되면 `enable_experiment_job_creation`을 `false`로
   되돌리는 Terraform 변경을 검토하고, 승인된 apply로 반영한다. #539 이후 이 플래그가
   여닫는 주체는 API KSA가 아니라 launcher KSA다. CronJob suspend(1번)가 즉시
   적용되는 반면 이쪽은 승인된 apply가 필요하므로, 순서는 항상 suspend → apply다.
4. 결과 버킷, namespace, KSA, GSA를 삭제하지 않는다. 삭제는 감사·재현·다른 실행의 복구를 훼손할 수 있으므로 별도 변경과 승인 절차가 필요하다.
5. 수정된 템플릿과 digest로 새 시도 ID의 Job을 만든다. 같은 prefix를 재사용하지 않는다.
   단, 완료 Job도 `count/jobs.batch=2` quota를 TTL controller가 삭제할 때까지 점유한다.
   두 개의 완료 Job이 남은 상태에서는 세 번째 create가 `Forbidden` quota 초과로
   거부되며, API는 재시도 가능 상태로 기록해 TTL 정리 후 제출한다. terminal Pod는
   `pods=2` 계산에서 제외될 수 있으므로 운영 병목은 Job 객체 quota다.

`ttlSecondsAfterFinished` 누락 또는 TTL controller 장애로 quota가 회수되지 않으면
새 제출이 quota 초과로 막히고 운영자에게 escalate된다. launcher에도 API에도 delete
권한이 없으므로, 운영자는 결과 URI·Job 상태·감사 메타데이터를 확인한 뒤 break-glass
cluster 관리자 권한으로 명시적으로 회수한다. 이 권한은 launcher KSA·API KSA·실험
KSA 어디에도 부여하지 않는다.
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
admission이 강제하는 `activeDeadlineSeconds`(최대 60000초)로 상한이 있지만, KPO
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
