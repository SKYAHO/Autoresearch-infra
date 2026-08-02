# 사용하지 않는 Vault 구성 완전 제거 — 설계 노트

> Issue: #478 | Date: 2026-08-02

## 배경

Vault는 #412에서 운영 경로에서 제외됐고(2026-07-29 드랍 확정), 실 서비스
secret은 GCP Secret Manager를 사용한다. 이 PR은 코드·구조 정리만 다룬다.

## live 상태 확인 (2026-08-02 실측)

- `kubectl get namespace vault`: 존재하지 않음 — 클러스터에 Vault 관련 리소스
  없음(namespace, Helm release, Pod, NetworkPolicy 모두 부재).
- `terraform -chdir=terraform/admin/vault-k8s state list`: `helm_release.vault`,
  `kubernetes_namespace_v1.vault`, `kubernetes_network_policy_v1.vault_egress`,
  `kubernetes_network_policy_v1.vault_ingress` 4개 리소스가 여전히 state에
  남아 있음(2개는 `data.*`) — **state와 live가 어긋난 상태(drift)**. 누군가
  Terraform 밖에서 live 리소스를 지웠고(#412 B~C, `docs/MIGRATION_RUNBOOK.md`
  2026-07-30 항목에 "vault 클러스터의 helm release·namespace를 최종 삭제"로
  기록됨) state는 갱신하지 않은 것으로 보인다.
- `terraform -chdir=terraform/envs/dev state list | grep vault`: `vault.tf`가
  선언한 6개 리소스(KMS keyring/key, GSA, WI 바인딩, custom role, role
  binding) 모두 존재. 이쪽은 drift 없음 — 코드가 있으니 리소스도 있다.
- `roles/cloudkms.admin`(`github_actions.tf` dev_apply SA)은 저장소 전체에서
  vault.tf 외 다른 소비자가 없음을 grep으로 확인. Vault 제거 시 함께 제거
  대상.

## 이 PR의 범위 — 코드/문서만, state·apply는 별도 승인

이슈 본문의 명시적 caution(`실제 GCP apply/state 변경은 별도 승인 후
수행합니다`)에 따라 이 PR은 다음만 수행한다.

- dev root 코드 제거(`vault.tf` 및 `variables.tf`/`locals.tf`/`outputs.tf`/
  `github_actions.tf`의 Vault 전용 항목)
- `terraform/admin/vault-k8s/` 디렉터리 전체 삭제(코드만 — GCS backend의
  원격 state 파일 자체는 건드리지 않는다)
- 문서 갱신(`CLAUDE.md`/`.claude/docs/*`, `docs/TERRAFORM_DEV.md`,
  `docs/VAULT_OPERATIONS_RUNBOOK.md` 배너, `dns.tf`/`elastic.tf`의 vault
  예시 주석)
- **PR에는 포함하지 않음**: 실제 `terraform apply`/`state rm`/`destroy` 실행

## admin root 완전 삭제 vs 리소스 블록만 비우기 — 결정

두 선택지:

1. **리소스 블록만 비우고 root 디렉터리는 유지** — 이후 `terraform state
   rm`을 그 자리에서 바로 실행할 수 있어 편하지만, 코드가 없는 리소스만
   덜렁 남은 root가 저장소에 계속 남아 "왜 존재하는지" 혼란을 준다.
2. **root 디렉터리 전체 삭제**. state 정리가 필요해지면 그 시점에 git
   history(`git show <이 삭제 커밋의 부모>:terraform/admin/vault-k8s/...`)로
   파일을 임시 복원해 `terraform init`/`state rm`을 실행하고 다시 지운다.

**선택: 2.** 이슈 제목이 "완전 제거"이고, 코드 삭제와 GCS backend의 원격
state 파일은 완전히 분리된 것(로컬 .tf 파일을 지워도 원격 state는 그대로
남는다)이므로 디렉터리를 미리 지워도 이후 state 정리에 지장이 없다. 다만
`kubernetes_namespace_v1.vault`에 `prevent_destroy = true`가 걸려 있어
**`terraform destroy`/`apply`로는 지울 수 없다** — `terraform state rm`은
lifecycle 검사를 거치지 않으므로(state에서만 분리, provider API 호출 없음)
이 경로를 쓴다. live에는 이미 해당 리소스가 없으므로 `state rm`은 GCP/K8s에
어떤 영향도 주지 않는다.

## 승인 후 실행할 state 정리 절차 (이 PR에 미포함)

