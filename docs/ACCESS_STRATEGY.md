# Dev 환경 내부망 접근 전략 (#33)

팀원이 로컬에서 dev GKE / Cloud SQL / 내부 서비스(Airflow UI 등)에 안전하게 접근하는 방식을 정리한다. Bastion Host, VPN, authorized networks 세 후보를 비교해 dev 환경에 맞는 1차 방식을 선택하고, 중기 대안의 도입 기준을 정의한다.

## 현재 아키텍처 전제

- GKE `autoresearch-dev-gke`: private nodes + **public endpoint**(`enable_private_endpoint=false`). 마스터 API 접근은 **DNS 기반 엔드포인트(IAM 검증, #45)가 기본**이고, `master_authorized_networks`(IP allowlist)는 예비 경로로 병행 유지.
- Cloud SQL `autoresearch-dev-pg`: **private IP only**. VPC 내부에서만 접근.
- VPC `autoresearch-dev-vpc`: IAP 경유 SSH(22/TCP) firewall rule 존재(`ssh-iap` 태그 VM).
- Cloud Run proxy(#27): VPC 내부 전용(`INGRESS_TRAFFIC_INTERNAL_ONLY`), invoker IAM 인증.

## 접근 방식 비교

| 후보 | 비용(dev/월) | 보안 | 운영 난이도 | 비고 |
|---|---|---|---|---|
| **A. master_authorized_networks(IP allowlist)** | **$0** | 중(IP 노출/변경 시 재등록). 마스터 API만 | 낮음(IP 1줄 추가 apply) | 팀원 공인 IP가 자주 바뀌면 관리 비용 증가. kubectl은 가능하지만 Cloud SQL private IP / 내부 서비스 직접 접근은 별도 경로 필요 |
| B. Bastion Host(단일 VM) | ~$10-15(e2-micro + disk) + Cloud NAT 공유 | 중-고(IAP tunneling으로 SSH만). 미사용 시 비용 누적 | 중(VM 패치/키 관리). IAP tunneling 필수 | private Cloud SQL / 내부 서비스 직접 접근 가능. 단일 장애점. 장기 실행 비용 |
| C. GCP Cloud VPN / HA VPN(site-to-site) | ~$25+(고정비) + 피어 측 VPN 장비 | 고(전사 네트워크와 VPC 터널) | 높음(피어 측 설정, 라우팅, 키 rotation) | dev 단일 팀 규모엔 과잉. 사내 VPN 인프라 전제 |
| D. Identity-Aware Proxy(IAP) tunneling(기존 firewall) | **$0**(IAP 자체 무료, 터널 대역폭 과금 미미) | 고(Google 계정 + `roles/iap.tunnelAccessor` gating) | 낮음(IAP 데스크톱 클라이언트) | IAP TCP forwarding은 Compute VM 또는 GKE 노드의 특정 포트가 종단이어야 한다. 임의의 VPC private IP로 직접 터널링하지 않는다 |

## 1차 권장안(dev)

**A + D 조합**으로 dev를 운영한다. VPN(C)은 **후속 이슈로 연기**한다.

> **갱신(2026-07-08)**: Airflow UI 상시 접속 요구(전환 조건 충족)로 **Bastion(B)을
> #47에서 도입**한다. 팀원이 IAP 터널로 bastion을 거쳐 VPC 내부 서비스(#48
> Airflow ILB + private DNS)에 브라우저로 접근한다. 아래 3번 항목의
> port-forward는 예비 경로로 남는다.

1. **GKE 마스터 API**: **DNS 기반 컨트롤 플레인 엔드포인트(#45)가 기본 경로**.
   Google 프런트엔드에서 IAM(`container.clusters.connect`, `roles/container.viewer`)으로
   검증되므로 팀원 IP 등록이 필요 없다. `master_authorized_networks`(IP allowlist)는
   예비 경로로 병행 유지하고, 안정화 후 IP 엔드포인트 축소는 별도 이슈로 검토한다.
2. **Cloud SQL(private IP)**: 로컬에서 private IP로 직접 접속하지 않는다. 1차
   경로는 GKE 내부에서 Cloud SQL Auth Proxy 또는 Connector를 실행하고
   `kubectl port-forward`로 localhost에 연결하는 방식이다. IAP TCP forwarding은
   터널 종단이 될 Compute VM/GKE 노드의 특정 포트가 필요하므로, 임의의 Cloud SQL
   private IP로 직접 터널을 만들 수 없다. `gcloud sql connect`류의 공인 IP
   allowlist 방식은 현재 `ipv4_enabled=false`인 private-IP-only 인스턴스에는
   맞지 않는다.
3. **내부 서비스(Airflow UI 등)**: 기본 경로는 **Bastion(#47) 경유** —
   IAP SSH 터널 + 포트 포워딩/SOCKS 프록시로 내부 ILB(#48)에 접속. 예비
   경로는 `kubectl port-forward`. 외부 미공개 원칙은 유지(내부 ILB + private DNS).
4. **GKE 노드 SSH(디버깅)**: IAP tunneling(`gcloud compute ssh ... --tunnel-through-iap`), `roles/iap.tunnelAccessor` 부여.

**선택 근거**:
- 비용: A + D는 $0. Bastion/VPN은 dev 월 고정비 ~$10-25 추가(Cloud NAT ~$32와 더해지면 dev 최대 비용 항목).
- 보안: IAP는 Google 계정 + IAM gating으로 IP allowlist보다 정교. VPN은 과잉(전사 네트워크 연결).
- 운영: Bastion VM 패치/키 관리/단일 장애점 부담. 팀원 수가 소수(dev)인 현재는 allowlist + IAP로 충분.

## 중기 전환 기준(Bastion/VPN 재검토)

아래 임계치를 넘으면 Bastion 또는 VPN 도입을 별도 이슈에서 다시 평가한다.

- 팀원 수 5명 초과, 또는 공인 IP 변경 주기가 주 1회 이하로 빈번해 tfvars apply 운영 부담이 역전할 때
- private 서비스(Airflow UI, DB 콘솔) 접속 빈도/지속 시간이 port-forward 단위로 비효율일 때
- 사내 VPN 인프라와의 통합이 보안/컴플라이언스 요구로 떠오를 때

도입 순위: **VPN(C)이 사내 인프라와 통합 필요 없으면 → Bastion(B)** 로. dev 규모에선 Bastion 1대가 설정/비용 면에서 더 가볍다.

## Terraform 변경 범위

- **dev 1차(A + D)**: 변경 **0**. `master_authorized_networks`는 기존 변수, IAP tunneling firewall은 `vpc.tf`에 이미 구성. 팀원 IP는 tfvars(로컬, 비커밋)에서 관리.
- **Bastion(#47, 도입)**: `terraform/envs/dev/bastion.tf` — e2-micro, 외부 IP 없음,
  OS Login, IAP 전용. 팀원 IAM 3종(`iap.tunnelResourceAccessor`, `compute.osLogin`,
  `compute.viewer`)은 `terraform/admin/gke-team-access`에서 관리. 미사용 시
  `bastion_enabled=false`로 제거 가능. 사용법은 `docs/TERRAFORM_DEV.md` Bastion 섹션.
- **VPN(후속 이슈)**: `google_compute_vpn_gateway` / `google_compute_ha_vpn_gateway` + 터널 + 라우팅. 피어 측 설정 의존.

## Airflow UI / 내부 서비스 접근 원칙

- **외부 미공개가 기본**. Ingress/LoadBalancer를 통한 공개 노출은 dev에서도 금지.
- 접근은 `kubectl port-forward`(localhost) 또는 인증 gate(Cloud Run proxy + IAM) 경로로만.
- `airflow` namespace(#32) NetworkPolicy ingress는 같은 namespace + `kube-system`만 허용. 외부는 차단.

## 참조

- PR #34: 팀원 GKE kubectl 접근 IAM(`roles/container.clusterViewer`)
- Issue #32 / PR #37: Airflow namespace + NetworkPolicy(내부망 접근 경계)
- PR #27: dev proxy Cloud Run(내부 서비스 인증 gate 후보)
- `docs/GKE_CLUSTER_ACCESS.md`: 팀원 로컬 kubeconfig / kubectl 접근 절차
- `docs/TERRAFORM_DEV.md` GKE 섹션: kubectl 접근 절차
