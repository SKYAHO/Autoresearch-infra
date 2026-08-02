# #478: vault.tf의 6개 리소스를 config에서 삭제했지만, 아직 dev root state에는
# 남아 있다(승인 대기 중인 state 정리, docs/superpowers/specs/2026-08-02-vault-removal-design.md
# 참조). removed 블록 없이 리소스 블록만 지우면 다음 plan/apply(terraform-drift.yml,
# apply.yml scope:all)가 이 6개를 destroy 대상으로 계획한다 — KMS crypto key
# destroy는 CryptoKeyVersion 파기를 실제로 예약하므로 무해하지 않다. removed
# 블록은 destroy를 계획하지 않고 state에서만 분리(forget)하도록 강제해, 승인
# 없는 apply가 실행되더라도 이 6개는 그대로 보존된다. 실제 forget은 이
# 블록이 apply될 때 실행되며, 이 역시 별도 승인 후에만 apply한다.
removed {
  from = google_kms_key_ring.vault

  lifecycle {
    destroy = false
  }
}

removed {
  from = google_kms_crypto_key.vault_unseal

  lifecycle {
    destroy = false
  }
}

removed {
  from = google_service_account.vault

  lifecycle {
    destroy = false
  }
}

removed {
  from = google_service_account_iam_member.vault_wi

  lifecycle {
    destroy = false
  }
}

removed {
  from = google_project_iam_custom_role.vault_unseal

  lifecycle {
    destroy = false
  }
}

removed {
  from = google_kms_crypto_key_iam_member.vault_unseal

  lifecycle {
    destroy = false
  }
}
