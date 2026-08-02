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

- dev root 코드 제거(`vault.tf`, `variables.tf`/`locals.tf`/`outputs.tf`의
  Vault 전용 항목 — `github_actions.tf`의 `roles/cloudkms.admin`은 영구
  유지, 아래 참조) + dev root state에 남는 6개 리소스 중 key ring/crypto
  key 2개는 `kms_vault_orphan.tf`에 일반 `resource` 블록으로 영구 유지
  (rotation만 제거, `prevent_destroy` 적용 — destroy도 forget도 아님),
  나머지 4개(GSA/WI 바인딩/custom role/key IAM binding)는 일반 destroy
  대상으로 남김(아래 "state 분리 전략" 참조)
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

dev root 잔여 6개는 `kms_vault_orphan.tf` 유지 2개(rotation 제거
in-place update) + 일반 destroy 4개로 처리한다(최종 전략, 아래
"dev root state 분리 전략" 절 참조 — `removed` 블록은 채택하지 않았고
현재 코드에도 없다). 이 절차는 `terraform/admin/vault-k8s/`
root(디렉터리 자체가 이 PR로 삭제돼 `removed` 블록을 넣을 config가
없는 root)의 4개 K8s 리소스 전용이다(claude-review 10차 지적 — 이전
서술이 "removed 블록"·"6개"로 남아 있어 같은 문서의 최종 결정과
충돌했다).

**최초 초안의 절차는 그대로 실행하면 동작하지 않는다**(claude-review
지적, 2026-08-02 2차). 삭제된 `terraform/admin/vault-k8s/versions.tf`의
backend는 partial 구성(`backend "gcs" {}`)이라 bucket/prefix가 코드에
없고, `scripts/terraform-env`가 `config/environments/dev/environment.yaml`의
`state.roots["terraform/admin/vault-k8s"]`에서 생성하는
`-backend-config` 플래그로만 주입된다. `/tmp` 임시 디렉터리에서 맨
`terraform init`을 실행하면 backend 좌표가 없어 실패하거나 대화형
프롬프트로 빠진다. `main.tf`만 복원하는 것도 불충분하다 —
`versions.tf`(provider/backend 선언)와 `variables.tf`가 함께 있어야
`init`이 된다.

저장소 관례에 맞는 절차: 임시 디렉터리 대신 리포지토리 경로에 그대로
복원하고 `scripts/terraform-env` 진입점을 쓴다.

