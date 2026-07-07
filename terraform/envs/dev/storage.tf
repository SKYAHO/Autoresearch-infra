# #18 dev 원본 데이터 GCS bucket
# YouTube raw, user raw, action log raw, persona raw 원본 전체를 prefix로 나눠 저장한다.
resource "google_storage_bucket" "raw_data" {
  name                        = local.raw_data_bucket_name
  location                    = var.raw_data_bucket_location
  storage_class               = var.raw_data_bucket_storage_class
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  labels = merge(local.default_labels, {
    data_class = "raw"
    purpose    = "original-data"
  })

  lifecycle {
    prevent_destroy = true
  }
}
