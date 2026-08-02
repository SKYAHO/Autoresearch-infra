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
# 않는다 — Vault 워크로드 자체가 영구 폐기됐고 git history로 언제든
# 재생성 가능하므로, forget/config-유지가 아니라 실제 destroy 대상으로
# 남긴다(최소 권한 원칙, `vault.tf` 삭제로 이미 config에서 빠짐).

resource "google_kms_key_ring" "vault" {
  name     = "${local.resource_prefix}-vault"
  location = var.region
}

resource "google_kms_crypto_key" "vault_unseal" {
  name     = "vault-unseal"
  key_ring = google_kms_key_ring.vault.id
  # rotation_period 없음(기존 90d 제거) — Vault가 영구 폐기돼 더 이상 회전할
  # 필요가 없다. 승인 apply 시 in-place update로 기존 rotation_period가
  # 제거되며, 그 즉시 신규 CryptoKeyVersion 생성·과금이 멈춘다(수동
  # `gcloud kms keys update --remove-rotation-schedule` 불필요 — apply
  # 자체가 그 동작을 대체한다).

  lifecycle {
    prevent_destroy = true
  }
}