```bash
# 1) 이 PR 머지 커밋의 부모(vault-k8s가 아직 있던 마지막 커밋)에서
#    디렉터리 전체를 리포지토리 경로에 그대로 복원
git checkout <이 PR 머지 커밋의 부모> -- terraform/admin/vault-k8s

# 2) 표준 wrapper로 init(-reconfigure로 이전 backend 캐시 무시)
scripts/terraform-env --environment dev --root terraform/admin/vault-k8s \
  init -reconfigure

# 3) state rm 4건
scripts/terraform-env --environment dev --root terraform/admin/vault-k8s \
  state rm kubernetes_namespace_v1.vault
scripts/terraform-env --environment dev --root terraform/admin/vault-k8s \
  state rm kubernetes_network_policy_v1.vault_ingress
scripts/terraform-env --environment dev --root terraform/admin/vault-k8s \
  state rm kubernetes_network_policy_v1.vault_egress
scripts/terraform-env --environment dev --root terraform/admin/vault-k8s \
  state rm helm_release.vault
scripts/terraform-env --environment dev --root terraform/admin/vault-k8s \
  state list   # data source 2개만 남고 비어 있어야 함

# 4) 복원한 디렉터리를 index와 워킹트리 양쪽에서 제거해 main 트리를 원상 복구
#    (이 PR 머지 후 HEAD에는 이 경로가 이미 없으므로 `git checkout HEAD --
#    terraform/admin/vault-k8s`는 pathspec 오류로 실패한다. 1)단계의
#    `git checkout <부모> -- ...`는 파일을 index에 staged 상태로 올려두므로
#    working tree만 지우는 것으로는 불충분하다.)
git restore --staged terraform/admin/vault-k8s
rm -rf terraform/admin/vault-k8s
git status --short terraform/admin   # 아무것도 남지 않아야 함
```

state가 비면 원격 GCS state 객체도 정리 대상이나, 실제 삭제(버킷 오브젝트
제거)는 별도로 재확인 후 수행한다.

```bash
# 5) state 정리 완료 후, 카탈로그 3곳에서 vault-k8s 항목 제거(아래 설명 참조)
#    - config/environments/dev/environment.yaml (state.roots)
#    - scripts/environment_catalog.rb (TERRAFORM_ROOTS, ROOT_VARIABLE_KEYS)
#    - scripts/test-environment-catalog.rb (VALID_CATALOG 픽스처)
#    제거 후 로컬 검증:
ruby scripts/test-environment-catalog.rb
```

**카탈로그에 `vault-k8s` 항목이 남아 있는 이유**: `scripts/environment_catalog.rb`의
`TERRAFORM_ROOTS`/`ROOT_VARIABLE_KEYS`와
`config/environments/dev/environment.yaml`의 `state.roots`에는 root
디렉터리가 삭제된 뒤에도 `terraform/admin/vault-k8s` 항목이 남아 있다.
이는 실수가 아니라 **의도적**이다 — 위 절차가 `scripts/terraform-env`의
backend-config 생성에 의존하므로, state 정리가 끝나기 전까지 카탈로그
항목을 지우면 이 복구 절차 자체가 동작하지 않는다. 두 파일 모두에
"state 정리 완료 전까지 유지" 주석을 남겨 다음 정리 작업에서 실수로
지워지는 것을 막는다.

**이 항목이 남아 있는 동안 CI가 안전한 이유(claude-review 10차 지적)**:
`.github/workflows/apply.yml`의 `ADMIN_ROOTS`는 vault-k8s를 정적으로
제외한 목록이라(같은 파일 주석 참조) 이 카탈로그 항목이 있어도 apply
job이 이 root를 순회하지 않는다. `.github/workflows/lint.yml`이 실행하는
`scripts/test-environment-catalog.rb`는 실 디렉터리가 아니라 임시
디렉터리에 쓴 합성 YAML로 카탈로그 로딩 로직만 검증하므로(`terraform
init`을 호출하지 않음), 이 항목의 존재 자체로 CI가 실 `vault-k8s`
디렉터리를 건드릴 경로는 없다. 위험은 사람이 이 root를 대상으로 CLI를
직접 실행할 때만 있고, 그 경로는 `environment.yaml`의 경고 주석과 이
절의 절차로 방어한다. **추적**: 카탈로그 3곳(위 5단계)을 지우는 작업은
이 문서가 그 자체로 체크리스트 역할을 한다 — state 정리(1~4단계) 완료
직후 5단계를 실행하는 것으로 별도 이슈 없이 이 절차 안에서 완결한다.

## dev root state 분리 전략 — `removed` 블록에서 config 유지(prevent_destroy)로 (claude-review 지적 반영)

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

**2차 정정(`removed` 블록/forget) — 이후 3차 정정으로 대체됨**: 한동안은
`terraform/envs/dev/vault_removed.tf`에 key ring/crypto key 2개를
`removed { lifecycle { destroy = false } }`로 forget하는 접근을 취했다
(Terraform 1.7+ 기능이라 `versions.tf`의 `required_version`도 일시
`>= 1.7.0`으로 올렸었다). 이 방식은 destroy 위험은 없앴지만, claude-review
6차 지적으로 다음 문제가 드러났다 — **forget된 리소스는 state·config·
`terraform-drift.yml` 어디에도 남지 않는다.** 즉 누가 이 key에 IAM을
다시 붙이거나 rotation을 재활성화해도 저장소의 어떤 장치도 감지하지
못한다. 게다가 forget과 별개로 "forget **전에** 수동으로 `gcloud kms
keys update --remove-rotation-schedule`을 실행해야 한다"는 절차가
필요했는데, 이 수동 단계 자체가 CI/코드로 강제되지 않아 운영자가
건너뛸 수 있는 창이었다.

**3차 정정(현재 채택) — `removed` 대신 config 유지 + `prevent_destroy`**:
KMS key ring/crypto key는 애초에 GCP에서 삭제가 불가능한 리소스이므로
(keyring은 삭제 API 자체가 없고, crypto key destroy는 리소스 삭제는
거부되지만 CryptoKeyVersion 파기는 예약한다), Terraform 관리 밖으로
내보낼 필요 자체가 없다 — 리소스 블록을 `terraform/envs/dev/
kms_vault_orphan.tf`에 그대로 남기고 `rotation_period`만 제거한다.

```hcl
resource "google_kms_crypto_key" "vault_unseal" {
  name     = "vault-unseal"
  key_ring = google_kms_key_ring.vault.id
  # rotation_period 없음 — Vault 영구 폐기로 회전 불필요

  lifecycle {
    prevent_destroy = true
  }
}
```

`removed` 대비 이점:

- **drift 감지 범위 유지**: config에 리소스 블록이 계속 존재하므로
  `terraform-drift.yml`이 이 2개를 계속 refresh·비교한다 — 누군가 live에서
  IAM을 재바인딩하거나 rotation을 재활성화하면 다음 drift plan에 잡힌다.
  forget 대상이었다면 이 감지 범위 밖으로 완전히 빠졌다.
- **수동 절차 제거**: rotation 해제가 코드에 선언되어 승인된 apply
  한 번(in-place update)으로 끝난다 — "forget 전에 수동으로
  `gcloud kms keys update --remove-rotation-schedule`을 실행해야 한다"는
  운영자 판단에 의존하는 절차가 사라진다.
- **`prevent_destroy`가 실제로 작동하는 상태로 복원**: `removed`
  블록이었을 때는 "config에 없으면 lifecycle 검사가 실행되지 않는다"는
  구멍이 있었다(위 1번 참조). config에 블록이 존재하는 지금은
  `prevent_destroy`가 정상 작동해, 이후 누군가 실수로 이 파일에서
  블록을 지우고 apply해도 Terraform이 destroy를 막는다.

**`removed`/config-유지 대상은 6개 전부가 아니라 key ring/crypto key
2개로 한정한다**(claude-review 재지적 반영, 2026-08-02 2차, 3차 정정
이후에도 유효). 최초 정정에서는 GSA·WI 바인딩·custom role·key IAM
binding 4개도 "재현이 필요해지면 `terraform import`로 되돌릴 수 있게"
forget으로 통일했으나, Vault는 #412에서 **영구 폐기**된 경로라 재현
시나리오 자체가 없다. 나머지 4개(GSA, WI 바인딩, custom role, key IAM
binding)는 destroy해도 GCP 쪽에 파기 예약 같은 비가역 부작용이 없고
git history로 언제든 재생성 가능하다. 이 4개를 config에 남기거나
forget으로 두면 Terraform 관리 밖에서 계속 살아 있는 IAM 바인딩(예:
`vault` namespace의 `vault` KSA가 여전히 KMS decrypt 가능한 GSA를
impersonate할 수 있는 Workload Identity 바인딩)이 무기한 남으므로,
최소 권한 원칙에서는 config 유지보다 destroy가 맞다. 그래서
`terraform/envs/dev/kms_vault_orphan.tf`에는 key ring/crypto key 2개만
남기고, 나머지 4개는 그대로 두어(=이미 `vault.tf` 삭제로 config에서
빠짐) 승인 후 apply 시 정상적으로 destroy되게 한다.

이 방식은 "승인 후 실행할 state 정리 절차"(구 버전, `terraform state
rm` 수기 실행)를 KMS key ring/crypto key 2개에 한해 **대체**한다 —
`kms_vault_orphan.tf`를 apply하는 것 자체가 rotation 제거를 코드로
반영하며, 이후로도 계속 관리 대상으로 남는다(state에서 완전히
빠지지 않음 — forget과의 핵심 차이). 나머지 4개는 일반적인 코드 삭제 →
apply 시 destroy 흐름을 그대로 따른다. **이 apply 실행 자체는 여전히 이
PR 범위 밖이며 별도 승인이 필요하다**(이슈 #478의 명시적 caution) —
승인 후 apply가 실행되면 plan은 key ring/crypto key 2개의 rotation
제거(in-place update, 최초 1회) + destroy 4건(GSA·WI 바인딩·custom
role·key IAM binding)으로 나타난다. `roles/cloudkms.admin`은 이
apply에 포함되지 않는다(회수하지 않는다) — 이유는 아래 "comment 3"
참조.

**이해도 확인 답변 (comment 2, 3차 정정 — 머지 직후 drift/apply.yml 노출
창, config 유지 설계로 갱신)**: 이 PR이 머지되면 dev root state에는
여전히 6개 리소스가 남아 있고, config에는 key ring/crypto key 2개에
대한 **리소스 블록(`kms_vault_orphan.tf`, rotation_period 없음)** +
나머지 4개(GSA·WI 바인딩·custom role·key IAM binding)에 대한 **config
자체 부재**(= 실제 destroy 대상)가 함께 존재한다. 이 상태에서:

- **(a) `terraform-drift.yml`의 `plan -detailed-exitcode`**: key
  ring/crypto key 2개 중 crypto key는 rotation_period 제거로 인한
  **in-place update 1건**으로 계획되고(keyring은 속성 변경이 없어
  no-op), 나머지 4개는 실제 destroy 대상으로 계획된다. 즉
  `Plan: 0 to add, 1 to change, 4 to destroy.`가 되어
  `-detailed-exitcode`는 `2`를 반환하고, `terraform-drift.yml`은 승인
  apply가 끝날 때까지 **매일 09:23 KST마다 `[DRIFT]` 이슈를
  생성/코멘트한다.** 이는 오탐이 아니라 "승인 대기 중인 진짜
  변경사항이 있다"는 정확한 신호이므로, 머지 직후 발생하는 첫
  `[DRIFT]` 이슈에는 이 PR을 참조하는 코멘트를 남겨 원인이 #478 승인
  대기임을 명시한다(완료 조건에 반영). `removed` 블록을 쓰지 않게
  되면서 forget 헤더(`will no longer be managed by Terraform`)는 이
  PR 자체에서는 더 이상 나타나지 않는다 — 다만 이 패턴을 인식하는
  allowlist 정규식 fix는 저장소의 다른 root가 향후 `removed` 블록을
  쓸 때를 대비해 그대로 유지한다(`.github/workflows/terraform-drift.yml`
  등 참조).
- **(b) 누군가 `apply.yml`을 `scope: all`로 dispatch하고 승인 1회를
  받는 경우**: 그 apply는 key ring/crypto key 2개의 rotation을
  제거하고, GSA·WI 바인딩·custom role·key IAM binding 4개를 실제로
  destroy한다(`roles/cloudkms.admin`은 이 PR에서 회수하지 않고 이후에도
  회수 계획이 없다 — 아래 comment 3 참조). "실제 GCP 삭제는 미수행"
  전제와 양립한다 — **이 PR 자체는 코드만 바꿀 뿐 apply를 실행하지
  않으므로**, 승인 없이 이 코드가 반영되는 일은 없다. 다만 승인 전에
  다른 이유로 `apply.yml scope:all`이 돌면 이 4개 리소스는 그대로
  destroy 계획에 포함되므로(예상치 못한 승인 클릭 방지가 여전히 유일한
  방어선), 승인 게이트 자체를 신뢰하는 전제는 변하지 않는다. 이는
  이 PR에 국한된 위험이 아니라 이 저장소의 승인 apply 워크플로 전반이
  가진 일반적 특성(머지된 코드는 다음 apply 때 함께 반영됨)이라, 이
  PR 범위에서 추가 방어 장치를 만들지는 않는다 — 병합 후 가능한 한
  빨리 승인 apply를 실행해 이 창을 줄이는 것을 완료 조건에 반영한다.

**이해도 확인 답변 (comment 3, 2차 정정 — `github_actions.tf:252` IAM 회수 순서)**:
1차 답변은 6개 전부가 forget이라는 전제 위에서 "순서 문제가 없다"고
결론 냈으나, 4개를 실제 destroy로 바꾸면서(comment 4 설계 변경) 새로운
순서 위험이 드러났다 — 그래서 **이 PR은 `roles/cloudkms.admin`을
`dev_apply` SA에서 회수하지 않는다**(이전 초안과 달리 되돌렸다).

- **위험**: `google_kms_crypto_key_iam_member.vault_unseal`을 destroy
  하려면 해당 crypto key에 대한 `cloudkms.cryptoKeys.setIamPolicy`
  권한이 필요하고, `dev_apply_roles` 중 이 권한을 포함하는 role은
  `cloudkms.admin`뿐이다(`resourcemanager.projectIamAdmin`은 project
  레벨 IAM만 다루고 KMS 리소스 레벨 IAM은 포함하지 않는다). 같은 apply
  안에서 이 role을 회수하는 것과 이 리소스를 destroy하는 것을 함께
  두면, 두 작업은 Terraform 리소스 그래프상 서로 의존관계가 없는
  독립 노드라 **병렬 실행 순서가 보장되지 않는다** — 회수가 먼저
  처리되면 destroy 호출이 403으로 실패할 수 있다.
  - **그래프 독립 근거**: `google_project_iam_member.dev_apply_roles
    ["roles/cloudkms.admin"]`와 `google_kms_crypto_key_iam_member.
    vault_unseal`은 서로의 속성값을 참조하지 않는다 — 전자는
    `dev_apply` SA의 email과 role 문자열만, 후자는 crypto key
    주소와 GSA 문자열만 쓴다. Terraform은 리소스 간 의존 관계를
    config의 참조식(하나가 다른 하나의 output/attribute를 쓰는지)과
    명시적 `depends_on`으로만 만든다 — 값이 겹치지 않고 `depends_on`도
    없으므로 그래프 상 두 노드를 잇는 edge가 아예 존재하지 않고,
    Terraform은 기본적으로 독립 노드를 병렬로 처리한다(worker pool
    동시 실행, 기본 동시성 10).
  - **실행 주체 자신이 잃는 권한이라는 점의 영향**: 이 apply를 수행하는
    `dev_apply` SA 자체가 `cloudkms.admin` 회수 대상이다. WIF 인증은
    job 시작 시 `google-github-actions/auth@v2`로 **한 번** 단기
    OAuth 토큰을 발급받지만, GCP IAM 권한 검사는 토큰 발급 시점에
    캐시된 권한이 아니라 **API 호출 시점의 현재 IAM 정책을 그때그때
    조회**해 판정한다(IAM 변경 전파는 보통 초 단위~수십 초, 최대
    수 분). 즉 같은 apply 안에서 role 회수 API 호출이 먼저 성공해
    전파까지 끝난 뒤 KMS IAM member destroy 호출이 나중에 나가면,
    토큰 자체는 여전히 유효해도 그 시점의 IAM 정책에는 이미
    `cloudkms.admin`이 없어 403을 받는다 — "토큰이 살아있으니
    안전하다"는 보호는 없다.
- **결정(3차 정정)**: `roles/cloudkms.admin`은 이번 PR에서 유지하고
  (코드에 남겨 둠, `github_actions.tf`에 사유 주석 추가) **영구적으로
  회수하지 않는다.** 1차/2차 정정 시점에는 "4개 destroy가 반영된 뒤
  더 이상 필요 없음을 확인하고 별도 후속 PR에서 회수"할 계획이었으나,
  `removed` 블록을 config 유지(`kms_vault_orphan.tf`,
  `prevent_destroy`)로 바꾸면서 전제가 달라졌다 — key ring/crypto key
  2개가 이제 **영구히** Terraform 관리 대상으로 남으므로, drift
  감지 refresh와 향후 발생할 수 있는 변경(예: rotation 재도입, IAM
  재바인딩 정리)에 이 role이 계속 필요하다. 즉 "권한 회수 후속 PR"
  자체가 없어졌으므로, comment 9가 다루던 "회수 후속 PR이 승인 apply보다
  먼저 머지되는 순서 위험"도 함께 사라졌다(아래 comment 9 갱신 참조).
- **`terraform-plan.yml`/`terraform-drift.yml`의 읽기 전용 `CI_SA`
  (`terraform-ci`) 경로**: 이 SA는 `dev_apply_roles`가 아니라 부트스트랩
  단계에서 부여된 **project-level `roles/viewer`**를 쓴다
  (`docs/TERRAFORM_BOOTSTRAP.md`). `roles/viewer`는 Cloud KMS
  read(`cloudkms.cryptoKeys.get`/`keyRings.get`)를 포함하는 범용
  읽기 role이라 `dev_apply`의 `cloudkms.admin` 회수와는 완전히
  무관하다 — 이 경로는 회수 전후 어느 시점에도 403을 받지 않는다.
- **판단**: 4개를 실제 destroy로 바꾼 이상 그중 key IAM binding 1개는
  `cloudkms.admin`을 요구하므로, 애초에 "권한 회수와 destroy를 같은
  apply에 함께 넣지 않는다"가 유일하게 안전한 순서였다. 이번 PR은 그
  회수 자체를 **하지 않기로** 설계를 바꿔 이 순서 요구를 원천적으로
  제거했다(회피가 아니라 제거) — key ring/crypto key 2개를 영구
  관리하려면 어차피 이 role이 계속 필요하므로, 회수 계획을 두는 것
  자체가 더 이상 목표와 맞지 않는다.

**이해도 확인 답변 (comment 4 — `vault_removed.tf`의 수명주기, 3차
정정으로 대부분 해소됨)**: `removed` 블록을 config 유지로 바꾸면서 이
질문의 전제(forget 후 별도 삭제 후속 PR이 필요하다)가 사라졌다 —
`kms_vault_orphan.tf`는 **영구히 남는 파일**이다(삭제 예정 없음). 그래도
남은 부분에 답한다.

1. **forget 후 파일 삭제 후속 PR**: 더 이상 필요 없다 — forget을 하지
   않으므로 "forget이 끝난 뒤 이 파일을 지운다"는 절차 자체가 없어졌다.
   `kms_vault_orphan.tf`는 이 PR 이후에도 계속 dev root의 정상 config로
   남는다.
2. **`vault.tf`가 나중에 복원되는데 `kms_vault_orphan.tf`가 남아 있는
   경우**: 같은 리소스 주소(`google_kms_key_ring.vault`,
   `google_kms_crypto_key.vault_unseal`)가 두 파일에 동시에 `resource`
   블록으로 정의되면 Terraform은 `validate` 단계에서 "Duplicate
   resource" 에러를 즉시 낸다. 즉 이 상황도 조용히 잘못된 상태로
   넘어가지 않고 명시적으로 막힌다 — Vault를 다시 도입하려는 작업자는
   `kms_vault_orphan.tf`의 해당 블록을 `vault.tf` 쪽으로 옮기거나
   삭제해야 하며, CI `validate`가 이를 강제한다.

**이해도 확인 답변 (comment 5 — 잔여 IAM 권한 경계, `github_actions.tf:252`)**:
이 코멘트는 6개 전부를 forget으로 통일했던 2차 정정 설계를 지적한
것으로, comment 3의 설계 변경(4개는 destroy로 전환, 위 참조)이 사실상의
답이다. 지적된 두 질문에 대해서도 명시적으로 답한다.

1. **승인 apply 전까지의 잔여 권한 경계**: `vault` namespace의 `vault` KSA가
   Workload Identity로 impersonate하는 `vault` GSA에는
   `roles/cloudkms.cryptoKeyEncrypterDecrypter`(`vault.tf` 삭제 전
   `google_kms_crypto_key_iam_member.vault_unseal`이 부여하던 권한)가
   남아 있어, 그 GSA를 통해 `vault_unseal` crypto key로 encrypt/decrypt
   호출은 가능하다. 다만 이 namespace/KSA 자체가 dev GKE에 존재하지
   않으므로(live 확인 완료, 배경 절 참조) 실제로 이 경로를 쓸 수 있는
   주체는 없다.
2. **정리 주체·권한**: 4개를 destroy로 전환했으므로, 승인된 apply가
   `dev_apply` SA로 한 번에 정리한다 — 별도 정리 주체나 후속 작업이
   필요 없다(이번 PR과 같은 승인 경로).

**이해도 확인 답변 (comment 6 — config 유지 리소스와 destroy가 같은
apply에 있을 때 순서, `kms_vault_orphan.tf`. 3차 정정으로 "forget"을
"rotation 제거 update"로 갱신)**:
같은 apply 안에서 `google_kms_crypto_key.vault_unseal`은 rotation
제거 update를 받고(state에서 사라지지 않고 계속 남음), 그 key를
참조하던 `google_kms_crypto_key_iam_member.vault_unseal`은 실제
destroy된다. 두 동작의 순서는 결과에 영향을 주지 않는다 — 이유는
"어느 쪽이 먼저 실행되는지"가 아니라 "destroy가 값을 어디서 가져오는지"에
있다.

- `google_kms_crypto_key_iam_member.vault_unseal`의 `crypto_key_id`
  값은 **그 리소스 자신의 state 항목에 생성 시점에 이미 값으로
  저장돼 있다**(참조가 아니라 문자열 값). config에서 `vault.tf`가
  통째로 삭제된 이상 이 리소스는 config에 존재하지 않으므로, destroy
  계획은 config의 참조식을 다시 평가하지 않고 **state에 저장된 값을
  그대로 읽어 GCP API 호출을 구성**한다. 즉 destroy 시점에 crypto key
  리소스가 아직 update 전인지 update 후인지는 이 destroy 호출과
  무관하다 — crypto key 쪽 update는 IAM member 쪽 값을 훼손하거나
  무효화할 수도 없다(3차 정정으로 crypto key는 애초에 forget되지 않고
  계속 state에 남으므로, 이 논점은 오히려 더 명확해졌다).
- 로컬에서 `null_resource` 2개(B가 A를 참조하는 trigger를 가짐)로
  같은 상황을 재현해 실측했다: A를 `removed`(destroy=false)로,
  B를 config에서 완전히 제거(=destroy 대상)해 같은 apply를 실행하면
  `Plan: 0 to add, 0 to change, 1 to destroy.`로 함께 계획되고 apply는
  `Apply complete! Resources: 0 added, 0 changed, 1 destroyed.`로
  오류 없이 끝난다. B의 destroy diff에는 `- "a_id" = "<A의 id
  값>"`이 그대로 찍히는데, 이 값은 B 자신의 state에서 나온 것이지 A를
  다시 조회해서 나온 값이 아니다 — 실제 시나리오의 `crypto_key_id`와
  동일한 성격이다.
