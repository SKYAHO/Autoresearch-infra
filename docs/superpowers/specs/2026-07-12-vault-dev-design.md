# HashiCorp Vault dev 도입 설계

> 작성: 2026-07-12
> 상태: 설계 검토 중 (이슈 발행 전)
> 관련: GCP Secret Manager(현행, `secret_manager.tf`), ArgoCD 설치 패턴(#84)

## 목적

실무에서 널리 쓰이는 secret 관리 도구인 HashiCorp Vault를 dev GKE에
실제 회사 운영 기준으로 설치·운영해 본다. 기존 GCP Secret Manager는
**대체하지 않고 병존**한다 — 실 서비스 secret은 Secret Manager에 유지하고,
Vault에는 학습·검증용 secret만 저장한다(1단계 기준).

## 결정 사항

| 항목 | 결정 | 근거 |
|---|---|---|
| 배포 위치 | dev GKE, 새 admin root `terraform/admin/vault-k8s` | argocd-k8s/monitoring-k8s와 동일 패턴(별도 GCS state prefix, 운영자 전용 plan/apply, CI plan 제외) |
| 설치 방식 | 공식 `hashicorp/vault` Helm chart, 버전 pin | helm_release `atomic`/`cleanup_on_fail` — ArgoCD(#84)와 동일 |
| 서버 모드 | standalone 1 replica + integrated Raft storage(PVC 10Gi) | dev 최소 비용. Raft는 HA 확장 경로를 남김(replica 증설로 전환 가능) |
| unseal | **GCP Cloud KMS auto-unseal** | 실무 표준. Shamir 수동 unseal은 pod 재시작마다 수동 개입 필요. KMS key/GSA는 dev root에서 관리 |
| 노출 | ClusterIP + `kubectl port-forward`(8200)만 | ArgoCD와 동일 원칙. LB/Ingress/공개 endpoint 금지 |
| TLS | 1단계 `tlsDisable=true`(클러스터 내부 + port-forward 한정) | cert 관리 체계(cert-manager) 부재. **실 secret 이관 전 TLS 활성화 필수** — 후속 이슈로 명시 |
| 네트워크 경계 | deny-by-default NetworkPolicy | 아래 상세. #116/#122/#126 교훈 반영 |
| audit | file audit device 활성화 | 실무 기준. stdout/파일 로그 → Cloud Logging 수집 |
| 라이선스 | BSL 1.1 (내부 사용은 무제한) | 오픈소스 필요 시 OpenBao 대안 인지 |

## 아키텍처

```
[운영자] --kubectl port-forward 8200--> [vault-0 (vault ns, ClusterIP)]
                                          | Raft PVC 10Gi
                                          | WI: vault KSA -> autoresearch-dev-vault GSA
                                          v
                                        [Cloud KMS key (auto-unseal, asia-northeast3)]
```

- **dev root 추가분**: KMS keyring/cryptokey, GSA `autoresearch-dev-vault`
  (권한: 해당 key에 대한 `roles/cloudkms.cryptoKeyEncrypterDecrypter`만),
  WI 바인딩(`vault/vault` KSA).
- **vault-k8s admin root**: namespace(PSS 라벨, prevent_destroy), KSA(WI
  annotation), NetworkPolicy, helm_release, values 파일.

## NetworkPolicy 상세 (누적 교훈 반영)

| 방향 | 허용 | 근거 |
|---|---|---|
| ingress | 같은 ns, kube-system | 컴포넌트/시스템 |
| ingress | 노드 대역(`ui_ingress_source_cidr`) → 8200 | port-forward는 노드 IP에서 출발(#116 교훈) |
| egress | 같은 ns | Raft/내부 통신 |
| egress | services CIDR 53 UDP/TCP | kube-dns VIP — Calico pre-DNAT 평가(#122 교훈) |
| egress | kube-system 53 | post-DNAT dataplane 대비 유지 |
| egress | `169.254.169.254/32`:80, `169.254.169.252/32`:987-988 | GKE Standard+Calico의 WI metadata 경로(#126/#127 교훈). KMS unseal이 WI 토큰에 의존 |
| egress | `0.0.0.0/0`:443 | Cloud KMS API |

## Secret 취급 원칙 (보안 최우선)

- `vault operator init` 출력물(root token, recovery keys)은 **Git/PR/채팅/
  Terraform state 어디에도 남기지 않는다**. 팀 비밀번호 관리 경로로만 보관.
- 초기 설정(auth/audit/policy) 완료 후 root token은 revoke하고, 이후 필요
  시 recovery key로 재생성한다(실무 표준).
- Terraform은 Vault 내부 리소스(secret payload, policy 값)를 관리하지
  않는다. 설치와 GCP 측 리소스만 IaC 범위.
- KMS key IAM은 vault GSA 단일 주체, key 단위 부여(프로젝트 수준 금지).

## 비용

| 항목 | 월 비용(추정) |
|---|---|
| Cloud KMS key 1개 + unseal 연산 | < $0.1 |
| PVC 10Gi (pd-balanced) | ~ $1 |
| vault pod (requests 250m/256Mi) | 기존 노드 여유 내, 추가 노드 없음 |

## 단계 분해 (이슈 3개)

1. **dev root**: KMS keyring/key + vault GSA/WI (`vault.tf`) — CI plan 대상
2. **vault-k8s admin root**: namespace/NetworkPolicy/helm release + init·
   unseal·credential 처리 runbook + 실측 검증
3. **후속**: Kubernetes auth method + KV v2 engine + 시범 secret 1개,
   TLS 활성화 및 External Secrets Operator 연동 검토

## 검증 기준 (2단계 apply 후)

- `vault status`: Initialized true / Sealed false / Recovery Seal Type `gcpckms`
- **pod 삭제 후 재기동 시 수동 개입 없이 unseal 되는지** (auto-unseal 핵심 검증)
- 타 namespace pod → vault 8200 차단, port-forward 접근 성공 (경계 양방향)
- WI metadata 경로 확인: vault pod에서 token endpoint HTTP 상태 코드만 확인
  (본문 미출력 — #122 검증 누락 교훈으로 초기 체크리스트에 포함)
- 두 root 최종 plan `No changes`

## 롤백

- helm release 제거 apply → 설치 삭제(namespace는 prevent_destroy로 유지).
  PVC 삭제 시 Vault 데이터는 소실되나 1단계에서는 학습용 secret만 존재.
- dev root KMS key는 destroy 시 즉시 삭제되지 않고 scheduled destruction
  (최소 24h) — key 삭제 전 Vault 데이터가 남아 있으면 복호화 불능이 되므로
  release 제거 → key 삭제 순서를 지킨다.
