# Vault Kubernetes Admin Root

이 root는 dev GKE의 HashiCorp Vault 설치를 별도 state로 관리한다. GCP 측
기반(KMS unseal key, GSA, WI 바인딩)은 dev root `vault.tf`(#132)가 담당하고,
이 root(#134)는 namespace, 네트워크 경계, Helm release를 담당한다.
설계: `docs/superpowers/specs/2026-07-12-vault-dev-design.md`.

## 책임 범위

| 항목 | 이 root에서 관리 | 비고 |
|---|---|---|
| `vault` namespace | 예 | `prevent_destroy`로 실수 삭제 방지 |
| Vault Helm release | 예 | chart `vault` `0.34.0` pin |
| Helm values | 예 | `helm-values/vault.values.yaml` |
| NetworkPolicy | 예 | deny-by-default ingress/egress |
| KMS key / GSA / WI | 아니오 | dev root `vault.tf`(#132) |
| Vault 내부 리소스 (secret, policy, auth) | 아니오 | 운영자가 CLI/UI로 관리 (runbook) |
| init 출력물 (root token, recovery keys) | 아니오 | 팀 비밀번호 관리 경로로만 보관 |

## 설치 구성 (#134)

| 항목 | 값 | 비고 |
|---|---|---|
| Chart | `vault` `0.34.0` | `var.vault_chart_version` |
| 모드 | single-node integrated Raft (`ha.replicas=1`) | HA 확장 경로 유지, 비용 최소 |
| unseal | Cloud KMS gcpckms (auto-unseal) | key/GSA는 dev root #132 |
| Service | `ClusterIP` | 외부 공개 금지. LoadBalancer/Ingress 없음 |
| TLS | **비활성 (1단계)** | 클러스터 내부 + port-forward 한정. 실 secret 이관 전 활성화 필수 |
| injector | disabled | 최소 설치. 필요 시 별도 이슈 |
| PVC | 데이터 10Gi + audit 5Gi | 삭제 시 Vault 데이터 소실 |
| KSA | chart 생성 `vault` + WI annotation | dev root WI principal(`vault/vault`)과 일치 필수 |

## 네트워크 경계

| 방향 | 허용 | 이유 |
|---|---|---|
| ingress | 같은 namespace | server/raft 통신 |
| ingress | kube-system | 시스템 컴포넌트 |
| ingress | `var.ui_ingress_source_cidr`(dev subnet) → 8200 | port-forward 트래픽은 노드 IP에서 출발(#116 교훈) |
| egress | 같은 namespace | raft cluster(8201) |
| egress | services CIDR 53 | kube-dns VIP — Calico pre-DNAT 평가(#122 교훈) |
| egress | kube-system 53 | post-DNAT dataplane 대비 유지 |
| egress | `169.254.169.254/32`:80, `169.254.169.252/32`:987-988 | WI metadata 경로(#126/#127 교훈). auto-unseal이 의존 |
| egress | 0.0.0.0/0 443 | Cloud KMS API, Kubernetes API |

## 사용 방법

```bash
cd terraform/admin/vault-k8s
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars에 실제 project_id를 입력합니다. 이 파일은 커밋하지 않습니다.

terraform init
terraform plan
terraform apply
```

주의: `helm-values/vault.values.yaml`의 GSA annotation과 `seal "gcpckms"`
project/key 값은 dev root #132 리소스(단일 dev project) 고정 값이다. values는
`file()`로 정적 로드되므로 `project_id` 변수와 무관하다 — 다른 project로
재구성할 때는 이 파일을 직접 수정해야 한다.

실행 환경에는 dev GKE API 접근 경로와 namespace/NetworkPolicy/Helm release를
만들 수 있는 Kubernetes 권한이 필요하다. 일반 PR CI가 아니라 운영자 환경에서만
plan/apply한다. **선행 조건**: dev root `vault.tf`(#132) apply 완료
(KMS key/GSA/WI가 없으면 pod가 seal 초기화에 실패한다).

로컬 검증:

```bash
terraform -chdir=terraform/admin/vault-k8s fmt -check -recursive
terraform -chdir=terraform/admin/vault-k8s init -backend=false
terraform -chdir=terraform/admin/vault-k8s validate
```

## 설치 후 확인과 운영

init(최초 1회), 접속, credential 처리, 재기동 auto-unseal 확인, 장애 대응은
[docs/VAULT_OPERATIONS_RUNBOOK.md](../../../docs/VAULT_OPERATIONS_RUNBOOK.md)를
따른다.

```bash
kubectl -n vault get pods
# 외부 공개 리소스가 없는지 검증: 모든 Service가 ClusterIP여야 한다.
kubectl -n vault get svc
kubectl -n vault get ingress
```

## 실 secret 이관 전 필수 조건

- **TLS 활성화** (`global.tlsDisable=false` + 인증서 체계) — 별도 이슈
- Kubernetes auth method와 최소 권한 policy 구성(3단계)
- 그 전까지 Vault에는 학습·검증용 더미 값만 저장한다. 실 서비스 secret은
  GCP Secret Manager를 계속 사용한다.

## 롤백

- `helm_release.vault` 제거 후 apply → release 삭제. namespace는
  `prevent_destroy`로 남는다. PVC(Raft 데이터)는 chart가 남기므로 완전
  정리는 PVC 삭제까지 수행한다.
- **KMS key(dev root)는 release/PVC 정리 이후에만 손댄다** — 데이터가 남은
  상태에서 key version을 disable/destroy하면 복호화가 영구 불능이 된다.
- chart 버전 롤백은 `vault_chart_version`을 이전 버전으로 되돌려 apply한다.