- 그래도 Terraform의 그래프 빌더는 state에 기록된 의존 관계(B가 A를
  참조해 생성됐다는 이력)를 이용해 일반적으로 의존하는 쪽(B)을 먼저
  처리하고 의존 대상(A)의 forget/destroy를 나중에 처리하는 순서를
  택하는 경향이 있지만, 이는 안전을 더 강화하는 부수 효과일 뿐 이
  케이스의 정합성이 그 순서에 의존하지는 않는다 — 반대 순서였어도
  결과는 같다.
- **apply 후 검증 방법**: `scripts/terraform-env --environment dev
  --root terraform/envs/dev state list | grep vault`로 확인한다 —
  성공한 apply라면 이 grep은 빈 결과여야 한다(key ring/crypto key
  2개는 forget으로 state에서 빠지고, `google_kms_crypto_key_iam_
  member.vault_unseal`을 포함한 나머지 4개는 destroy로 state에서
  빠지므로). `terraform apply`는 애초에 `Apply complete!` 뒤에
  added/changed/destroyed 개수를 출력하고 하나라도 실패하면 0이 아닌
  종료 코드로 끝나 `apply.yml`의 "Apply dev root" 스텝이 그 자리에서
  실패를 잡아낸다(comment 9 (c) 참조) — 즉 apply 자체가 성공 종료했다면
  이 순서 문제로 인한 부분 실패는 이미 없었다는 뜻이고, `state list`는
  그 결과를 사후에 다시 확인하는 용도다.

