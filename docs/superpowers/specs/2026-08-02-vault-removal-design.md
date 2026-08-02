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
  Vault 전용 항목 — `github_actions.tf`의 `roles/cloudkms.admin`은 유지,
  아래 참조) + dev root state에 남는 6개 리소스 중 key ring/crypto key
  2개에 대한 `removed` 블록 추가(destroy 없이 forget), 나머지 4개(GSA/WI
  바인딩/custom role/key IAM binding)는 일반 destroy 대상으로 남김(아래
  "state 분리 전략" 참조)
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

**카탈로그에 `vault-k8s` 항목이 남아 있는 이유**: `scripts/environment_catalog.rb`의
`TERRAFORM_ROOTS`/`ROOT_VARIABLE_KEYS`와
`config/environments/dev/environment.yaml`의 `state.roots`에는 root
디렉터리가 삭제된 뒤에도 `terraform/admin/vault-k8s` 항목이 남아 있다.
이는 실수가 아니라 **의도적**이다 — 위 절차가 `scripts/terraform-env`의
backend-config 생성에 의존하므로, state 정리가 끝나기 전까지 카탈로그
항목을 지우면 이 복구 절차 자체가 동작하지 않는다. 두 파일 모두에
"state 정리 완료 전까지 유지" 주석을 남겨 다음 정리 작업에서 실수로
지워지는 것을 막는다.

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
objects, but will not delete them" — HashiCorp 공식 동작).