```bash
# 1) 이 PR 머지 커밋의 부모(vault-k8s가 아직 있던 마지막 커밋)에서 파일 복원
git show <부모커밋>:terraform/admin/vault-k8s/main.tf > /tmp/vault-k8s-main.tf
# (versions.tf/variables.tf/outputs.tf/terraform.tfvars.example도 동일하게 복원)
cd /tmp/vault-k8s-restore  # 위 파일들을 모아 임시 디렉터리 구성
terraform init
terraform state rm kubernetes_namespace_v1.vault
terraform state rm kubernetes_network_policy_v1.vault_ingress
terraform state rm kubernetes_network_policy_v1.vault_egress
terraform state rm helm_release.vault
terraform state list   # data source 2개만 남고 비어 있어야 함
```

state가 비면 원격 GCS state 객체도 정리 대상이나, 실제 삭제(버킷 오브젝트
제거)는 별도로 재확인 후 수행한다.

## KMS 잔여 자산 — 삭제 불가, 문서화로 대체

`google_kms_key_ring.vault`(`autoresearch-dev-vault`)는 GCP 특성상 **key
ring 자체를 영구히 삭제할 수 없다**(GCP 플랫폼 제약, `vault.tf` 기존
주석에도 명시). `google_kms_crypto_key.vault_unseal`도 crypto key 리소스
자체는 삭제되지 않으며, `prevent_destroy = true`가 걸려 있어 Terraform
코드에서 제거해도 실제 GCP 리소스는 그대로 남는다(코드 제거는 Terraform
관리 대상에서 빠질 뿐, GCP에서 사라지지 않는다).

- 코드(dev root `vault.tf`)에서 6개 리소스(keyring, key, GSA, WI 바인딩,
  custom role, key IAM binding)를 모두 제거한다 — Terraform state에서
  `terraform apply` 시 destroy 시도가 발생하는데, key/keyring은 GCP가
  삭제를 거부하므로(`prevent_destroy`도 이를 사전 차단) **이 apply는 별도
  승인 후 실행하며, key/keyring 두 리소스는 오차 없이 `state rm`으로
  분리하는 방식을 검토한다**(destroy 시도 자체가 실패로 apply를 막을 수
  있으므로).
- GSA·WI 바인딩·custom role·key IAM binding 4개는 실제로 삭제 가능한
  일반 IAM 리소스라 `terraform apply`(destroy)로 정상 제거된다.
- 잔여 KMS 자산(keyring `autoresearch-dev-vault`, key `vault-unseal`)은
  **비활성화·잔여 자산으로 문서화**한다 — 별도 비용은 발생하지 않는다(KMS
  keyring/key 자체는 무료, 과금은 암호화 연산 건수 기준이며 미사용 시
  0). 위협 모델: 이 key는 90일 rotation이 설정돼 있었으나 IAM 바인딩
  제거 후에는 아무도 접근 권한이 없어 실질적으로 비활성 상태와 같다.

## 완료 조건

- [ ] `terraform/envs/dev/vault.tf` 삭제
- [ ] `variables.tf`/`locals.tf`/`outputs.tf`의 Vault 전용 항목 제거
- [ ] `github_actions.tf`의 `roles/cloudkms.admin` 제거
- [ ] `dns.tf`/`elastic.tf`의 vault 참조 주석 정리
- [ ] `terraform/admin/vault-k8s/` 디렉터리 삭제
- [ ] `CLAUDE.md`(및 symlink `AGENTS.md`), `.claude/docs/agent-project-reference.md`,
      `.claude/docs/agent-terraform-reference.md`, `.claude/docs/architecture-overview.md`
      갱신
- [ ] `docs/TERRAFORM_DEV.md` "Vault auto-unseal 기반 — 폐기 이력" 절과
      디렉터리 트리 갱신
- [ ] `docs/VAULT_OPERATIONS_RUNBOOK.md` 배너 갱신(코드 제거 완료, state
      정리는 승인 대기로 정정)
- [ ] `fmt -check`, `validate`, `git diff --check` 통과
- [ ] plan에 의도하지 않은 리소스 삭제가 없는지 검토(dev root에서 vault
      6개 리소스만 destroy 대상으로 나와야 한다)
- [ ] KMS key ring/crypto key 삭제 불가 사실과 잔여 비용을 문서에 기록

## 롤백

- 코드 변경만 되돌리려면 이 PR을 revert한다 — live 리소스는 건드리지
  않았으므로 즉시 원상 복구된다.
- 승인 후 state rm까지 실행했다면, `terraform/admin/vault-k8s/`를 git
  history에서 복원하고 `terraform import`로 4개 리소스를 다시 state에
  넣을 수 있다(단, live 리소스가 이미 없으므로 `helm_release`/`namespace`/
  `network_policy`는 import 대상 자체가 없다 — 실질적으로는 재설치가
  필요하며, 이는 이 PR의 롤백 범위를 넘는다).
