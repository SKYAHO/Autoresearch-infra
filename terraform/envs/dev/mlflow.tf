# MLflow 리소스 (#91 설계, #92 GCS artifact bucket + 전용 GSA).
# 설계: docs/superpowers/specs/2026-07-17-mlflow-operating-design.md
# backend(Cloud SQL DB/user)는 #93, 배포(mlflow-k8s + deploy/mlflow + ArgoCD)는 #94.

# --- artifact store: GCS 버킷 (proxy 모드로 MLflow 서버만 접근) ---
# 모델 artifact 저장소. 외부 공개 금지, 삭제 방지, 7일 soft delete 복구층(#179 교훈).
resource "google_storage_bucket" "mlflow_artifacts" {
  name                        = local.mlflow_artifacts_bucket
  location                    = var.mlflow_bucket_location
  storage_class               = var.mlflow_bucket_storage_class
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  # 실수/침해로 artifact 삭제 시 7일 복구 가능(#179 ES snapshot 교훈).
  soft_delete_policy {
    retention_duration_seconds = var.mlflow_artifacts_soft_delete_seconds
  }

  labels = {
    data_class = "artifact"
    purpose    = "mlflow-artifacts"
  }

  # 모델 artifact 손실 방지. 삭제하려면 코드에서 이 블록을 먼저 제거해야 한다.
  lifecycle {
    prevent_destroy = true
  }
}

# --- MLflow 전용 GSA (app GSA와 분리 — GCS 자격을 MLflow 서버에만 부여) ---
resource "google_service_account" "mlflow" {
  account_id   = local.mlflow_sa_name
  display_name = "Autoresearch dev MLflow tracking server workload identity SA"
}

# Workload Identity: mlflow namespace의 KSA(#94에서 생성)가 이 GSA를 가장한다.
# KSA보다 먼저 만들어도 무방(멤버 문자열만 참조).
resource "google_service_account_iam_member" "mlflow_wi" {
  service_account_id = google_service_account.mlflow.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.mlflow_workload_identity_principal}"
}

# GCS artifact 버킷 접근 — 이 버킷에만(resource-level 최소권한).
# objectAdmin(객체 read/write) + legacyBucketReader(bucket.get).
# #204 교훈: objectAdmin에는 storage.buckets.get이 없어 일부 GCS 클라이언트가 403.
resource "google_storage_bucket_iam_member" "mlflow_artifacts_object_admin" {
  bucket = google_storage_bucket.mlflow_artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.mlflow.email}"
}

resource "google_storage_bucket_iam_member" "mlflow_artifacts_bucket_reader" {
  bucket = google_storage_bucket.mlflow_artifacts.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.mlflow.email}"
}

# Cloud SQL 접근(private IP). MLflow 서버 pod만(WI). 노드 SA에 주지 않음. #93.
resource "google_project_iam_member" "mlflow_cloudsql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.mlflow.email}"
}
