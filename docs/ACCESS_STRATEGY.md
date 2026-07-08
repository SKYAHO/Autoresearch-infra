# Dev 환경 내부망 접근 전략 (#33)

팀원이 로컬에서 dev GKE / Cloud SQL / 내부 서비스(Airflow UI 등)에 안전하게 접근하는 방식을 정리한다. Bastion Host, VPN, authorized networks 세 후보를 비교해 dev 환경에 맞는 1차 방식을 선택하고, 중기 대안의 도입 기준을 정의한다.

## 현재 아키텍처 전제

- GKE `autoresearch-dev-gke`: private nodes + **public endpoint**(`enable_private_endpoint=false`), `master_authorized_networks`로 특정 공인 IP만 마스터 API 허용.
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

**A + D 조합**으로 dev를 운영한다. Bastion Host(B)와 VPN(C)은 **후속 이슈로 연기**한다.

1. **GKE 마스터 API**: `master_authorized_networks`에 팀원 공인 IP/32 추가(기존 방식, #34로 `roles/container.clusterViewer` 부여와 짝). IP 변경 시 tfvars 갱신 + apply.
2. **Cloud SQL(private IP)**: 로컬에서 private IP로 직접 접속하지 않는다. 1차
   경로는 GKE 내부에서 Cloud SQL Auth Proxy 또는 Connector를 실행하고
   `kubectl port-forward`로 localhost에 연결하는 방식이다. IAP TCP forwarding은
   터널 종단이 될 Compute VM/GKE 노드의 특정 포트가 필요하므로, 임의의 Cloud SQL
   private IP로 직접 터널을 만들 수 없다. `gcloud sql connect`류의 공인 IP
   allowlist 방식은 현재 `ipv4_enabled=false`인 private-IP-only 인스턴스에는
   맞지 않는다.
3. **내부 서비스(Airflow UI 등)**: `kubectl port-forward`로 localhost에서만 접속. 외부 미공개 원칙 준수. 필요 시 Cloud Run proxy(#27) 경유 경로 별도 검토.
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
- **Bastion(후속 이슈)**: 신규 `bastion.tf` — compute instance + IAP tunneling IAM + (선택) 정지 스케줄. 비용 절감을 위해 토요일/일요일 자동 정지 권장.
- **VPN(후속 이슈)**: `google_compute_vpn_gateway` / `google_compute_ha_vpn_gateway` + 터널 + 라우팅. 피어 측 설정 의존.

## Airflow UI / 내부 서비스 접근 원칙

- **외부 미공개가 기본**. Ingress/LoadBalancer를 통한 공개 노출은 dev에서도 금지.
- 접근은 `kubectl port-forward`(localhost) 또는 인증 gate(Cloud Run proxy + IAM) 경로로만.
- `airflow` namespace(#32) NetworkPolicy ingress는 같은 namespace + `kube-system`만 허용. 외부는 차단.

## 참조

- PR #34: 팀원 GKE kubectl 접근 IAM(`roles/container.clusterViewer`)
- Issue #32 / PR #37: Airflow namespace + NetworkPolicy(내부망 접근 경계)
- PR #27: dev proxy Cloud Run(내부 서비스 인증 gate 후보)
- `docs/TERRAFORM_DEV.md` GKE 섹션: kubectl 접근 절차
