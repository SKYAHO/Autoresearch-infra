# #478: Vault는 #412에서 영구 폐기됐지만, 이 2개 KMS 리소스(key ring/crypto
# key)는 GCP에서 애초에 삭제가 불가능하다 — keyring은 삭제 API 자체가 없고,
# crypto key destroy는 GCP가 리소스 자체 삭제는 거부하되 모든
# CryptoKeyVersion의 파기를 실제로 예약한다(기본 24시간 후 확정, 재현
# 불가능). 이 2개를 `removed` 블록으로 Terraform 관리 밖으로 forget하는
# 방안도 검토했으나(1차 리비전), forget하면 state·config·`terraform-drift.yml`
# 어디에도 남지 않아 이후 누가 이 key에 IAM을 다시 붙이거나 rotation을
# 재활성화해도 저장소 어디에서도 감지되지 않는다(claude-review 6차 지적,
# docs/superpowers/specs/2026-08-02-vault-removal-design.md 참조). 그래서
# 대신 리소스 블록을 그대로 남기고 rotation_period만 제거해(신규
# CryptoKeyVersion 발생·과금을 코드로 영구 차단) drift 감지 범위 안에 둔다.
# `prevent_destroy`는 리소스 블록이 config에 존재할 때만 작동하므로, 이
# 파일이 존재하는 한 실수로 destroy가 계획돼도 apply가 막아 준다.
#
# GSA/WI 바인딩/custom role/key IAM binding 4개는 이 파일에 포함하지
# 않는다 — Vault 워크로드 자체가 영구 폐기됐고 git history로 재생성
# 가능하므로, forget/config-유지가 아니라 실제 destroy 대상으로
# 남긴다(최소 권한 원칙, `vault.tf` 삭제로 이미 config에서 빠짐).
#
# 이 4개 중 2쌍은 참조 관계가 있다(claude-review 9차 지적):
# `google_kms_crypto_key_iam_member.vault_unseal`의 `role`이
# `google_project_iam_custom_role.vault_unseal.id`를 참조하고,
# `google_service_account_iam_member.vault_wi`의 `service_account_id`가
# `google_service_account.vault.name`을 참조한다(git history, vault.tf
# 삭제 전 커밋 확인). Terraform은 destroy 시 이 그래프를 뒤집어 참조하는
# 쪽(binding)을 참조되는 쪽(role/GSA)보다 항상 먼저 destroy하므로,
# "custom role은 삭제됐는데 binding은 남은" 순서는 일반 apply(비-target)
# 경로로는 발생하지 않는다 — binding destroy가 중간에 실패하면 그
# 시점에서 그래프 진행이 멈춰 role/GSA는 아직 destroy 시도조차 안 된
# 채로 남고(state·GCP 둘 다 "둘 다 존재" 상태 유지), 재실행하면 실패한
# binding destroy부터 다시 시도해 수렴한다.
#
# "git history로 언제든 재생성 가능"의 "언제든"은 부정확하다(claude-review
# 9차 지적) — GCP custom role은 soft-delete된다. 삭제 후 7일 안에는
# `gcloud iam roles undelete vaultUnsealKmsAccess --project=<project_id>`로
# 즉시 복구 가능하지만, 7일이 지나 영구 삭제되면 같은 `role_id`
# (`vaultUnsealKmsAccess`)는 GCP 쪽 예약이 남아 있어 삭제 후 최대
# 37일까지 재사용이 막힐 수 있다(공급자 문서 기준). 그 기간 안에
# git history로 다시 apply하면 role_id 충돌로 실패한다 — 실질적으로는
# 7일 안에 undelete하거나, 최대 37일을 기다리거나, 새 `role_id`를
# 쓰는 것 중 하나를 선택해야 한다.
#
# `prevent_destroy`는 key ring/crypto key 둘 다에 건다(claude-review 8차
# 지적 — 이전 리비전은 crypto key에만 걸려 있었다). crypto key가 key ring을
# 참조하므로 지금은 crypto key의 guard가 key ring destroy도 먼저 막지만,
# 이 파일의 목적 자체가 "이 2개 리소스가 나중에 개별적으로 config에서
# 빠져나가 drift 감지 밖으로 조용히 사라지는 것을 막는" 것이다. key ring은
# 삭제 API가 없어 destroy가 API 호출 없이 state 제거로만 끝나므로, 누군가
# key ring 블록만 지우면 guard 없이는 그 시점부터 감지 대상에서 조용히
# 빠진다 — key ring 쪽에도 독립적으로 guard를 둬야 이 경로를 막는다.