**이해도 확인 답변 (comment 7 — 잔여 3개 destroy의 권한 커버리지와 custom
role 재생성, `github_actions.tf:255`)**:
지적된 주석은 `google_kms_crypto_key_iam_member.vault_unseal` 1개에
필요한 권한만 설명한다. 나머지 3개는 이미 `dev_apply_roles`에 있는
**다른** role로 커버되므로 `cloudkms.admin`과는 무관하다.

- `google_service_account.vault`(GSA) destroy → `roles/iam.serviceAccountAdmin`
  (`github_actions.tf:241`, "SA 15종 + SA IAM"이라는 기존 주석이 이미
  이 용도를 포함).
- `google_service_account_iam_member.vault_wi`(WI 바인딩) destroy →
  동일하게 `roles/iam.serviceAccountAdmin`(SA IAM 멤버 관리 포함).
- `google_project_iam_custom_role.vault_unseal`(custom role
  `vaultUnsealKmsAccess`) destroy → `roles/iam.roleAdmin`
  (`github_actions.tf:244`, "custom role"이라는 기존 주석). 이 role은
  애초에 `vault.tf`가 이 custom role을 **생성**할 때도 필요했던
  권한이므로 원래부터 있었다 — `cloudkms.admin`을 새로 추가한 이유와는
  무관하다.

role ID의 즉시 소멸 여부: **아니다.** GCP IAM custom role의 `delete`는
soft delete다 — 삭제 직후 role은 `DELETED` 상태로 전환되지만 **7일간
보존**되며, 그 7일 안에는 같은 `role_id`(`vaultUnsealKmsAccess`)로 새
custom role을 만들 수 없다(API가 "role already exists" 계열 오류를
반환한다). `gcloud iam roles undelete --project=<PROJECT_ID>
vaultUnsealKmsAccess`로 7일 안에 되살릴 수도 있다. **정정(claude-review
9차 지적)**: "7일이 지나면 완전히 삭제되고 그때부터 같은 ID를 재사용할
수 있다"는 이전 서술은 부정확했다 — GCP는 영구 삭제(7일 경과) 후에도
같은 `role_id` 재사용을 최대 37일(삭제 후 7~37일 구간)까지 막을 수
있다. 안전한 선택지는 (a) 7일 안에 undelete, (b) 최대 37일을 기다린
뒤 재생성, (c) 다른 `role_id`로 새로 만드는 것뿐이다.

이는 아래 "롤백" 절의 "`vault.tf`를 복원해 `terraform apply`로
재생성" 서술에 구멍이 있었다는 뜻이다 — **destroy 후 7일 이내에** 그냥
`terraform apply`를 돌리면 custom role 생성 단계에서 오류가 난다.
"롤백" 절을 아래와 같이 정정한다(체크리스트에도 반영).

**이해도 확인 답변 (comment 8 — `vault_removed.tf` 삭제 후속 PR이 승인
apply보다 먼저 머지되는 경우, `vault_removed.tf:19`. 3차 정정으로 moot)**:
이 코멘트가 지적한 위험은 "forget 성공을 확인한 뒤 `vault_removed.tf`를
지우는 후속 PR"과 "승인 apply" 사이의 순서가 강제되지 않는다는 것이었다.
3차 정정으로 `vault_removed.tf`는 애초에 존재하지 않고(→
`kms_vault_orphan.tf`), 그 파일을 지우는 후속 PR 자체를 계획하지 않는다
— `kms_vault_orphan.tf`는 key ring/crypto key가 GCP에 살아 있는 한
영구히 config에 남아 `prevent_destroy`로 보호한다(comment 4 3차 정정
참조). 따라서 이 코멘트가 우려한 "정리 후속 PR이 승인 apply보다 먼저
머지돼 의도치 않은 destroy가 계획되는" 시나리오 자체가 발생할 수 없다.

**이해도 확인 답변 (comment 9 — `roles/cloudkms.admin` 회수 후속 PR이
승인 apply보다 먼저 머지되는 경우, `github_actions.tf:255`. 3차 정정으로
moot)**:
이 코멘트가 분석한 403 순서 위험(role 회수가 destroy보다 먼저 반영되면
apply가 부분 실패로 중단)은 "destroy 완료 확인 후 role을 회수하는 후속
PR"의 존재를 전제로 한다. comment 3의 3차 정정으로 `roles/cloudkms.admin`은
`kms_vault_orphan.tf`의 2개 리소스를 계속 관리(drift 감지, 향후
rotation/IAM 변경)하는 데 상시 필요해 **회수하지 않기로** 결정했으므로,
그런 후속 PR 자체가 존재하지 않는다 — 이 코멘트의 (a)~(c) 순서 분석
전체가 전제 소멸로 moot됐다.

## claude-review 7차 지적 (2026-08-02, PR #500)

3차 정정(comment 1~9) 반영 후 재요청한 리뷰에서 5건이 새로 나왔다. 이번
회차는 추론만으로 답하지 않고, 실제 provider 소스와 workflow 인증 흐름을
직접 확인해 답했다.

