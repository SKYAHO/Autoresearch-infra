# #5 dev GKE 클러스터 설계 (Design Spec)

- 이슈: [#5 [FEAT] dev GKE 소형 클러스터 Terraform 구성](https://github.com/SKYAHO/Autoresearch-infra/issues/5)
- 분기 전략: **A** — PR #13(#4 Cloud SQL) 머지 후 갱신된 `main`에서 `feat/5-gke` 분기
- 작성일: 2026-07-03
- 상태: 설계 승인됨(사용자), 구현 대기

## 1. 목적

dev 환경에서 Kubernetes 기반 워크로드를 검증할 수 있는 **최소 비용·보안 기본기**를 갖춘 GKE 클러스터를 Terraform으로 구성한다.

## 2. 의사결정 요약

| 항목 | 결정 | 근거 |
|---|---|---|
| 분기 | #13 머지 후 `feat/5-gke` 분기 (A) | #4 outputs(`random_password`, Cloud SQL)를 같은 PR에서 소비 |
| 모드 | **Standard** zonal(`asia-northeast3-a`) | 노드 단위 과금 → dev 비용 예측 단순·최소 |
| 노드 수 | autoscaling **min=1 / max=2** | 기본 1대 저렴, 트래픽 검증 시 확장 |
| IAM | **Workload Identity** | 최소 권한: AR pull/로깅은 노드 SA, DB/Secret 접근은 app GCP SA↔KSA 매핑 |
| 네트워크 | **Private cluster** (private nodes + master authorized networks) | repo 보안 기조(IAP-only SSH, private SQL, PGA) 일관 |
| egress | **Cloud NAT** | private 노드가 `*.pkg.dev`(AR)에서 pull — PGA는 `googleapis.com`만 덮음 |

## 3. 범위

### 3.1 신규 리소스

| 리소스 | 파일 | 비고 |
|---|---|---|
| `google_secret_manager_secret.db_app_password` + `_version` | `secret_manager.tf` (신규) | ← #4에서 미룬 것. payload=`base64encode(random_password.db_app_password.result)` |
| `google_service_account.gke_nodes` | `gke.tf` (신규) | `autoresearch-dev-gke-nodes`. roles: `artifactregistry.reader`(←#3), `logging.logWriter`, `monitoring.metricWriter` |
| `google_service_account.gke_app` | `gke.tf` | `autoresearch-dev-app`(WI용). roles: `cloudsql.client`(←#4), `secretmanager.secretAccessor`, + `iam.workloadIdentityUser`→KSA principal binding |
| `google_container_cluster.dev` | `gke.tf` | Standard, zonal, private nodes, WI pool, release channel REGULAR, `deletion_protection=false`(dev) |
| `google_container_node_pool.dev` | `gke.tf` | e2-small, pd-standard 30GB, autoscaling 1~2, 노드 SA, `tags=[ssh-iap]`, `workload_metadata_config{GKE_METADATA}` |
| `google_compute_router.dev` + `google_compute_nat_gateway.dev` | `nat.tf` (신규) | private 노드 egress(Cloud NAT) |

### 3.2 수정 리소스

| 리소스 | 파일 | 변경 |
|---|---|---|
| `google_compute_subnetwork.dev` | `vpc.tf` | `secondary_ip_range` 2개 추가(pods/services). #2 리소스 additive in-place 업데이트 |

### 3.3 변수(`variables.tf` +)

| 변수 | 기본값 | 설명 |
|---|---|---|
| `gke_master_ipv4_cidr` | (필수, /28) | private cluster 마스터 대역. dev subnet/private services와 미중복 |
| `gke_pods_cidr` | (예 /20) | 서브넷 pods 2차 대역 |
| `gke_services_cidr` | (예 /24) | 서브넷 services 2차 대역 |
| `gke_machine_type` | `e2-small` | 노드 머신 타입 |
| `gke_node_count_min` / `_max` | `1` / `2` | 노드풀 autoscaling |
| `gke_node_disk_size` / `_type` | `30` / `pd-standard` | 노드 부트 디스크 |
| `gke_release_channel` | `REGULAR` | 관리형 업그레이드 |
| `gke_deletion_protection` | `false` | dev |
| `master_authorized_networks` | `[]` | kubectl 접속 IP(CIDR). tfvars에서 본인 IP 명시 |
| `gke_app_k8s_namespace` | `autoresearch` | WI KSA principal 계산용 |
| `gke_app_k8s_service_account` | `autoresearch-app` | WI KSA principal 계산용 |

> 모든 CIDR 변수는 `can(cidrhost(...))` validation 추가. `gke_master_ipv4_cidr`는 default 없이(또는 placeholder) tfvars에서 필수 입력.

### 3.4 출력(`outputs.tf` +)

`gke_cluster_name`, `gke_cluster_endpoint`, `gke_cluster_ca_certificate`, `gke_node_service_account_email`, `gke_app_service_account_email`, `gke_workload_identity_principal`(KSA principal 문자열), `db_app_password_secret_id`

## 4. 아키텍처 / 데이터 흐름

```
[개발자 노트북] --(본인 IP, master_authorized_networks)--> [GKE control plane (/28)]
                                                                   |
                                                        private nodes (e2-small x1~2)
                                                          ├─ tags=[ssh-iap] -> IAP SSH(22) 디버그
                                                          ├─ AR pull --(Cloud NAT egress)--> *.pkg.dev
                                                          └─ app pod(KSA) --WI--> app GCP SA
                                                                                  ├─ Cloud SQL Client -> private IP SQL
                                                                                  └─ Secret Accessor -> db password secret
```

- **이미지 pull**: 노드 SA(AR reader) 인증 + 트래픽은 Cloud NAT 경유(`pkg.dev`는 PGA 미지원).
- **DB 접속**: app KSA `iam.gke.io/gcp-service-account` annotation → app GCP SA 가장 → Cloud SQL Client 권한. app 배포 시 Cloud SQL Auth Proxy/Connector 사용(문서화만).
- **노드 디버그**: `ssh-iap` 태그 + 기존 IAP SSH firewall(`35.235.240.0/20` → TCP 22). `roles/iap.tunnelAccessor` gating(기존 정책).

## 5. Workload Identity 매핑

- 클러스터: `workload_identity_config { workload_pool = "${var.project_id}.svc.id.goog" }`
- 노드풀: `workload_metadata_config { mode = "GKE_METADATA" }` (GCE 메타데이터 숨김, WI 강제)
- app GCP SA(`autoresearch-dev-app`)에 binding:
  - member = `serviceAccount:${var.project_id}.svc.id.goog[${var.gke_app_k8s_namespace}/${var.gke_app_k8s_service_account}]`
  - role = `roles/iam.workloadIdentityUser`
- **KSA/namespace 생성은 이 repo(인프라) 범위가 아님** → app 배포 이슈에서 아래 매니페스트로 생성하도록 문서화:
  ```yaml
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    namespace: autoresearch
    name: autoresearch-app
    annotations:
      iam.gke.io/gcp-service-account: autoresearch-dev-app@<project_id>.iam.gserviceaccount.com
  ```

## 6. 선행 / 의존성

- **#13(#4 Cloud SQL) 머지 선행** — `random_password.db_app_password`, Cloud SQL outputs 사용.
- API: `container.googleapis.com`(`locals.required_services`에 이미 포함). NAT/Router=compute(기본 활성화), `secretmanager.googleapis.com`(#4에서 활성화됨).
- 서브넷 2차 대역 additive 업데이트 → 기존 VPC 리소스 in-place 변경(검증 필요).

## 7. 예상 비용 / 절감 / 롤백

- **예상 비용(월)**: e2-small ~$13 + pd-standard 30GB ~$1.5(×2대 시 ~$29) + **Cloud NAT ~$32**(고정비, 최대 항목) + Standard control plane **무료** → 1노드 기준 **~$47/월**.
- **절감**: min=1 고정·e2-small·pd-standard. 장기 미사용 시 노드풀을 count 0 또는 `terraform destroy` 권장(NAT 고정비가 지속됨).
- **롤백**: `deletion_protection=false` → `terraform destroy`로 cluster/node pool/NAT/router/SA 일괄 제거. 현재 dev state는 GCS backend에 저장.

## 8. 완료조건 매핑 (이슈 #5)

- [x] Standard/Autopilot 기준 정리 → Standard 선택(§2)
- [x] zonal cluster → `asia-northeast3-a`(§3.1)
- [x] 노드 머신/수 최소화 → e2-small, min=1/max=2(§3.1)
- [x] VPC/subnet 연결 → dev VPC/subnet + 2차 대역(§3.2)
- [x] cluster SA + 최소 IAM → 노드 SA + app SA(WI)(§3.1, §5)
- [x] 비용 절감(autoscaling/운영중지) → autoscaling + destroy 전략(§7)
- [ ] TF plan에서 cluster/node pool 생성 확인 → 구현 단계
- [ ] kubectl 접근 문서화 → 구현 단계(docs/TERRAFORM_DEV.md + 본 스펙 §4)
- [ ] 예상 비용/절감/롤백 PR 본문 → §7

## 9. 구현 시 파일 구성(예정)

- 신규: `terraform/envs/dev/{gke.tf, nat.tf, secret_manager.tf}`
- 수정: `vpc.tf`, `variables.tf`, `outputs.tf`, `locals.tf`, `terraform.tfvars.example`, `docs/TERRAFORM_DEV.md`, `README.md`
- 로컬 전용(미커밋): `agent.md`, `docs/NOTION_PROGRESS_TIMELINE.md`

## 10. 보류 항목 (YAGNI)

- Cloud SQL 접속 IAM: app SA로 이번에 부여(←#4 미룬 것 해소).
- KSA/namespace 리소스: app 배포 이슈에서 생성(문서화만).
- GCS remote backend, GitHub OIDC 배포 SA: 별개 이슈(#6).
- `master_authorized_networks` 기본 빈 리스트 → 본인 IP는 tfvars에서 명시(보안).
