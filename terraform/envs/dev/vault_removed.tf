# #478: vault.tf의 6개 리소스를 config에서 삭제했지만, 아직 dev root state에는
# 남아 있다(승인 대기 중인 state 정리, docs/superpowers/specs/2026-08-02-vault-removal-design.md
# 참조). 이 중 KMS key ring/crypto key 2개만 removed 블록으로 forget한다 —
# crypto key destroy는 CryptoKeyVersion 파기를 실제로 예약하므로(기본 24시간 후
# 확정) 재현 불가능한 파괴적 동작이라 무해하지 않다. 나머지 4개(GSA, WI 바인딩,
# custom role, key IAM binding)는 removed 블록을 두지 않는다 — Vault는 #412에서
# 영구 폐기됐고, 이 4개는 안전하게 destroy 가능하며 필요하면 git history로 언제든
# 재생성할 수 있으므로 최소 권한 원칙에 따라 forget 대신 실제 destroy 대상으로
# 남겨 둔다(claude-review 지적 반영, 승인 후 apply 시 destroy 계획).
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