**이해도 확인 답변 (comment 1 — `kms_vault_orphan.tf`의 rotation 제거가
정말로 `--remove-rotation-schedule`와 동일하게 GCP 쪽 스케줄을 해제하는지
근거 부족)**: `terraform-provider-google`의
`resource_kms_crypto_key.go`(`resourceKMSCryptoKeyUpdate`) 소스를 직접
가져와 확인했다. `rotation_period`가 config에서 사라지면
`d.HasChange("rotation_period")`가 true가 되어 `updateMask`에
`rotationPeriod,nextRotationTime` 두 필드가 포함되고, 새 값이 빈 값이라
`obj["rotationPeriod"]`는 요청 바디에 아예 채워지지 않는다("필드는
updateMask에, 바디에는 없음" 조합은 GCP PATCH의 표준 "필드 삭제" 문법) —
`gcloud kms keys update --remove-rotation-schedule`와 기능적으로 동일하다.
또한 `next_rotation_time`은 이 리소스의 Terraform schema 속성 자체가
아니라 updateMask 구성에만 등장하므로, apply 후 그 값이 stale computed
diff로 남을 위험도 없다. `kms_vault_orphan.tf`의 주석을 이 근거로 갱신했다.

**이해도 확인 답변 (comment 2 — `github_actions.tf:255`의
`roles/cloudkms.admin` 영구 유지 근거로 든 "drift 감지 refresh"가 실제
workflow 인증과 맞는지)**: 맞지 않았다. `terraform-drift.yml`과
`terraform-plan.yml`은 둘 다 `CI_SA_EMAIL`(project-level `roles/viewer`,
읽기 전용)로 인증해 plan만 수행하며 `dev_apply` SA를 쓰지 않는다.
`apply.yml`의 "Apply dev root" 스텝만 `DEV_APPLY_SA_EMAIL`로 인증하고,
그마저도 새로 plan/refresh하지 않고 GCS에서 내려받은 저장된 plan
바이너리(`terraform apply tfplan.bin`)를 그대로 적용한다. 따라서
`dev_apply`의 `roles/cloudkms.admin`이 필요한 진짜 이유는 "drift 감지"가
아니라 "`kms_vault_orphan.tf`의 2개 리소스를 다루는 모든 dev root
apply(이번 승인 apply 포함)를 `dev_apply` SA가 실행하기 때문"이다.
`github_actions.tf`의 해당 주석을 이 근거로 정정했다.

**이해도 확인 답변 (comment 3 — `will no longer be managed by Terraform`
allowlist 패턴이 정말 "미래 대비"인지, 어디서도 검증 불가능한 죽은
코드는 아닌지)**: `grep -rln "^\s*removed\s*{" terraform/`로 저장소
전체를 훑어본 결과, 이 패턴은 가정이 아니라 **이미 실제로 존재**했다 —
`terraform/admin/monitoring-k8s/main.tf`(`helm_release.
kube_prometheus_stack`)와 `terraform/admin/argo-rollouts-k8s/main.tf`
(`helm_release.argo_rollouts`)에 기존 `removed { lifecycle { destroy =
false } }` 블록이 있다. 그런데 이 두 root는 `apply.yml`의
`ADMIN_ROOTS`에는 포함되지만, `terraform-drift.yml`/`terraform-plan.yml`
/`apply.yml`의 **dev-root** plan 스텝은 각 workflow 헤더 주석대로 admin
root를 명시적으로 제외한다. 즉 이 3곳(정확히는 4곳 — `apply.yml`은
dev-root 스텝과 admin-root 스텝이 분리)에서 패턴을 두는 게 아니라, 이
패턴이 실제로 exercise되는 유일한 지점인 `apply.yml`의 admin-root plan
스텝 1곳에만 남기고 나머지 3곳은 되돌렸다 — "미래 대비"라는 이전 근거는
검증 불가능한 죽은 코드를 정당화하는 부정확한 서술이었다. `완료 조건`의
해당 항목도 이 결정에 맞춰 정정했다(아래).

**이해도 확인 답변 (comment 4 — rotation 제거가 "그 즉시 과금이 멈춘다"는
서술의 정확성)**: 부정확했다. Cloud KMS는 사용량이 아니라 **활성
CryptoKeyVersion 수** 기준으로 과금한다. rotation 제거가 멈추는 것은
**신규** version 생성뿐이고, 이미 존재하는 활성 version 1개는 그 version이
실제로 `DESTROYED` 상태가 되기 전까지 계속 과금된다(software key 기준
버전당 월 $0.06). `kms_vault_orphan.tf`·`docs/TERRAFORM_DEV.md`·PR #500
본문 체크리스트를 모두 이 근거로 정정했다 — 이번 설계(key ring/crypto
key `prevent_destroy` 영구 보존)에서는 이 잔여 과금도 영구적이나 금액은
미미하다.

**이해도 확인 답변 (comment 5 — `docs/VAULT_OPERATIONS_RUNBOOK.md:8`이
아직 "`removed` 블록 apply"라는 2차 정정 시절 서술을 담고 있어 3차
정정(comment 1)의 최종 설계와 불일치)**: 지적이 맞았다. 3차 정정 이후
문서 전반을 훑을 때 이 배너 문구를 놓쳤다 — "dev root는 `removed` 블록
apply"를 "dev root는 `kms_vault_orphan.tf` 유지 + 잔여 4개 destroy
apply"로 정정했다.

## claude-review 8차 지적 (2026-08-02, PR #500)

7차 fix 세트 재요청 리뷰에서 5건이 나왔다. 이번 회차는 로컬에서 실제
동작을 재현·검증(`terraform init` 실측, provider 소스 재확인)해 답했다.

**이해도 확인 답변(1) — `kms_vault_orphan.tf` 헤더가 "이 파일이 존재하는
한 destroy를 apply가 막아 준다"고 key ring/crypto key를 함께 묶어
서술하지만, `prevent_destroy`는 crypto key에만 있고 key ring에는 없었다**:
지적이 맞았다. 지금은 crypto key가 key ring을 참조해 root 전체/key ring
대상 destroy가 crypto key 쪽 guard에서 먼저 막히지만, 이 파일의 목적
자체가 "리소스가 개별적으로 config에서 빠져나가 drift 감지 밖으로 조용히
사라지는 것을 막는" 것이다. key ring은 삭제 API가 없어 destroy가 API
호출 없이 state 제거로만 끝나므로, 누군가 나중에 key ring 블록만 지우면
guard 없이는 그 시점부터 감지 대상에서 빠진다 — key ring에도 독립적으로
`prevent_destroy`를 추가했다.

**이해도 확인 답변(2) — rotation 제거 in-place update가 GCP 실제 상태에
반영됐는지 확인할 명령이 없고, `next_rotation_time`이 Terraform schema에
없어 서버 쪽에 남아도 plan/state에 나타나지 않는 사각지대를 어떻게
다루는지**: 맞는 지적이다. `next_rotation_time`이 tracked 속성이 아니라는
사실 자체가 "GCP 쪽에서 완전히 안 지워져도 Terraform은 절대 알아채지
못한다"는 뜻이므로, 승인 apply 직후 `gcloud kms keys describe
vault-unseal --keyring=<ring> --location=<region> --project=<project>
--format='value(rotationPeriod,nextRotationTime)'`로 두 값이 비어 있는지
1회 수동 확인하는 절차를 `kms_vault_orphan.tf` 주석에 추가했다.

**이해도 확인 답변(3) — `will no longer be managed by Terraform` 패턴을
dev root 스텝에서 뺀 7차 결정이 실제로는 정보 손실을 만드는지, `Plan:`
요약 라인이 forget을 어떻게 집계하는지**: 재검토 결과 7차 결정을
뒤집었다. `^Plan: [0-9]`는 forget이 있어도 항상 매치되므로 "몇 개
forget되는지" 총계 자체는 이 alternative 없이도 남지만, **어떤 리소스
주소인지는 이 alternative 없이는 완전히 사라진다** — 미래에 dev root에
`removed` 블록이 하나라도 추가되면 PR 댓글도 drift 이슈 본문도 "1 to
forget"만 보여주고 원인 리소스를 알려주지 않는다. 이 한 줄은 비용이
없고 `apply.yml`의 admin root 스텝에서 이미 실제 매치 동작이 검증돼
있으므로, "오늘 dev root에 removed 블록이 없다"는 이유로 이 안전장치를
빼는 것은 실익보다 위험이 크다고 판단해 `terraform-drift.yml`/
`terraform-plan.yml`/`apply.yml`(dev-root 스텝) 3곳 모두에 다시 추가했다.

**이해도 확인 답변(4) — `terraform/admin/vault-k8s/` 디렉터리는 삭제됐지만
카탈로그(`environment_catalog.rb`의 `TERRAFORM_ROOTS`/
`config/environments/dev/environment.yaml`)에는 남아 있어, 복원 절차 없이
바로 `scripts/terraform-env --environment dev --root
terraform/admin/vault-k8s init`을 실행하면 무슨 일이 벌어지는지**:
로컬에서 실제로 재현했다. `write_terraform_inputs!`가 `FileUtils.mkdir_p`로
빈 디렉터리를 조용히 재생성하고 `.environment.auto.tfvars.json`/
`.environment.backend.hcl`(진짜 bucket/prefix 포함)만 써 넣는다. `.tf`
파일이 없어 `terraform { backend "gcs" {} }` 블록 선언 자체가 없으므로
`-backend-config` 값은 아무 backend에도 연결되지 못하고, `terraform init`은
"Terraform initialized in an empty directory!"로 로컬 상태로 끝난다(실측
확인 — 원격 backend 연결 없음, live state 접근·변경 전혀 없음). 즉 실
리소스를 건드리는 위험은 아니지만, 복원 절차를 건너뛰면 코드 없이 입력
파일만 있는 사용 불가능한 디렉터리가 워킹 트리에 조용히 생겨 운영자를
혼란스럽게 한다 — `environment.yaml`의 해당 항목에 이 실측 결과와
"반드시 절차대로 root 코드를 먼저 복원하라"는 경고 주석을 추가했다.

**이해도 확인 답변(5) — `github_actions.tf`에서 `roles/cloudkms.admin`이
목록 끝으로 옮겨지고, 18줄 근거 주석이 `toset([...])` 리터럴 내부에
들어가 있어 나머지 `role # 한 줄 사유` 형식과 어긋나 목록을 훑기 어려운
문제**: 반영했다. `roles/cloudkms.admin`을 원래 위치(`roles/dns.admin`
다음)로 되돌리고, 다른 항목과 같은 한 줄 사유
(`# key ring/crypto key IAM·속성 (#478 잔존 리소스)`)만 남겼다. 전체
근거는 `resource "google_project_iam_member" "dev_apply_roles"` 블록
바로 위 주석으로 옮겼다. 이 역할이 project 전체 key의
`cryptoKeyVersions.destroy`까지 포함해 실제 필요(`keyRings.get` +
`cryptoKeys.get/update/setIamPolicy`)보다 넓다는 지적도 맞다 — 이 PR
범위에서 custom role로 좁히지는 않되, 후속 검토 여지를 주석에 한 줄
남겼다.

## claude-review 9차 지적 (2026-08-02, PR #500)

라운드 8 수정 후 재요청한 리뷰에서 3건이 지적됐다(라운드 8의 5건에서
감소).

**이해도 확인 답변(1) — `rotation_period` 제거가 replace로 판정될 경우
`prevent_destroy` 하에서 plan/apply가 각각 어떻게 되는지**: 이번
변경은 애초에 replace를 유발하지 않는다 — `rotation_period`는
provider 스키마(`resource_kms_crypto_key.go`)에서 `Optional`/
`TypeString`이며 `ForceNew`가 아니다(직접 소스 확인, ForceNew는
`name`/`key_ring`에만 걸림). 그래도 가정 시나리오에 답하기 위해 로컬
재현으로 확인했다: `prevent_destroy = true`가 걸린 리소스에 대해 plan이
replace로 판정되면 **`terraform apply`가 아니라 `terraform plan`
자체가** `Error: Instance cannot be destroyed`로 즉시 실패한다(exit
code 1, apply는 시도조차 되지 않음). 이 저장소의 `apply.yml`에서는 dev
root plan 스텝에서 파이프라인이 멈추므로, 같은 plan에 묶인 나머지
변경(4개 destroy 포함)도 함께 적용되지 못한다. 복구는 ForceNew를
유발한 원인 diff를 되돌리는 것뿐이다(이 PR 범위에서는 애초에 그런
diff가 없으므로 해당 없음). `kms_vault_orphan.tf`의
`google_kms_crypto_key.vault_unseal` 코멘트에 이 내용을 추가했다.

**이해도 확인 답변(2) — destroy 대상 4개 중 custom role↔key IAM
binding의 부분 실패 시 수렴 여부, 그리고 롤백 시 role_id 재사용
제약**: git history(vault.tf 삭제 전 커밋)로 참조 관계를 확인했다 —
`google_kms_crypto_key_iam_member.vault_unseal.role`이
`google_project_iam_custom_role.vault_unseal.id`를,
`google_service_account_iam_member.vault_wi.service_account_id`가
`google_service_account.vault.name`을 참조한다. Terraform은 destroy
시 이 그래프를 뒤집어 참조하는 쪽(binding)을 항상 먼저 destroy하므로,
"role만 삭제되고 binding이 남는" 비대칭 상태는 일반(비-target) apply
경로에서 발생하지 않는다 — binding destroy가 실패하면 그 지점에서
멈춰 role/GSA는 아직 손대지 않은 채 남고, 재실행하면 그대로 수렴한다.
role_id 재사용 제약은 웹 검색으로 재확인했다: "7일이 지나면 완전히
삭제되고 그때부터 같은 ID를 재사용할 수 있다"는 이전(3차 정정) 서술이
부정확했다 — GCP는 영구 삭제(7일 경과) 후에도 같은 `role_id`
재사용을 최대 37일(삭제 후 7~37일 구간)까지 막을 수 있다. 안전한
선택지는 (a) 7일 안에 `gcloud iam roles undelete`, (b) 최대 37일을
기다린 뒤 재생성, (c) 다른 `role_id` 사용 중 하나다. "롤백" 절과
`kms_vault_orphan.tf`의 관련 주석을 모두 정정했다.

**이해도 확인 답변(3) — `terraform-drift.yml`이 머지~승인 apply 사이
매일 돌 때의 정확한 동작과, 진짜 새 drift와의 구분 방법**: 파일을
다시 읽어 추적했다 — 4개 destroy만 있고 add/change가 0인 plan은
`-detailed-exitcode` 기준 exitcode `2`를 반환하고, "결과 판정" 스텝이
exitcode가 `0`이 아니면 무조건 `exit 1`하므로 이 job은 승인 apply
전까지 **매일 실패 처리**된다(정상 동작). 이슈는 라벨(`bug`/
`terraform`/`gcp`) + 제목(`[DRIFT] dev root 코드-인프라 불일치`)
필터로 기존 open 이슈를 찾는 로직 덕분에 첫날 1회만 생성되고 이후는
코멘트만 추가된다(중복 이슈 생성 없음). 진짜 새 drift와의 구분은
round 8에서 이미 확보된 리소스 주소 보존 덕분에 가능하다 — 매일
코멘트가 정확히 이 4개 주소 + `Plan: 0 to add, 0 to change, 4 to
destroy.`와 일치하면 예상된 Vault drift이고, 주소가 더 있거나
add/change가 0이 아니거나 destroy 개수가 다르면 별도 조사가 필요한
새 drift다. 이 판별 기준을 `docs/VAULT_OPERATIONS_RUNBOOK.md`에 새
절("머지~승인 apply 사이 예상 drift")로 추가하고, `terraform-drift.yml`
헤더 주석에서 그 절을 참조하도록 했다.

## claude-review 10차 지적 (2026-08-02, PR #500)

라운드 9 수정 후 재요청한 리뷰에서 6건이 지적됐다(라운드 9의 3건에서
증가 — 5→3→6으로 단조 수렴이 아니었다. 그중 1건은 **라운드 9 수정
자체의 사실 오류**를 지적한 CRITICAL 항목이었다).

**이해도 확인 답변(1, CRITICAL) — 라운드 9에서 작성한 "머지~승인 apply
사이 예상 drift" 기준선이 틀렸다는 지적**: 맞다. 라운드 9 문서는
기준선을 "destroy 대상 4개 주소, `Plan: 0 to add, 0 to change, 4 to
destroy.`"로 서술했는데, `google_kms_crypto_key.vault_unseal`의
rotation 제거도 in-place update로 매일 함께 잡힌다는 사실이 빠져
있었다 — 머지 직후 config에는 이미 `rotation_period`가 없지만 live/
state에는 승인 apply 전까지 기존 값이 남아 있어, 이 리소스도 매일 plan
에서 diff로 뜬다. 잘못된 기준선을 쓰면 실제 정상 drift(1 update + 4
destroy)가 "정의되지 않은 6번째 리소스처럼" 보여 매일 "새 drift"로
오판될 위험이 있었다. `docs/VAULT_OPERATIONS_RUNBOOK.md`의 해당 절,
`kms_vault_orphan.tf`의 crypto key 코멘트, `docs/TERRAFORM_DEV.md`의
"(0 또는 1 to change)"라는 모호한 서술을 모두 "5개 주소, 1 to change +
4 to destroy"로 정정했다.

**이해도 확인 답변(2) — 위 정정과 짝을 이루는 지적, `TERRAFORM_DEV.md`의
"GCP 쪽 변경 없음"류 서술 재확인**: 답변(1)의 정정에 포함해 함께
처리했다 — 승인 apply는 "변경 없음"이 아니라 crypto key 1개
in-place update를 실제로 수행한다는 점을 명시했다.

**이해도 확인 답변(3) — `roles/cloudkms.admin`이 project 전체 key의
`cryptoKeyVersions.destroy`까지 포함하는데, 이 초과 권한을 실제로
제한하는 것이 무엇인지**: 정직하게 답하면 IAM 자체에는 이 초과분을
kms_vault_orphan.tf의 2개 리소스로 좁힐 방법이 없다(role은 project
단위 부여이고, 필요한 update/setIamPolicy를 가진 더 좁은 predefined
role이 없다). 실제 방어는 코드 쪽 2겹뿐이다: ①이 2개 리소스의
`prevent_destroy`가 Terraform 경로의 destroy를 막고, ②`apply.yml`의
사람 승인 게이트가 이 SA로 실행되는 모든 apply를 리뷰 없이 실행되지
않게 막는다. SA 자격 자체가 Terraform 밖에서(예: SA 키 탈취) 직접
오남용되는 경로는 어느 쪽도 막지 못한다는 한계를 그대로 인정하고
`github_actions.tf`의 `dev_apply_roles` 주석에 명시했다.

**이해도 확인 답변(4) — `environment.yaml`의 vault-k8s 카탈로그
항목이 CI에서 실제로 안전한지, 그리고 정리 시점을 추적하는 방법**:
`apply.yml`의 `ADMIN_ROOTS`가 vault-k8s를 정적으로 제외하고,
`lint.yml`이 돌리는 `scripts/test-environment-catalog.rb`는 임시
디렉터리의 합성 YAML만 검증할 뿐 `terraform init`을 호출하지 않으므로
실 디렉터리를 건드리지 않는다 — 두 경로 모두 실 위험이 없음을
확인했다. 카탈로그 3곳(`environment.yaml`, `environment_catalog.rb`의
`TERRAFORM_ROOTS`/`ROOT_VARIABLE_KEYS`, `test-environment-catalog.rb`
픽스처)을 지우는 작업은 "승인 후 실행할 vault-k8s admin root state
정리 절차" 안에 5단계로 추가해, 이 문서 자체가 체크리스트 역할을
하도록 했다(별도 이슈 없이 state rm 직후 실행).

**이해도 확인 답변(5) — 설계 문서 안에서 "removed 블록"·"6개"로 남은
서술이 최종 결정(kms_vault_orphan.tf 유지 2개 + destroy 4개)과
충돌한다는 지적**: "승인 후 실행할 vault-k8s admin root state 정리
절차" 절의 도입부가 초기 설계안 문구를 그대로 남기고 있었다 — 최종
전략을 반영해 정정했다.

**이해도 확인 답변(6, non-blocking) — 여러 파일의 "claude-review N차
지적" 회차 인용이 문서 안에서 근거 없이 나열돼 가독성을 해친다는
지적**: `kms_vault_orphan.tf`를 전체 재작성해 회차 인용 없이 실질
근거만 남기고 이 설계 문서 하나로 investigative history를 모으도록
정리했다. `terraform-drift.yml`/`terraform-plan.yml`/`apply.yml`의
grep 정규식 설명 코멘트에서도 회차 인용을 제거하고 실질 이유(정규식이
왜 필요한지)만 남겼다.

## claude-review 11차 지적 (2026-08-02, PR #500)

라운드 10 수정 후 재요청한 리뷰에서 6건이 지적됐다. 모두 `CLAUDE.md`와
`.claude/docs/agent-project-reference.md`/`agent-terraform-reference.md`의
문서 일관성 문제였다 — 저장소 실 트리(`kms_vault_orphan.tf`는 남아
있고 `vault.tf`/`terraform/admin/vault-k8s`는 삭제됨)와 이 3개 문서의
서술이 어긋난 부분을 지적했다. 검증 결과 6건 중 4건은 실제로 반영이
필요했고, 2건(`agent-terraform-reference.md`의 admin root 목록,
`agent-project-reference.md`의 `VAULT_OPERATIONS_RUNBOOK.md` 이슈 번호
서술)은 이미 이전 라운드에서 정정돼 있어 추가 조치가 필요 없었다(리뷰
comment의 diff position이 가리키는 스냅샷과 최신 커밋 사이에 차이가
있었던 것으로 보인다 — 반영 전 실제 파일 내용을 grep으로 재확인한 뒤
적용했다).

반영한 4건: `CLAUDE.md`의 dev root 파일 목록에 `kms_vault_orphan.tf`
누락, admin root 목록에 `mlflow-k8s` 누락(이 PR 이전부터 있던 별개
gap이나 같은 줄을 손대는 김에 함께 반영) — 2건 모두 추가.
`agent-project-reference.md`의 dev root 트리 다이어그램에도 같은
`kms_vault_orphan.tf` 항목 추가. 두 문서 모두 `vault-k8s`가 #412
운영 제외 → #478 root 삭제(원격 state 잔여 4개만 승인 대기) 상태임을
트리 밖 각주로 명시(트리 안에 다시 넣지 않음 — 존재하지 않는 디렉터리를
트리에 넣으면 오히려 오해를 유발한다는 라운드 10 이전 판단 유지).

## 완료 조건

- [ ] `terraform/envs/dev/vault.tf` 삭제
- [ ] `variables.tf`/`locals.tf`/`outputs.tf`의 Vault 전용 항목 제거
- [ ] `github_actions.tf`의 `roles/cloudkms.admin`은 **영구 유지**한다
      (`kms_vault_orphan.tf`가 남기는 key ring/crypto key 2개의 상시
      관리에 필요 — comment 3 3차 정정 참조). 별도 회수 후속 PR은
      계획하지 않는다
- [ ] `versions.tf`의 `required_version`은 `>= 1.6.0`을 유지한다(`removed`
      블록을 쓰지 않으므로 `>= 1.7.0` 상향 불필요 — 3차 정정)
- [ ] `kms_vault_orphan.tf`에 key ring/crypto key 2개를 일반 `resource`
      블록으로 남기고 `rotation_period`만 제거, `lifecycle { prevent_destroy
      = true }` 적용. GSA/WI 바인딩/custom role/key IAM binding 4개는
      이 파일에 포함하지 않고 일반 destroy 대상으로 남긴다(comment 1
      3차 정정 반영)
- [ ] `dns.tf`/`elastic.tf`의 vault 참조 주석 정리
- [ ] `terraform/admin/vault-k8s/` 디렉터리 삭제
- [ ] `CLAUDE.md`(및 symlink `AGENTS.md`), `.claude/docs/agent-project-reference.md`,
      `.claude/docs/agent-terraform-reference.md`, `.claude/docs/architecture-overview.md`
      갱신
- [ ] `docs/TERRAFORM_DEV.md` "Vault auto-unseal 기반 — 폐기 이력" 절을
      "rotation 제거 update 1건(key ring/crypto key는 config에 영구 유지) +
      destroy 4건"으로 정정(claude-review 3차 지적 반영 — 이전 리비전들의
      "forget" 서술 제거), 및 이를 참조하던 나머지 문서
      (`terraform/envs/dev/README.md`, `terraform/README.md`,
      `docs/INFRASTRUCTURE_SUMMARY.md`, `.github/pr-report/pipeline-nodes.json`)의
      stale 참조 정리
- [ ] `docs/TERRAFORM_DEV.md`의 비용 서술 정정 — key rotation `90d` 제거는
      승인 apply의 in-place update 1회로 자동 처리되며(수동 gcloud 절차
      불필요), 그 즉시 신규 CryptoKeyVersion 생성·과금이 멈추고 이후에도
      `kms_vault_orphan.tf`가 config에 남아 있는 한 drift 감지 대상임을
      명시(claude-review 3차 지적 반영)
- [ ] `docs/VAULT_OPERATIONS_RUNBOOK.md` 배너 갱신(코드 제거 완료, state
      정리는 승인 대기로 정정)
- [ ] `will no longer be managed by Terraform` allowlist 패턴은
      `terraform-drift.yml`/`terraform-plan.yml`/`apply.yml`(dev-root +
      admin-root 스텝) 4곳 모두에 둔다 — dev root에는 지금 `removed` 블록이
      없어 이 alternative가 오늘은 매치되지 않지만, 빠져 있으면 미래에
      dev root가 `removed` 블록을 쓸 때 `Plan:` 총계만 남고 리소스 주소가
      완전히 사라지는 실질적 회귀 위험이 있다(claude-review 7차 지적으로
      뺐다가 8차 지적으로 재추가). admin-root 스텝은
      `monitoring-k8s`/`argo-rollouts-k8s`의 기존 `removed` 블록(helm_release
      forget)으로 매치 동작 자체가 실제 검증돼 있다
- [ ] `scripts/environment_catalog.rb`/`config/environments/dev/environment.yaml`의
      `vault-k8s` 카탈로그 항목 유지 사유 주석 추가
- [ ] `fmt -check`, `validate`, `git diff --check` 통과
- [ ] plan에 의도하지 않은 리소스 삭제가 없는지 검토(dev root에서 key
      ring/crypto key 2개는 rotation 제거로 인한 in-place update 1건만
      나오고 destroy 0, 나머지 `google_service_account.vault`(GSA)·
      `google_service_account_iam_member.vault_wi`(WI 바인딩)·
      `google_project_iam_custom_role.vault_unseal`(custom role)·
      `google_kms_crypto_key_iam_member.vault_unseal`(key-level IAM
      바인딩) 4개는 실제 destroy로 나타남 — 이 4개와 별개로
      `google_project_iam_member.dev_apply_roles["roles/cloudkms.admin"]`
      (apply SA의 project-level role)은 영구 유지이므로 이번 plan에
      나타나지 않음)
- [ ] KMS crypto key destroy가 CryptoKeyVersion 파기를 실제로 예약한다는
      사실과, config 유지 + `prevent_destroy`로 그 위험을 없앤 이유를
      문서에 기록
- [ ] 머지 직후 `terraform-drift.yml`이 4개 리소스 destroy 대상 때문에
      매일 job 실패 + `[DRIFT]` 이슈 생성(첫날)/코멘트(이후 매일)를
      반복함을 `docs/VAULT_OPERATIONS_RUNBOOK.md`의 "머지~승인 apply
      사이 예상 drift" 절에 기록하고, 진짜 새 drift와 구분하는 기준
      (예상 4개 주소 + `4 to destroy`와 정확히 일치하는지)을 명시한다
      (claude-review 9차 지적)
- [ ] `rotation_period` 제거는 provider 스키마상 `ForceNew`가 아니므로
      이번 apply의 plan은 항상 in-place update이며 replace를 계획하지
      않는다는 사실을, `prevent_destroy` 하에서 replace가 발생하면
      `terraform plan` 자체가(apply 이전 단계에서) 즉시 실패한다는
      로컬 재현 결과와 함께 `kms_vault_orphan.tf` 주석에 기록한다
      (claude-review 9차 지적)
- [ ] destroy 대상 4개 중 참조 관계가 있는 2쌍(key IAM binding→custom
      role, WI 바인딩→GSA)은 Terraform의 의존성 역순 destroy 덕분에
      부분 실패 시에도 "참조되는 쪽만 먼저 사라지는" 비대칭 상태가
      발생하지 않고 재실행만으로 수렴함을 `kms_vault_orphan.tf` 주석에
      기록한다(claude-review 9차 지적)
- [ ] 롤백 절에 custom role `vaultUnsealKmsAccess`의 GCP soft delete
      7일 보존 사실과, 그 기간 내 롤백 시 `gcloud iam roles undelete` +
      `terraform import`가 필요하다는 절차 정정 반영(claude-review 3차
      지적, comment 7 참조). 7일 경과 후에도 같은 `role_id` 재사용이
      최대 37일까지 막힐 수 있다는 사실로 추가 정정(claude-review 9차
      지적 — "7일 지나면 바로 apply 가능" 서술은 부정확했음)

## 롤백

- 코드 변경만 되돌리려면 이 PR을 revert한다 — live 리소스는 건드리지
  않았고, apply도 아직 실행되지 않았으므로(별도 승인 대기 중) state에도
  영향이 없다. 즉시 원상 복구된다.
- 승인 후 apply까지 실행했다면:
  - **key ring/crypto key 2개(rotation 제거 in-place update)**: 3차
    정정으로 이 2개는 애초에 state에서 빠지지 않는다 — `kms_vault_
    orphan.tf`가 config에 영구히 남고 `prevent_destroy`로 보호되므로,
    `terraform import`가 필요한 상황 자체가 생기지 않는다. rotation만
    되돌리고 싶다면 `kms_vault_orphan.tf`의 `google_kms_crypto_key.
    vault_unseal`에 `rotation_period = "7776000s"`(90일)를 다시 추가해
    `apply`하면 in-place update 한 번으로 원복된다.
  - **GSA/WI 바인딩/custom role/key IAM binding 4개(destroy)**: 실제로
    GCP에서 삭제되므로 `terraform import`로 되돌릴 대상 자체가 없다 —
    `vault.tf`를 복원해 `terraform apply`로 재생성해야 한다(GSA 이메일이
    바뀌면 그 GSA를 참조하는 다른 리소스도 함께 갱신 필요, 실질적으로는
    #478 이전 상태로의 완전한 재구축). **단, custom role
    `vaultUnsealKmsAccess`는 destroy 후 7일간 GCP IAM에서 soft delete
    상태로 보존되며 같은 role_id 재생성이 막혀 있다**(comment 7 참조) —
    이 7일 이내에 `vault.tf`를 복원해 그냥 `terraform apply`를 돌리면
    custom role 생성 단계에서 오류가 난다. 그 기간 안에 롤백하려면 먼저
    `gcloud iam roles undelete --project=<PROJECT_ID>
    vaultUnsealKmsAccess`로 role을 되살린 뒤 `terraform import
    google_project_iam_custom_role.vault_unseal
    projects/<PROJECT_ID>/roles/vaultUnsealKmsAccess`로 state에 편입하고
    나머지 3개만 일반 `apply`로 재생성한다. **정정(claude-review 9차
    지적)**: "7일이 지난 뒤라면 undelete 없이 바로 `apply`해도 된다"는
    이전 서술은 부정확했다 — GCP는 영구 삭제(7일 경과) 후에도 같은
    `role_id` 재사용을 최대 37일(삭제 후 7~37일 구간)까지 막을 수 있다.
    즉 안전한 선택지는 (a) 7일 안에 undelete, (b) 최대 37일을 기다린 뒤
    재생성, (c) 다른 `role_id`로 새로 만드는 것 중 하나이며, "7일만
    지나면 무조건 바로 apply 가능"은 보장되지 않는다. `vault.tf`를
    복원할 때 `kms_vault_orphan.tf`의 key ring/crypto key 2개 블록은
    함께 지워야 한다 — 두 파일에 같은 리소스 주소를 남기면 `Duplicate
    resource` 오류가 난다(comment 4 3차 정정 참조).
  - **부분 apply 실패 시 수렴 여부(claude-review 9차 지적)**: destroy
    대상 4개 중 `google_kms_crypto_key_iam_member.vault_unseal`은
    `role` 속성으로 `google_project_iam_custom_role.vault_unseal.id`를,
    `google_service_account_iam_member.vault_wi`는
    `service_account_id` 속성으로 `google_service_account.vault.name`을
    참조한다(vault.tf 삭제 전 커밋 기준). Terraform은 destroy 시 이
    참조 그래프를 뒤집어 참조하는 쪽(binding)을 참조되는 쪽(role/GSA)
    보다 항상 먼저 destroy하므로, "role/GSA는 지워졌는데 binding만
    남는" 비대칭 상태는 일반(비-target) apply 경로에서 발생하지 않는다.
    binding destroy가 실패하면 그 지점에서 그래프 진행이 멈춰 role/GSA는
    아직 destroy 시도조차 안 된 채 state·GCP 양쪽에 그대로 남고, 재실행
    하면 실패했던 binding destroy부터 다시 시도해 수렴한다 — 별도 수동
    개입 없이 재실행만으로 정상 수렴한다.
  - `roles/cloudkms.admin`은 영구 유지로 설계가 바뀌어(comment 3 3차
    정정) 별도 회수 후속 PR이 없으므로, 이와 관련해 되돌릴 대상도 없다.
- 승인 후 vault-k8s state rm까지 실행했다면, `terraform/admin/vault-k8s/`를 git
  history에서 복원하고 `terraform import`로 4개 리소스를 다시 state에
  넣을 수 있다(단, live 리소스가 이미 없으므로 `helm_release`/`namespace`/
  `network_policy`는 import 대상 자체가 없다 — 실질적으로는 재설치가
  필요하며, 이는 이 PR의 롤백 범위를 넘는다).
