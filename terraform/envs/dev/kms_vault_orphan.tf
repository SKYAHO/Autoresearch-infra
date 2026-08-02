# #478: Vault는 #412에서 영구 폐기됐지만, 이 2개 KMS 리소스(key ring/crypto
# key)는 GCP에서 애초에 삭제가 불가능하다 — key ring은 삭제 API 자체가
# 없고, crypto key destroy는 리소스 삭제는 거부하되 모든 CryptoKeyVersion의
# 파기를 실제로 예약한다(재현 불가능). 그래서 `removed` 블록으로 forget하지
# 않고 리소스 블록을 그대로 남긴 채 rotation_period만 제거해 drift 감지
# 범위 안에 둔다. `prevent_destroy`는 key ring/crypto key 둘 다에 독립적으로
# 건다.
#
# GSA/WI 바인딩/custom role/key IAM binding 4개는 이 파일에 포함하지 않고
# 실제 destroy 대상으로 남긴다(최소 권한 원칙, `vault.tf` 삭제로 이미
# config에서 빠짐).
#
# 이 설계의 조사 근거·롤백 절차(GSA/custom role 재생성 비대칭 포함)·API
# 호출 단계별 분석·리뷰 대응 이력 전체는 정본인
# docs/superpowers/specs/2026-08-02-vault-removal-design.md를 참조한다 —
# 이 파일 자체에는 결정과 제약만 남긴다(claude-review 14차 지적: 중복
# 서술은 한쪽만 갱신되면 서로 어긋난다). 운영 절차(승인 apply 후 검증,
# drift 판별 기준, dev root 전체 destroy와의 상호작용)는
# docs/VAULT_OPERATIONS_RUNBOOK.md 참조.

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
  # rotation_period 없음(기존 90d 제거) — `rotation_period`는 ForceNew가
  # 아니므로 in-place update이며 replace를 유발하지 않는다.

  lifecycle {
    prevent_destroy = true
  }
}