resource "google_kms_key_ring" "vault" {
  name     = "${local.resource_prefix}-vault"
  location = var.region

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key" "vault_unseal" {
  name     = "vault-unseal"
  key_ring = google_kms_key_ring.vault.id
  # 이 변경(rotation_period 제거)은 replace를 유발하지 않는다(claude-review
  # 9차 지적 — in-place update 보장 근거). `rotation_period`는 provider
  # 스키마(resource_kms_crypto_key.go)에서 `Optional`/`TypeString`이며
  # `ForceNew`가 아니다 — ForceNew는 `name`/`key_ring`(리소스 식별자)에만
  # 걸려 있다. 그래서 이번 apply의 plan은 항상 update이며 destroy를
  # 절대 계획하지 않는다. 참고로(가정 시나리오) 만약 이 리소스에 대해
  # `name`/`key_ring`처럼 ForceNew 필드가 바뀌어 plan이 replace로 판정되면
  # `prevent_destroy = true`가 걸린 상태에서 **`terraform apply`가 아니라
  # `terraform plan` 자체가** "Error: Instance cannot be destroyed"로
  # 즉시 실패한다(exit code 1) — 로컬 재현으로 확인. apply는 시도조차
  # 되지 않으므로 `apply.yml`의 dev root plan 스텝에서 파이프라인이
  # 멈추고, 이 파일의 destroy 대상 4개 리소스를 포함한 나머지 변경도
  # 함께 적용되지 못한다(같은 plan에 묶여 있으므로). 복구는 ForceNew를
  # 유발한 변경을 되돌리거나(이번 apply 의도상 발생할 수 없음),
  # `prevent_destroy`를 일시 해제하는 것뿐인데 후자는 이 파일의 목적과
  # 정면으로 배치되므로 실질적으로는 원인 diff를 되돌리는 것이 유일한
  # 선택지다.
  #
  # rotation_period 없음(기존 90d 제거) — Vault가 영구 폐기돼 더 이상 회전할
  # 필요가 없다. 승인 apply 시 in-place update(PATCH updateMask=
  # rotationPeriod,nextRotationTime, 두 필드 모두 body에 미포함)로 GCP
  # 쪽 rotation schedule 자체가 해제된다 — `gcloud kms keys update
  # --remove-rotation-schedule`와 동일한 효과이며, provider가 이
  # updateMask를 정확히 그렇게 구성하는지는 terraform-provider-google
  # 소스(resource_kms_crypto_key.go)로 확인했다(claude-review 7차 지적,
  # 수동 gcloud 절차 불필요 확인). 이후 **신규** CryptoKeyVersion 생성·
  # 과금은 멈추지만, 이미 존재하는 활성 version 1개의 월정액 과금(버전당
  # 약 $0.06)은 그 version이 실제로 `DESTROYED` 상태가 되기 전까지는
  # 계속된다 — "과금이 완전히 멈춘다"는 서술은 부정확하다(claude-review
  # 7차 지적). key ring/crypto key를 `prevent_destroy`로 영구 보존하는
  # 이번 설계에서는 이 잔여 과금도 영구적이나, 금액 자체는 미미하다.
  #
  # 승인 apply 후 GCP 쪽 실제 반영을 확인하려면(claude-review 8차 지적):
  #   gcloud kms keys describe vault-unseal \
  #     --keyring="${resource_prefix}-vault" --location=<region> \
  #     --project=<project_id> --format='value(rotationPeriod,nextRotationTime)'
  #   두 값이 모두 비어 있어야 정상이다. `next_rotation_time`은 이 리소스의
  #   Terraform schema 속성이 아니다(updateMask 구성에만 등장) — 그래서
  #   GCP 서버 쪽에서 이 필드가 완전히 지워지지 않는 경우가 있어도
  #   `terraform plan`/state에는 그 어떤 형태로도 나타나지 않는다. 이건
  #   drift 감지로는 잡히지 않는 사각지대이므로, 위 gcloud 명령이 유일한
  #   검증 수단이다 — 승인 apply 직후 1회 수동 확인이 필요하다.

  lifecycle {
    prevent_destroy = true
  }
}
