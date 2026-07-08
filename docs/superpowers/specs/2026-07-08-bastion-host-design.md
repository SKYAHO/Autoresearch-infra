# dev Bastion Host 설계 (#47)

> Status: Draft | Issue: #47 | Last Updated: 2026-07-08

## 목적

팀원이 로컬 브라우저에서 VPC 내부 서비스(1차 대상: #48 Airflow UI ILB)에 접근할
경로를 제공한다. `ACCESS_STRATEGY.md`(#33)에서 후속으로 미뤘던 Bastion을,
전환 조건(Airflow UI 상시 접속) 충족으로 도입한다. 멘토 가이드(폐쇄망 접근은
VPN/Bastion 경유)의 Bastion 경로다.

## 설계 결정

| 결정 | 내용 | 이유 |
|---|---|---|
| VM | e2-micro, pd-standard 10GB, Debian 12 | 터널 종단 용도 최소 사양 (~$8/월) |
| 네트워크 | dev subnet, **외부 IP 없음** | 공격면 최소화. egress는 Cloud NAT |
| SSH 진입 | IAP TCP forwarding만 (`ssh-iap` 태그) | 기존 firewall 재사용, 공인 SSH 포트 없음 |
| 로그인 | OS Login | SSH 키 배포/관리 제거, IAM으로 접속 통제·회수 |
| VM SA | 전용 SA, role 없음 | 최소 권한. bastion이 GCP API를 쓸 일 없음 |
| 팀원 IAM | `iap.tunnelResourceAccessor` + `compute.osLogin` + `compute.viewer` (project) | 터널 통과 + SSH 로그인 + instance 조회. 모두 읽기/접속용 |
| IAM 위치 | `terraform/admin/gke-team-access` | 팀원 이메일을 dev plan에서 분리하는 기존 패턴 유지 |
| on/off | `var.bastion_enabled` (count) | 장기 미사용 시 false apply로 비용 0 |
| 정지 스케줄 | 도입 안 함 (수동 stop 안내) | YAGNI. 사용 패턴 확인 후 별도 검토 |
| VPN(C) | 계속 연기 | 사내망 통합 요구 없음. Bastion이 요구를 충족 |

## 접근 흐름

```
팀원 로컬 ──(gcloud compute ssh --tunnel-through-iap, IAM 검증)──▶ Bastion(e2-micro)
   └─ -L 8080:<ILB>:8080  또는  -D 1080(SOCKS)
                                   │
                                   ▼
                     VPC 내부: Airflow ILB(#48), Cloud SQL 등
```

## 비목표

- Airflow ILB/DNS 구성 (#48)
- Google OAuth allowlist (#49)
- VPN, 자동 정지 스케줄, prod 구성

## 비용 / 리스크 / 롤백

- 비용: VM ~$8/월 + 디스크 ~$0.5 + Cloud NAT VM 몫 최대 ~$32/월.
- 리스크: 단일 장애점(접근 경로 한정, 서비스 영향 없음), OS 패치는 Debian 자동
  보안 업데이트 + 필요 시 재생성(불변 취급).
- 권한 확대: 팀원에게 project 수준 IAM 3종 추가 — 모두 조회/접속용이며 변경
  권한 없음. instance 수준으로 좁히는 최적화는 필요 시 후속.
- 롤백: `bastion_enabled=false` apply(VM 삭제) + IAM 블록 제거. 상태ful 데이터 없음.