**`removed` 대상은 6개 전부가 아니라 key ring/crypto key 2개로 한정한다**
(claude-review 재지적 반영, 2026-08-02 2차). 최초 정정에서는 GSA·WI
바인딩·custom role·key IAM binding 4개도 "재현이 필요해지면 `terraform
import`로 되돌릴 수 있게" forget으로 통일했으나, Vault는 #412에서
**영구 폐기**된 경로라 재현 시나리오 자체가 없다. KMS key/keyring은
crypto key destroy가 CryptoKeyVersion 파기를 실제로 예약하는(기본
24시간 후 확정) 재현 불가능한 파괴적 동작이라 forget이 유일하게
안전한 선택이지만, 나머지 4개(GSA, WI 바인딩, custom role, key IAM
binding)는 destroy해도 GCP 쪽에 파기 예약 같은 비가역 부작용이 없고
git history로 언제든 재생성 가능하다. 이 4개를 forget으로 두면
Terraform 관리 밖에서 계속 살아 있는 IAM 바인딩(예: `vault` namespace의
`vault` KSA가 여전히 KMS decrypt 가능한 GSA를 impersonate할 수 있는
Workload Identity 바인딩)이 drift 감지 대상에서도 빠진 채 무기한
남으므로, 최소 권한 원칙에서는 forget보다 destroy가 맞다. 그래서
`terraform/envs/dev/vault_removed.tf`에는 key ring/crypto key 2개만
남기고, 나머지 4개는 `removed` 블록 없이 그대로 두어(=이미 `vault.tf`
삭제로 config에서 빠짐) 승인 후 apply 시 정상적으로 destroy되게 한다.

이 방식은 "승인 후 실행할 state 정리 절차"(구 버전, `terraform state
rm` 수기 실행)를 KMS key ring/crypto key 2개에 한해 **대체**한다 —
`removed` 블록이 있는 코드를 apply하는 것 자체가 그 2개 항목에 대해
`state rm`과 동일한 효과를 내며, 코드로 선언돼 있으므로 실행 실수(엉뚱한
리소스를 rm하는 등) 위험도 없다. 나머지 4개는 일반적인 코드 삭제 →
apply 시 destroy 흐름을 그대로 따른다. **이 apply 실행 자체는 여전히 이
PR 범위 밖이며 별도 승인이 필요하다**(이슈 #478의 명시적 caution) —
승인 후 apply가 실행되면 plan은 forget 2건 + destroy 4건(GSA·WI
바인딩·custom role·key IAM binding)으로 나타난다. `roles/cloudkms.admin`은
이 apply에 포함되지 않는다 — 이유는 아래 "comment 3" 참조(순서 위험 회피를
위해 이번 PR·apply 범위에서 뺐고, 별도 후속 PR에서 회수한다).

**이해도 확인 답변 (comment 2, 2차 정정 — 머지 직후 drift/apply.yml 노출 창)**:
1차 답변의 "(a) drift로 오탐되지 않는다" 결론은 **틀렸다**(claude-review
2차 지적, 2026-08-02). 이 PR이 머지되면 dev root state에는 여전히
6개 리소스가 남아 있고, config에는 key ring/crypto key 2개에 대한
`removed` 블록 + 나머지 4개(GSA·WI 바인딩·custom role·key IAM
binding)에 대한 **config 자체 부재**(= 실제 destroy 대상)가 함께
존재한다. 이 상태에서:

- **(a) `terraform-drift.yml`의 `plan -detailed-exitcode`**: key
  ring/crypto key 2개는 "no longer managed, will not be destroyed"로
  계획되어 add/change/destroy 카운트에 잡히지 않지만, **나머지 4개는
  실제 destroy 대상으로 계획된다.** 즉 `Plan: 0 to add, 0 to change, 4
  to destroy.`가 되어 `-detailed-exitcode`는 `2`를 반환하고,
  `terraform-drift.yml`은 승인 apply가 끝날 때까지 **매일 09:23
  KST마다 `[DRIFT]` 이슈를 생성/코멘트한다.** 이는 오탐이 아니라
  "승인 대기 중인 진짜 변경사항이 있다"는 정확한 신호이므로, 머지 직후
  발생하는 첫 `[DRIFT]` 이슈에는 이 PR을 참조하는 코멘트를 남겨 원인이
  #478 승인 대기임을 명시한다(완료 조건에 반영).
  - 추가로 allowlist 렌더링 문제: `terraform-drift.yml:79`의 allowlist
    정규식은 `will be`/`must be`/`has moved to`만 매칭해 `removed` +
    `destroy = false` 대상의 헤더(`# <addr> will no longer be managed
    by Terraform, but will not be destroyed`)를 놓친다. #468에서
    `moved` 블록에 대해 겪었던 것과 같은 정보 손실이라, 이번 PR에서
    `will no longer be managed by Terraform` 패턴을 추가해 함께
    고쳤다(`.github/workflows/terraform-drift.yml` 참조).
- **(b) 누군가 `apply.yml`을 `scope: all`로 dispatch하고 승인 1회를
  받는 경우**: 그 apply는 key ring/crypto key 2개를 destroy 없이
  forget하고, GSA·WI 바인딩·custom role·key IAM binding 4개를 실제로
  destroy한다(`roles/cloudkms.admin`은 이 PR에서 **아직 회수하지
  않는다** — 아래 comment 3 참조). "실제 GCP 삭제는 미수행" 전제와
  양립한다 — **이 PR 자체는 코드만 바꿀 뿐 apply를 실행하지 않으므로**,
  승인 없이 이 코드가 반영되는 일은 없다. 다만 승인 전에 다른 이유로
  `apply.yml scope:all`이 돌면 이 4개 리소스는 그대로 destroy
  계획에 포함되므로(예상치 못한 승인 클릭 방지가 여전히 유일한
  방어선), 승인 게이트 자체를 신뢰하는 전제는 변하지 않는다.

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
- **결정**: `roles/cloudkms.admin`은 이번 PR에서 유지하고(코드에 남겨
  둠, `github_actions.tf`에 사유 주석 추가), 승인된 apply로 4개
  리소스 destroy + 2개 forget이 실제로 반영된 뒤 이 role이 더 이상
  필요 없음을 확인하고 나서 **별도 후속 PR**에서 회수한다(완료 조건에
  반영). 이 PR 시점 기준으로는 `roles/cloudkms.admin` 관련 변경이
  전혀 없으므로, 1차 답변에서 다뤘던 "권한 회수" 자체가 이 PR 범위에서
  사라졌다 — 순서 문제도 함께 사라진다(회피가 아니라 제거).
- **`terraform-plan.yml`/`terraform-drift.yml`의 읽기 전용 `CI_SA`
  (`terraform-ci`) 경로**: 이 SA는 `dev_apply_roles`가 아니라 부트스트랩
  단계에서 부여된 **project-level `roles/viewer`**를 쓴다
  (`docs/TERRAFORM_BOOTSTRAP.md`). `roles/viewer`는 Cloud KMS
  read(`cloudkms.cryptoKeys.get`/`keyRings.get`)를 포함하는 범용
  읽기 role이라 `dev_apply`의 `cloudkms.admin` 회수와는 완전히
  무관하다 — 이 경로는 회수 전후 어느 시점에도 403을 받지 않는다.
- **판단**: key ring/crypto key 2개(forget)에 한정하면 provider 권한이
  전혀 필요 없어 순서가 무의미하지만, 4개를 실제 destroy로 바꾼 이상
  그중 key IAM binding 1개는 `cloudkms.admin`을 요구하므로 "권한 회수와
  destroy를 같은 apply에 함께 넣지 않는다"가 유일하게 안전한 순서다.
  이번 PR은 회수 자체를 이번 apply 범위에서 빼는 방식으로 이 순서
  요구를 만족시킨다.

**이해도 확인 답변 (comment 4 — `vault_removed.tf`의 수명주기)**:
`removed` 블록은 이제 key ring/crypto key 2개로 줄었다. 이 2개에
한정해 아래 질문에 답한다.

1. **forget이 끝난 뒤 `apply.yml` 재실행 시 영향**: `removed` 블록은
   대상 주소가 state에 없어도 plan/apply를 막지 않는다 — Terraform은
   "state에 없으면 이미 forget된 것으로 간주하고 조용히 무시"한다(추가
   API 호출도, 오류도 없다). 즉 이 파일은 forget이 끝난 뒤에도 안전하게
   남아 있을 수 있다. 다만 영구히 둘 이유는 없으므로, forget apply가
   성공한 것을 `terraform state list`로 확인한 뒤 이 파일을 삭제하는
   작업을 이슈 완료 후속 정리(별도 PR)로 남긴다 — 이번 PR 완료 조건에는
   포함하지 않는다(아직 apply 자체가 승인 전이라 시점을 못 박을 수
   없음).
2. **`vault.tf`가 나중에 복원되는데 `vault_removed.tf`가 남아 있는
   경우**: 같은 리소스 주소가 `resource` 블록과 `removed` 블록 양쪽에
   있으면 Terraform은 `validate`/`plan` 단계에서 즉시 에러를 낸다
   ("resource ... is in both a removed block and a resource block" 류).
   즉 이 상황은 조용히 잘못된 상태로 넘어가지 않고 명시적으로 막힌다 —
   복원 작업자가 `vault.tf`를 되살리려면 `vault_removed.tf`의 해당
   블록도 함께 지워야 하며, CI `validate`가 이를 강제한다.

**이해도 확인 답변 (comment 5 — 잔여 IAM 권한 경계, `github_actions.tf:252`)**:
이 코멘트는 6개 전부를 forget으로 통일했던 설계를 지적한 것으로, comment
3의 설계 변경(4개는 destroy로 전환, 위 참조)이 사실상의 답이다. 지적된
두 질문에 대해서도 명시적으로 답한다.

1. **forget 유지 시 잔여 권한 경계**(이제는 승인 apply 전까지의 현재
   상태에 대한 질문으로 한정): `vault` namespace의 `vault` KSA가
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

**이해도 확인 답변 (comment 6 — forget과 destroy가 같은 apply에 있을 때
순서, `vault_removed.tf:19`)**:
같은 apply 안에서 `google_kms_crypto_key.vault_unseal`은 forget되고,
그 key를 참조하던 `google_kms_crypto_key_iam_member.vault_unseal`은
실제 destroy된다. 두 동작의 순서는 결과에 영향을 주지 않는다 — 이유는
"어느 쪽이 먼저 실행되는지"가 아니라 "destroy가 값을 어디서 가져오는지"에
있다.

- `google_kms_crypto_key_iam_member.vault_unseal`의 `crypto_key_id`
  값은 **그 리소스 자신의 state 항목에 생성 시점에 이미 값으로
  저장돼 있다**(참조가 아니라 문자열 값). config에서 `vault.tf`가
  통째로 삭제된 이상 이 리소스는 config에 존재하지 않으므로, destroy
  계획은 config의 참조식을 다시 평가하지 않고 **state에 저장된 값을
  그대로 읽어 GCP API 호출을 구성**한다. 즉 destroy 시점에 crypto key
  리소스가 여전히 state에 있는지, 이미 forget돼 사라졌는지는 이
  destroy 호출과 무관하다 — forget은 GCP API를 전혀 호출하지 않는
  순수 state 조작이므로 IAM member 쪽 값을 훼손하거나 무효화할 수도
  없다.
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
반환한다). 7일이 지나면 완전히 삭제되고 그때부터 같은 ID를 재사용할 수
있다. `gcloud iam roles undelete --project=<PROJECT_ID>
vaultUnsealKmsAccess`로 7일 안에 되살릴 수도 있다.

이는 아래 "롤백" 절의 "`vault.tf`를 복원해 `terraform apply`로
재생성" 서술에 구멍이 있었다는 뜻이다 — **destroy 후 7일 이내에** 그냥
`terraform apply`를 돌리면 custom role 생성 단계에서 오류가 난다.
"롤백" 절을 아래와 같이 정정한다(체크리스트에도 반영).

**이해도 확인 답변 (comment 8 — `vault_removed.tf` 삭제 후속 PR이 승인
apply보다 먼저 머지되는 경우, `vault_removed.tf:19`)**:
comment 4는 forget apply 성공을 `terraform state list`로 확인한 뒤 이
파일을 삭제하는 정리를 별도 후속 PR로 미뤄 두었는데, 그 순서를 강제하는
장치는 코드·CI 어디에도 없다.

- **plan에 미치는 영향**: `vault_removed.tf`가 먼저 사라지면 dev root
  config에는 key ring/crypto key에 대한 어떤 블록도 남지 않는다
  (`vault.tf`는 이미 이 PR에서 삭제됨). 승인 apply가 아직 실행되지
  않은 상태라 state에는 이 2개 리소스가 여전히 남아 있으므로, 그
  다음 plan은 이 2개를 GSA·WI 바인딩·custom role·key IAM binding
  4개와 똑같이 **`will be destroyed`(실제 destroy)로 계획한다** —
  `removed` 블록이 막던 "forget vs destroy" 구분이 사라지는 것이다.
- **live GCP 영향**: 이 plan이 그대로 승인·apply되면 crypto key
  destroy가 CryptoKeyVersion 파기를 실제로 예약한다(위 "정정된 접근"
  절의 원래 위험이 그대로 재현). 다만 확정까지 기본 24시간의 유예가
  있고, 이 dev key에는 실제 Vault Raft 데이터가 없어(배경 절 참고)
  파기돼도 복구할 실피해는 없다 — 위험은 "의도와 다른 삭제가 조용히
  실행된다"는 절차 실수 쪽이지, 데이터 손실 쪽이 아니다.
- **`terraform-drift.yml`로 구분 가능한가**: 텍스트로는 구분된다 —
  정상 시나리오는 plan 요약에 `will no longer be managed by
  Terraform, but will not be destroyed`가 찍히고, 이 사고 시나리오는
  `will be destroyed`가 찍힌다. 다만 `terraform-drift.yml`은 이
  차이를 해석하지 않고 원문 그대로 이슈에 올릴 뿐이므로, 매일 오는
  `[DRIFT]` 이슈를 습관적으로 훑어보는 사람이 두 문구의 차이를
  놓치면 못 잡아낸다 — 자동 판별 장치는 없다.
- **강제 장치가 필요한가**: 코드/CI 수준 가드(예: "config에 없는데
  `removed`도 없는 KMS 주소가 있으면 실패"하는 정적 검사)까지는
  이 PR 범위에서 만들지 않는다 — blast radius가 dev의 미사용 key
  1개로 좁고 24시간 유예가 있어 과설계다. 대신 후속 PR 자체의 설명에
  "이 PR은 #478 승인 apply가 `terraform state list`로 이 2개 주소
  부재를 확인한 뒤에만 머지한다"는 전제 조건을 명시하는 것을 완료
  조건에 추가한다(아래 체크리스트).

**이해도 확인 답변 (comment 9 — `roles/cloudkms.admin` 회수 후속 PR이
승인 apply보다 먼저 머지되는 경우, `github_actions.tf:255`)**:

- **(a) 그래프상 의존 관계**: comment 3에서 이미 확인한 대로 없다.
  `google_project_iam_member.dev_apply_roles["roles/cloudkms.admin"]`
  회수와 `google_kms_crypto_key_iam_member.vault_unseal` destroy는
  서로를 참조하지 않는 독립 노드라 실행 순서가 보장되지 않는다 — 이
  후속 PR이 승인 apply보다 먼저 머지되면 comment 3이 막으려던 바로
  그 403 순서 위험이 재현된다.
- **(b) 403으로 apply가 중단되면 state/GCP는 어떤 상태로 남는가**:
  role 회수(`google_project_iam_member` 리소스)가 먼저 처리돼
  성공했다면 그 리소스는 state·GCP 양쪽에서 이미 제거된 상태로
  남는다. 반면 `google_kms_crypto_key_iam_member.vault_unseal`
  destroy 호출이 403으로 실패하면 이 리소스는 **state에도 GCP에도
  그대로 남는다**(destroy가 완료돼야 state에서 빠지므로) — 즉
  "dev_apply SA는 cloudkms 권한이 없는데 아직 destroy 안 된 KMS IAM
  binding이 state에 남아 있는" 부분 실패 상태가 된다. 재실행하려면
  `roles/cloudkms.admin`을 다시 부여(이 후속 PR을 되돌리거나 동등한
  권한을 임시 부여)한 뒤 apply를 다시 돌려야 한다.
- **(c) 어느 단계가 이 실패를 잡아내는가**: `plan` job은 `CI_SA`의
  project-level `roles/viewer`로 읽기만 하므로 이 시점에는 실패하지
  않는다(comment 3의 CI_SA 분석과 동일). 실제로 실패하는 지점은
  `apply` job의 "Apply dev root" 스텝(`apply.yml:383`)이다 — `rc`가
  0이 아니면 `::error::`를 출력하고 그 워크플로 run 자체가 실패로
  끝난다(GitHub Actions run이 실패 표시되어 승인자·dispatch한 사람
  눈에 바로 보인다. `terraform-drift.yml`과는 무관한 경로다).
- **전제 조건을 어디에 남길지**: 지금은 comment 3 문단 안의 문장
  하나뿐이다. comment 8과 동일하게, 이 role을 회수하는 후속 PR
  자체의 설명에 "#478 승인 apply가 성공적으로 끝나 `google_kms_
  crypto_key_iam_member.vault_unseal`이 `terraform state list`에서
  사라진 것을 확인한 뒤에만 머지한다"는 전제 조건을 명시하는 것을
  완료 조건에 추가한다.

## 완료 조건

- [ ] `terraform/envs/dev/vault.tf` 삭제
- [ ] `variables.tf`/`locals.tf`/`outputs.tf`의 Vault 전용 항목 제거
- [ ] `github_actions.tf`의 `roles/cloudkms.admin`은 이번 PR에서 **유지**한다
      (남은 key IAM binding destroy에 필요 — comment 3 참조). 회수는 승인
      apply 완료 확인 후 별도 후속 PR
- [ ] `versions.tf`의 `required_version`을 `>= 1.7.0`으로 상향
- [ ] `vault_removed.tf`에 key ring/crypto key 2개만 `removed` 블록 추가
      (destroy 없이 forget). GSA/WI 바인딩/custom role/key IAM binding
      4개는 `removed` 블록을 두지 않고 일반 destroy 대상으로 남긴다
      (comment 3/5 설계 변경 반영)
- [ ] `dns.tf`/`elastic.tf`의 vault 참조 주석 정리
- [ ] `terraform/admin/vault-k8s/` 디렉터리 삭제
- [ ] `CLAUDE.md`(및 symlink `AGENTS.md`), `.claude/docs/agent-project-reference.md`,
      `.claude/docs/agent-terraform-reference.md`, `.claude/docs/architecture-overview.md`
      갱신
- [ ] `docs/TERRAFORM_DEV.md` "Vault auto-unseal 기반 — 폐기 이력" 절을
      "forget 2건 + destroy 4건"으로 정정(claude-review 3차 지적 — 이전
      리비전인 "6개 전부 forget, GCP 쪽 변경 없음" 서술이 남아 있었음),
      및 이를 참조하던 나머지 문서(`terraform/envs/dev/README.md`,
      `terraform/README.md`, `docs/INFRASTRUCTURE_SUMMARY.md`,
      `.github/pr-report/pipeline-nodes.json`)의 stale 참조 정리
- [ ] `docs/TERRAFORM_DEV.md`의 forget 후 비용 서술 정정 — key rotation
      `90d`는 forget 후에도 live에 남아 CryptoKeyVersion이 계속 쌓이고
      과금되며 drift 감지 밖이라는 사실을 명시하고, forget apply **전**
      `gcloud kms keys update ... --remove-rotation-schedule`로 rotation을
      해제하는 절차를 승인 후 실행 순서에 추가(claude-review 3차 지적)
- [ ] `docs/VAULT_OPERATIONS_RUNBOOK.md` 배너 갱신(코드 제거 완료, state
      정리는 승인 대기로 정정)
- [ ] `.github/workflows/terraform-drift.yml`의 allowlist 정규식에
      `will no longer be managed by Terraform` 패턴 추가(forget 대상
      주소가 `[DRIFT]` 이슈에서 유실되지 않도록, #468 동일 사례)
- [ ] `scripts/environment_catalog.rb`/`config/environments/dev/environment.yaml`의
      `vault-k8s` 카탈로그 항목 유지 사유 주석 추가
- [ ] `fmt -check`, `validate`, `git diff --check` 통과
- [ ] plan에 의도하지 않은 리소스 삭제가 없는지 검토(dev root에서 key
      ring/crypto key 2개는 forget으로만 나오고 destroy 0, 나머지
      GSA/WI 바인딩/custom role/key IAM binding 4개는 실제 destroy —
      `roles/cloudkms.admin`은 이번 PR에서 회수하지 않으므로 IAM
      바인딩 destroy는 이번 plan에 나타나지 않음)
- [ ] KMS crypto key destroy가 CryptoKeyVersion 파기를 실제로 예약한다는
      사실과, `removed` 블록으로 그 위험을 없앤 이유를 문서에 기록
- [ ] 머지 직후 `terraform-drift.yml`이 4개 리소스 destroy 대상 때문에
      `[DRIFT]` 이슈를 생성함을 예상하고, 그 이슈에 #478 승인 대기 중임을
      코멘트로 남긴다(승인 apply 완료 후 이슈 자동 종료 확인)
- [ ] 롤백 절에 custom role `vaultUnsealKmsAccess`의 GCP soft delete
      7일 보존 사실과, 그 기간 내 롤백 시 `gcloud iam roles undelete` +
      `terraform import`가 필요하다는 절차 정정 반영(claude-review 3차
      지적, comment 7 참조)
- [ ] 두 후속 PR(`vault_removed.tf` 삭제, `roles/cloudkms.admin` 회수)은
      각각의 PR 설명에 "#478 승인 apply가 성공적으로 끝난 뒤에만 머지"라는
      전제 조건과 `terraform state list` 확인 방법을 명시한다(claude-review
      3차 지적, comment 8/9 참조 — 순서를 어기면 각각 의도치 않은 KMS
      destroy, IAM 회수-destroy 403 순서 위험 재현)

## 롤백

- 코드 변경만 되돌리려면 이 PR을 revert한다 — live 리소스는 건드리지
  않았고, `removed` 블록을 포함한 apply도 아직 실행되지 않았으므로
  (별도 승인 대기 중) state에도 영향이 없다. 즉시 원상 복구된다.
- 승인 후 apply까지 실행했다면:
  - **key ring/crypto key 2개(forget)**: `vault.tf`에서 해당 2개 리소스
    블록을 git history에서 복원하고 `terraform import`로 다시 state에
    넣을 수 있다(live 리소스는 forget으로는 전혀 건드리지 않았으므로
    import 대상 자체는 그대로 존재한다).
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
    나머지 3개만 일반 `apply`로 재생성한다. 7일이 지난 뒤라면 undelete
    없이 바로 `apply`해도 된다.
- `roles/cloudkms.admin` 후속 회수 PR까지 되돌리려면 그 PR만 별도로
  revert한다(이번 PR의 롤백 범위와 독립적).
- 승인 후 vault-k8s state rm까지 실행했다면, `terraform/admin/vault-k8s/`를 git
  history에서 복원하고 `terraform import`로 4개 리소스를 다시 state에
  넣을 수 있다(단, live 리소스가 이미 없으므로 `helm_release`/`namespace`/
  `network_policy`는 import 대상 자체가 없다 — 실질적으로는 재설치가
  필요하며, 이는 이 PR의 롤백 범위를 넘는다).
