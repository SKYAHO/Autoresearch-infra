# #478: Vault는 #412에서 영구 폐기됐지만, 이 2개 KMS 리소스(key ring/crypto
# key)는 GCP에서 애초에 삭제가 불가능하다 — key ring은 삭제 API 자체가
# 없고, crypto key destroy는 리소스 삭제 자체는 거부하되 모든
# CryptoKeyVersion의 파기를 실제로 예약한다(재현 불가능). 그래서 `removed`
# 블록으로 forget하지 않고 리소스 블록을 그대로 남긴 채 rotation_period만
# 제거해 drift 감지 범위 안에 둔다. `prevent_destroy`는 key ring/crypto key
# 둘 다에 독립적으로 건다 — crypto key가 key ring을 참조해 지금은 crypto
# key guard가 key ring destroy도 막지만, key ring 블록만 단독으로 지워지는
# 경로까지 막으려면 key ring 쪽에도 guard가 필요하다.
#
# GSA/WI 바인딩/custom role/key IAM binding 4개는 이 파일에 포함하지
# 않고 실제 destroy 대상으로 남긴다(최소 권한 원칙, `vault.tf` 삭제로 이미
# config에서 빠짐). destroy 대상 중 2쌍(key IAM binding→custom role,
# WI 바인딩→GSA)은 참조 관계가 있어 Terraform이 destroy 시 그 순서를
# 뒤집어 참조하는 쪽(binding)을 먼저 destroy한다 — binding destroy가
# 중간에 실패해도 role/GSA는 손대지 않은 채 남으므로, 재실행만으로
# 비대칭 상태 없이 수렴한다. custom role(`vaultUnsealKmsAccess`)
# 재생성은 GCP의 soft-delete 제약을 받는다(삭제 후 7일 내
# `gcloud iam roles undelete`로 즉시 복구 가능, 이후 영구 삭제되면 같은
# role_id 재사용이 최대 37일까지 막힐 수 있다).
#
# 이 설계의 조사 근거·검토 이력 전체는
# docs/superpowers/specs/2026-08-02-vault-removal-design.md 참조.

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
  # rotation_period 없음(기존 90d 제거). `rotation_period`는 provider
  # 스키마에서 ForceNew가 아니므로 이 변경은 항상 in-place update이며
  # replace를 계획하지 않는다(가정: `name`/`key_ring`처럼 ForceNew 필드가
  # 바뀌어 plan이 replace로 판정되면 `prevent_destroy` 하에서는 apply가
  # 아니라 `terraform plan` 자체가 "Error: Instance cannot be destroyed"로
  # 즉시 실패한다 — 로컬 재현으로 확인).
  #
  # 승인 apply 시 in-place update(PATCH updateMask=rotationPeriod,
  # nextRotationTime)로 GCP 쪽 rotation schedule이 해제된다 — 이후 신규
  # CryptoKeyVersion 생성·과금은 멈추지만, 이미 존재하는 활성 version
  # 1개의 월정액 과금(버전당 약 $0.06)은 그 version이 실제로 DESTROYED
  # 상태가 되기 전까지 계속된다(영구 보존 설계이므로 이 잔여 과금도
  # 영구적이다).
  #
  # 머지 후 승인 apply 전까지는 이 리소스도 매일 drift plan에 in-place
  # update로 잡힌다 — 판별 기준(부분 실패 시 부분집합 인식 포함)과, Vault와
  # 무관한 다른 dev root apply가 먼저 실행돼 이 변경과 함께 반영되는
  # 경우 승인자가 리소스 주소로 식별하는 방법은
  # docs/VAULT_OPERATIONS_RUNBOOK.md의 "머지~승인 apply 사이 예상 drift"
  # 절 참조.
  #
  # 승인 apply 후 검증:
  #   gcloud kms keys describe vault-unseal \
  #     --keyring="${resource_prefix}-vault" --location=<region> \
  #     --project=<project_id> --format='value(rotationPeriod,nextRotationTime)'
  #   두 값 모두 비어야 정상. `next_rotation_time`은 이 리소스의 Terraform
  #   schema 속성이 아니라 drift 감지로 잡히지 않는 사각지대이므로, 이
  #   gcloud 명령이 유일한 검증 수단이다.

  lifecycle {
    prevent_destroy = true
  }
}
