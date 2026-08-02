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
  `github_actions.tf`의 Vault 전용 항목) + dev root state에 남는 6개
  리소스에 대한 `removed` 블록 추가(destroy 없이 forget, 아래 "state 분리
  전략" 참조)
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
남는다)이므로 디렉터리를 미리 지워도 이후 state 정리에 지장이 없다.

`kubernetes_namespace_v1.vault`에는 `prevent_destroy = true`가 걸려 있었지만,
**이 보호는 리소스 블록이 config에 남아 있을 때만 작동한다** —
`lifecycle` 메타인자는 config 쪽 검사이므로, 이 PR처럼 블록 자체를
삭제하면 다음 plan은 그 항목을 그냥 "config에 없는 state 항목 = destroy
대상"으로 취급하고 `prevent_destroy` 검사는 아예 실행되지 않는다(잘못된
안전 근거였던 부분 — claude-review 지적으로 정정). 그런데도 이 root는 실제
위험이 없다: `vault-k8s`는 애초에 `apply.yml`의 admin ROOTS 목록에서
제외돼 있어(#416) CI가 이 root를 plan/apply할 경로 자체가 없고, 로컬에서
디렉터리를 복원해 수동으로 `terraform apply`(destroy)를 실행하지 않는 한
아무 apply도 걸리지 않는다. 그래서 아래 "승인 후 실행할 state 정리
절차"처럼 **`state rm`만 수동으로 실행하는 경로를 그대로 유지**한다(dev
root처럼 `removed` 블록을 쓸 수 없는 이유는, 이 PR이 root 디렉터리 자체를
지워 main에 그 config가 더 이상 존재하지 않기 때문 — `removed` 블록도
"해당 root의 config"의 일부이므로 넣을 자리가 없다). live에는 이미 해당
리소스가 없으므로 `state rm`은 GCP/K8s에 어떤 영향도 주지 않는다.

## 승인 후 실행할 vault-k8s admin root state 정리 절차 (이 PR에 미포함)

dev root 6개 리소스는 아래 절차 대신 위 "dev root state 분리 전략"의
`removed` 블록 apply로 처리한다. 이 절차는 `terraform/admin/vault-k8s/`
root(디렉터리 자체가 이 PR로 삭제돼 `removed` 블록을 넣을 config가
없는 root)의 4개 K8s 리소스 전용이다.

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

## dev root state 분리 전략 — `removed` 블록 (claude-review 지적 반영)

**최초 초안의 안전성 근거 두 가지가 실제 Terraform/provider 동작과
어긋났다(claude-review 지적, 2026-08-02)** — 아래에 정정한다.

1. **`prevent_destroy`는 리소스 블록을 삭제하면 더 이상 보호막이
   아니다.** `lifecycle` 메타인자는 *config*에서 온다. `vault.tf` 블록
   자체를 삭제하면 다음 plan에서 `google_kms_crypto_key.vault_unseal`은
   "config에 없는 state 항목 = destroy 대상"으로만 취급되고
   `prevent_destroy` 검사는 애초에 실행되지 않는다(블록이 남은 채로
   destroy가 계획될 때만 apply를 막는 장치이기 때문).
2. **`google_kms_crypto_key` destroy는 "GCP가 거부"하지 않는다.**
   provider 문서 기준으로 crypto key 리소스 자체(그리고 keyring)는 GCP
   에서 지워지지 않지만, destroy 시 **모든 CryptoKeyVersion의 파기가
   스케줄**된다(기본 24시간 후 확정, 그 전까지만 복구 가능). 즉 "삭제
   거부 → 무해"가 아니라 "키 버전은 실제로 파기 예약됨"이다. 지금은 Vault
   Raft 데이터가 없어 실피해가 없지만 이 위협을 과소평가해서는 안 된다.

즉, 최초 초안대로 리소스 블록만 지우고 별도 승인 후 `terraform apply`를
그대로 돌리면, 그 apply는 6개 리소스에 대해 **실제 destroy를 시도**한다.
GSA·WI 바인딩·custom role·key IAM binding 4개는 정상적으로 삭제되고,
key/keyring 2개는 GCP가 리소스 자체 삭제는 거부하되 **key version
파기는 실행**되며 keyring destroy 호출은 provider 에러로 이어질 수 있어
apply가 일부 실패로 종료될 위험이 있다 — "GCP 삭제 불가 = 무해"라는
전제로는 막을 수 없는 위험이다.

