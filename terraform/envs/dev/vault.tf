# #132 Vault dev 도입 1단계: Cloud KMS auto-unseal 기반
# Vault 설치(helm release, NetworkPolicy)는 terraform/admin/vault-k8s에서
# 별도 state로 관리한다(2단계). 설계: docs/superpowers/specs/2026-07-12-vault-dev-design.md
# 전제: cloudkms.googleapis.com API 수동 활성화(필수 GCP API 표 참조).

# --- Cloud KMS (gcpckms seal) ---

# keyring은 GCP에서 삭제가 불가능한 리소스다. 이름 재사용 충돌을 피하기 위해
# state에서 제거하더라도 실제 keyring은 남는다.
resource "google_kms_key_ring" "vault" {
  name     = "${local.resource_prefix}-vault"
  location = var.region
}

# unseal key 제거 시 Vault Raft 데이터 복호화가 불가능해진다. 2단계 release
# 제거 후에만 정리한다(설계 문서 롤백 절차).
resource "google_kms_crypto_key" "vault_unseal" {
  name            = "vault-unseal"
  key_ring        = google_kms_key_ring.vault.id
  rotation_period = "7776000s" # 90d

  lifecycle {
    prevent_destroy = true
  }
}

# --- Vault 전용 GSA + Workload Identity ---

resource "google_service_account" "vault" {
  account_id   = local.vault_sa_name
  display_name = "Autoresearch dev Vault workload identity SA"
  description  = "Vault server auto-unseal(gcpckms). KMS vault-unseal key 접근만 보유."
}

resource "google_service_account_iam_member" "vault_wi" {
  service_account_id = google_service_account.vault.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.vault_workload_identity_principal}"

  depends_on = [google_container_cluster.dev]
}

# Vault gcpckms seal 요구 권한(cryptoKeys.get + useToEncrypt/useToDecrypt).
# 사전 정의 role cryptoKeyEncrypterDecrypter는 cryptoKeys.get을 포함하지
# 않으므로 custom role을 key 단위로 바인딩한다(bootstrap custom role 선례).
resource "google_project_iam_custom_role" "vault_unseal" {
  role_id     = "vaultUnsealKmsAccess"
  title       = "Vault unseal KMS access"
  description = "Vault gcpckms seal이 요구하는 최소 권한 (key-level 바인딩 전용)"
  permissions = [
    "cloudkms.cryptoKeys.get",
    "cloudkms.cryptoKeyVersions.useToEncrypt",
    "cloudkms.cryptoKeyVersions.useToDecrypt",
  ]
}

resource "google_kms_crypto_key_iam_member" "vault_unseal" {
  crypto_key_id = google_kms_crypto_key.vault_unseal.id
  role          = google_project_iam_custom_role.vault_unseal.id
  member        = "serviceAccount:${google_service_account.vault.email}"
}
