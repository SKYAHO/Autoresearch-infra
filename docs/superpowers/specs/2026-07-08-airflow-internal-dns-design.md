# Airflow UI 내부 노출 설계 (#48)

> Status: Done (구현·apply 완료) | Issue: #48 | Last Updated: 2026-07-09

## 목적

Airflow 웹서버(8080)를 VPC 내부망에서 도메인으로 접근할 수 있게 한다
(멘토 가이드: 내부망 접근 가능 + 필요 시 GCP DNS 등록). 인터넷 노출은 없다.
브라우저 접근은 Bastion(#47) 터널을 전제로 한다.

## 설계 결정

| 결정 | 내용 | 이유 |
|---|---|---|
| 노출 방식 | k8s Service `type: LoadBalancer` + `networking.gke.io/load-balancer-type: Internal` | GKE internal passthrough LB. 외부 노출 없음, LB 자체 무과금 |
| VIP | Terraform 예약 내부 고정 IP (`SHARED_LOADBALANCER_VIP`) | Helm 재설치에도 IP 불변 → DNS 레코드 안정 |
| DNS | Cloud DNS **private zone** `dev.autoresearch.internal` + `airflow.` A 레코드 | VPC 내부에서만 조회. `var.internal_dns_domain`으로 변경 가능 |
| NetworkPolicy | `airflow` ns ingress에 dev subnet(10.10.0.0/20)→8080 허용 추가 | source IP 보존은 Service `externalTrafficPolicy: Local` 전제(Helm values 필수 항목, 리뷰 반영). 기존 same-ns/kube-system 규칙 유지 |
| Helm values | 앱 저장소 관리. 인프라는 IP/DNS/경계만 제공 | 기존 역할 분리 원칙(#32) 유지 |
| 가용성 | webserver **replica 2 + PDB + soft anti-affinity** (values 가이드 필수 항목) | `Local` 정책의 pod 재시작 단절 창 제거. replica>1이면 `webserverSecretKey` 고정 필요 |
| 필요 API | `dns.googleapis.com` (수동 활성화) | `google_project_service` 미사용 정책 |

## 접근 흐름

```
팀원 로컬 ──(IAP 터널, #47 Bastion, SOCKS -D 1080)──▶ Bastion
                └─ http://airflow.dev.autoresearch.internal:8080 (private DNS 조회)
                                   │
                                   ▼
              ILB 고정 IP (dev subnet) ──▶ airflow ns webserver:8080
                          (NetworkPolicy: dev subnet만 허용)
```

## 비목표

- 인터넷 노출, HTTPS/인증서 (내부 HTTP. 필요해지면 별도 이슈)
- Google OAuth 로그인 (#49(close, #54로 대체))
- Helm values 실제 적용 (앱 저장소 작업)

## 비용 / 리스크 / 롤백

- 비용: private zone $0.20/월 + 내부 고정 IP/passthrough ILB 무과금 수준.
- 리스크: NetworkPolicy가 subnet 전체(10.10.0.0/20)를 허용 — GKE 노드도 포함되나
  pod 트래픽은 pods CIDR(172.16.64.0/20)이라 영향 없음. 더 좁히려면 Bastion IP/32로
  tfvars 조정 가능(`ui_ingress_source_cidr`). **주의**: source IP 기준 제한은
  Service `externalTrafficPolicy: Local`일 때만 성립 — 기본값(Cluster)이면 SNAT로
  노드 IP가 소스가 되어 CIDR을 좁혀도 실효가 없고, Local 없이 /32로 좁히면 접근이
  조용히 끊긴다. Helm values에 Local을 필수로 명시한다(리뷰 반영).
- `Local`의 단절 창은 replica 2 + PDB로 제거한다. 단 airflow 노드풀 1대 구성에서는
  노드 업그레이드 시 짧은 단절이 남는다(dev 허용, 제거하려면 노드풀 max=2).
  운영 전환 시에는 L7 internal ALB(NEG, 노드 경유 제거) + 인증 계층(IAP/OAuth)을
  주 방어로 전환한다 — Envoy 고정비로 dev 미적용.
- 참고: 예약 IP `purpose=SHARED_LOADBALANCER_VIP`는 GKE 공식 문서의 ILB 예약 IP
  패턴으로 단일 Service에서도 유효하다(최대 10개 forwarding rule 공유 가능).
- 롤백: `dns.tf` 제거 + NetworkPolicy 블록 제거 apply. Helm Service를 ClusterIP로
  되돌리면 ILB 삭제.
