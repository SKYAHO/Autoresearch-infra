# GKE DNS 기반 엔드포인트 설계 (#45)

> Status: Done (구현·apply 완료) | Issue: #45 | Last Updated: 2026-07-09

## 목적

팀원 kubectl 접근이 `master_authorized_networks`(공인 IP allowlist)에 묶여 있어 IP가
바뀔 때마다 tfvars 갱신 + apply가 필요하다. GKE **DNS 기반 컨트롤 플레인
엔드포인트**를 활성화해 네트워크 위치와 무관하게 팀원 구글 계정(IAM)만으로
클러스터에 접근하게 한다.

## 동작 원리

클러스터별 고유 FQDN(`gke-....gke.goog`)이 발급되고, 이 주소로 오는 요청은 GKE
컨트롤 플레인에 닿기 전에 **Google 프런트엔드에서 IAM
(`container.clusters.connect`)으로 먼저 검증**된다. 따라서 IP allowlist 없이도
비인가 트래픽이 클러스터 엔드포인트에 도달하지 못한다.

## 설계 결정

| 결정 | 내용 | 이유 |
|---|---|---|
| 활성화 방식 | `control_plane_endpoints_config { dns_endpoint_config { allow_external_traffic = true } }` | google provider 7.39(현재 lock)에서 지원. in-place update |
| IP 엔드포인트 | **유지** (병행 운영) | 전환기 예비 경로. CI plan 등 기존 경로 영향 없음. 축소는 안정화 후 별도 이슈 |
| `master_authorized_networks` | 유지 | IP 경로 예비용. DNS 경로에는 적용되지 않음 |
| 팀원 IAM | `roles/container.clusterViewer` → `roles/container.viewer` | connect가 clusterViewer에 없음. viewer는 클러스터 전역 k8s 읽기(secrets 제외)도 포함 — 소규모 팀 상호 가시성을 위해 **의도적으로 채택**(리뷰 논의 반영). 쓰기는 RBAC로만 |
| 접속 명령 | `gcloud container clusters get-credentials ... --dns-endpoint` | kubeconfig가 DNS 주소를 가리키게 발급 |
| output | `gke_dns_endpoint` 추가 | 팀원 안내/문서화용 |

## 보안 트레이드오프

- 엔드포인트가 네트워크상 도달 가능해지는 대신 IAM이 유일한 관문. Google API
  프런트엔드가 앞단이므로 무인증 트래픽은 클러스터에 닿지 않는다.
- 계정 보안(2FA)이 사실상 방어선. dev 규모에서 수용, 운영 전환 시 재평가.
- viewer 승격으로 팀원은 전체 namespace k8s 오브젝트를 읽을 수 있다(secrets 제외, 의도된 방침). 쓰기/설치 권한은 기존 RBAC(#32) 그대로.

## 비목표

- IP 엔드포인트/authorized networks 제거 (별도 이슈)
- Airflow UI 접근 (kubectl 외 웹 트래픽은 이 방식으로 해결되지 않음 — #33 후속)
- Bastion/VPN 도입 여부 결정 (#33 기준 유지)

## 비용 / 롤백

- 비용: $0 (기능 자체 무과금).
- 롤백: `control_plane_endpoints_config` 블록 제거 + role 원복 후 apply. 기존 IP
  경로가 살아 있으므로 접속 단절 없음.