**정정된 접근: dev root에 `removed` 블록을 추가한다**
(`terraform/envs/dev/vault_removed.tf`, 이 PR에 포함). Terraform 1.7+
기능이라 `versions.tf`의 `required_version`을 `>= 1.7.0`으로 올렸다(CI
사용 버전은 1.13.5라 영향 없음).

```hcl
removed {
  from = google_kms_crypto_key.vault_unseal
  lifecycle { destroy = false }
}
```

`removed` 블록이 걸린 리소스는 plan 시 여전히 provider API로
refresh(현재 상태 조회)는 되지만 — 아래 "권한 순서" 절 참고 — **destroy
호출은 절대 계획되지 않는다.** apply가 실행되면 Terraform은 해당
리소스를 state에서만 제거(forget)하고 실제 GCP/K8s 객체는 그대로
둔다("Terraform will discard its tracking information for these
objects, but will not delete them" — HashiCorp 공식 동작). 6개 리소스
모두(keyring, key, GSA, WI 바인딩, custom role, key IAM binding)에 이
방식을 적용해 **destroy 시도 자체를 없앤다** — key/keyring뿐 아니라
GSA·IAM 계열 4개도 굳이 실제로 삭제할 이유가 없으므로(재현이
필요해지면 `terraform import`로 되돌릴 수 있게 남겨 둔다) 동일하게
forget 대상으로 통일했다.

이 방식은 "승인 후 실행할 state 정리 절차"(구 버전, `terraform state
rm` 수기 실행)를 **대체**한다 — `removed` 블록이 있는 코드를 apply하는
것 자체가 그 6개 항목에 한해 `state rm`과 동일한 효과를 내며, 코드로
선언돼 있으므로 실행 실수(엉뚱한 리소스를 rm하는 등) 위험도 없다. 다만
**이 removed 블록을 포함한 apply 실행 자체는 여전히 이 PR 범위 밖이며
별도 승인이 필요하다**(이슈 #478의 명시적 caution).

**이해도 확인 답변 (comment 2 — 머지 직후 drift/apply.yml 노출 창)**:
이 PR이 removed 블록까지 포함해 머지되면, 머지 직후 dev root state에는
여전히 6개 리소스가 남아 있지만 config에는 `removed` 블록이 함께
존재한다. 이 상태에서:

- **(a) `terraform-drift.yml`의 `plan -detailed-exitcode`**: 6개
  리소스에 대해 "no longer managed, will not be destroyed"로 계획되고
  `Plan: 0 add, 0 change, 0 destroy`(forget은 add/change/destroy
  카운트에 잡히지 않는다) — drift로 오탐되지 않는다.
- **(b) 누군가 `apply.yml`을 `scope: all`로 dispatch하고 승인 1회를
  받는 경우**: 그 apply는 6개 리소스를 destroy 없이 forget하고
  `roles/cloudkms.admin` IAM 바인딩만 실제로 revoke한다. "실제 GCP
  삭제는 미수행" 전제와 양립한다 — **forget은 GCP/K8s 쪽에 어떤
  API 변경도 만들지 않기 때문**(순수 state 파일 조작). 즉 이슈가 금지한
  "실제 GCP apply/state 변경"의 "GCP 변경" 부분에는 해당하지 않지만,
  "state 변경"에는 해당한다 — **그래서 이 PR은 removed 블록을 코드로만
  넣어 두고, 그 코드를 반영하는 apply 실행 자체는 별도 승인 없이는
  하지 않는다.** 승인 전에 다른 이유로 `apply.yml scope:all`이 돌더라도
  6개 리소스는 안전하게 보존되므로(위험이 "만약 승인 없이 누가 눌러도
  destroy가 아니라 forget만 일어난다"로 격하됨), 이 removed 블록
  자체가 노출 창을 닫는 조치다.

**이해도 확인 답변 (comment 3 — `github_actions.tf:252` IAM 회수 순서)**:
`roles/cloudkms.admin` 회수(`dev_apply` SA 대상)와 6개 리소스 forget은
**같은 PR·같은 apply에 함께 들어 있어 순서 문제가 생기지 않는다.**

- **`apply.yml`의 `dev_apply` SA 경로**: 그 apply 실행 자체는 시작
  시점에 이미 발급된 자격 증명(그 시점까지는 아직 `cloudkms.admin`을
  보유)으로 동작한다. plan 단계의 refresh(2개 KMS 리소스 read)는 이
  자격으로 성공하고, apply 단계에서 forget은 **provider API 호출이
  전혀 없는 순수 state 조작**이라 revoke가 같은 apply 안에서 먼저
  처리되더라도 forget에 영향이 없다. 이 apply가 끝나면 6개 리소스는
  state에서 사라지고 `cloudkms.admin`도 회수돼 있어, **다음 실행부터는
  이 SA가 KMS 권한을 아예 필요로 하지 않는다.**
- **`terraform-plan.yml`/`terraform-drift.yml`의 읽기 전용 `CI_SA`
  (`terraform-ci`) 경로**: 이 SA는 `dev_apply_roles`가 아니라 부트스트랩
  단계에서 부여된 **project-level `roles/viewer`**를 쓴다
  (`docs/TERRAFORM_BOOTSTRAP.md`). `roles/viewer`는 Cloud KMS
  read(`cloudkms.cryptoKeys.get`/`keyRings.get`)를 포함하는 범용
  읽기 role이라 `dev_apply`의 `cloudkms.admin` 회수와는 완전히
  무관하다 — 이 경로는 회수 전후 어느 시점에도 403을 받지 않는다.
- **판단**: 권한 회수와 state 분리(removed 블록 적용) 중 어느 쪽이
  먼저여야 하는지는 **의미가 없다** — `removed` 블록 방식에서는 forget이
  provider 권한을 요구하지 않으므로 같은 apply에서 동시에 처리해도
  안전하다. 순서가 실제로 문제가 되는 경우는 오직 "블록만 지우고
  destroy를 실제로 시도하는" 원안 방식뿐이었다(그 경우 destroy에
  cloudkms 쓰기 권한이 필요했을 것이므로, 권한을 먼저 회수하면 오히려
  destroy가 403으로 막혀 apply가 실패했을 것이다) — removed 블록 채택이
  이 순서 문제 자체를 없앴다.

## 완료 조건

- [ ] `terraform/envs/dev/vault.tf` 삭제
- [ ] `variables.tf`/`locals.tf`/`outputs.tf`의 Vault 전용 항목 제거
- [ ] `github_actions.tf`의 `roles/cloudkms.admin` 제거
- [ ] `versions.tf`의 `required_version`을 `>= 1.7.0`으로 상향
- [ ] `vault_removed.tf`에 6개 리소스 `removed` 블록 추가(destroy 없이
      forget)
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
      6개 리소스는 forget으로만 나오고 destroy 0, `roles/cloudkms.admin`
      IAM 바인딩 1개만 실제 destroy)
- [ ] KMS key ring/crypto key destroy가 CryptoKeyVersion 파기를 실제로
      예약한다는 사실과, `removed` 블록으로 그 위험을 없앤 이유를 문서에
      기록

## 롤백

- 코드 변경만 되돌리려면 이 PR을 revert한다 — live 리소스는 건드리지
  않았고, `removed` 블록을 포함한 apply도 아직 실행되지 않았으므로
  (별도 승인 대기 중) state에도 영향이 없다. 즉시 원상 복구된다.
- 승인 후 `removed` 블록 apply까지 실행했다면(dev root 6개 리소스
  forget), `vault.tf`를 git history에서 복원하고 `terraform import`로
  6개 리소스를 다시 state에 넣을 수 있다(live 리소스는 forget으로는
  전혀 건드리지 않았으므로 import 대상 자체는 그대로 존재한다).
- 승인 후 vault-k8s state rm까지 실행했다면, `terraform/admin/vault-k8s/`를 git
  history에서 복원하고 `terraform import`로 4개 리소스를 다시 state에
  넣을 수 있다(단, live 리소스가 이미 없으므로 `helm_release`/`namespace`/
  `network_policy`는 import 대상 자체가 없다 — 실질적으로는 재설치가
  필요하며, 이는 이 PR의 롤백 범위를 넘는다).
