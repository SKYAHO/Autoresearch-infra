# #238 코드 아카이브 배포 파이프라인 인프라.
# GitHub Actions(Autoresearch code-archive.yml)가 main 머지/dispatch 시 코드
# tar.gz를 이 버킷에 올리고 latest.txt를 갱신하며, GKE autoresearch-app 파드가
# 시작 시 아카이브를 내려받아 실행한다. 앱 구현: SKYAHO/Autoresearch#180, #182.
#
# #577에서 두 번째 용도가 붙었다 — 학습 데이터셋 스냅샷(`training-snapshots/`).
# 성격이 같아서 같은 버킷을 쓴다: 파드 밖에서 만들어 올리고 파드는 읽기만 하는 불변
# 산출물이며, 소비자 GSA마다 `objectViewer`를 한 줄씩 부여하는 이 파일의 관례가 그대로
# 적용된다. prefix로 분리하고 IAM 조건으로 서로 침범하지 않게 한다.

# 파드가 읽는 입력물 버킷. versioning 없음(#238) — 코드 아카이브는 삭제해도 git에서
# 재생성 가능한 배포 캐시고, #577 스냅샷은 content-addressed write-once라 같은 경로에
# 다른 내용이 덮어써지는 상황 자체가 성립하지 않는다. prevent_destroy는 두지 않는다.
# 공개 접근은 차단.
resource "google_storage_bucket" "code_artifacts" {
  name                        = local.code_artifacts_bucket
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  labels = {
    data_class = "artifact"
    purpose    = "code-artifacts"
  }
}

# GitHub Actions(Autoresearch)가 WIF로 가장해 아카이브를 업로드하는 전용 SA.
# 앱 이미지 push SA(application_pusher)와 분리해 권한 전이를 막는다.
resource "google_service_account" "code_uploader" {
  account_id   = local.code_uploader_sa_name
  display_name = "Autoresearch dev code archive uploader SA"
  description  = "Impersonated by Autoresearch GitHub Actions via WIF to upload code archives to GCS."
}

# 정확한 code-archive workflow(main)만 이 SA 가장 허용(#175/#221 관례:
# repository 단독이 아니라 workflow_ref로 임의 브랜치·워크플로우 가장 차단).
# push(main)·workflow_dispatch(main) 모두 workflow_ref가 동일해 단일 바인딩으로 충분.
resource "google_service_account_iam_member" "code_uploader_wi" {
  service_account_id = google_service_account.code_uploader.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.github_wif_pool_name}/attribute.workflow_ref/${var.code_uploader_workflow_ref}"
}

# 업로더는 이 버킷에만 objectAdmin. latest.txt 덮어쓰기가 필요해 objectViewer로는
# 부족하다. 프로젝트 수준 권한은 부여하지 않는다(resource-level 최소권한).
resource "google_storage_bucket_iam_member" "code_uploader_object_admin" {
  bucket = google_storage_bucket.code_artifacts.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.code_uploader.email}"
}

# GKE autoresearch-app 파드(gke_app GSA)는 이 버킷 read만(아카이브 다운로드).
resource "google_storage_bucket_iam_member" "code_artifacts_app_viewer" {
  bucket = google_storage_bucket.code_artifacts.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.gke_app.email}"
}

# #263 Feast materialize DAG. KubernetesPodOperator가 KSA airflow/autoresearch-batch로
# 띄우는 Feast 전용 이미지의 entrypoint가 code/latest.txt와 code/<sha>.tar.gz를 읽는다.
# gke_app과 동일하게 이 버킷 read만 부여하고 write(objectAdmin)는 업로더 SA에만 남긴다.
resource "google_storage_bucket_iam_member" "code_artifacts_airflow_batch_viewer" {
  bucket = google_storage_bucket.code_artifacts.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.airflow_batch.email}"
}

# #346/#370 feast apply Job. Dockerfile.feast는 코드를 이미지에 넣지 않고
# ENTRYPOINT 부트스트랩이 code/<sha>.tar.gz를 받아 /app에 푼다. 같은 GSA로
# GitHub Actions가 Job 생성 전에 아카이브 업로드 완료를 폴링하므로(코드 아카이브
# 워크플로우와 병렬 실행), 이 grant 하나가 파드와 러너 두 경로를 모두 연다.
# 위 두 리소스와 동일하게 read만 부여하고 write는 업로더 SA에만 남긴다.
resource "google_storage_bucket_iam_member" "code_artifacts_feast_apply_dev_viewer" {
  bucket = google_storage_bucket.code_artifacts.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.feast_apply_dev.email}"
}

resource "google_storage_bucket_iam_member" "code_artifacts_feast_apply_prod_viewer" {
  bucket = google_storage_bucket.code_artifacts.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.feast_apply_prod.email}"
}

# #577 실험 Job이 학습 입력으로 쓰는 데이터셋 스냅샷 read.
#
# 위 네 grant와 달리 **IAM 조건으로 prefix를 좁힌다.** 이유는 이 GSA의 권한 경계가
# 다른 소비자보다 좁게 설계돼 있기 때문이다 — `experiment_jobs.tf`가 결과 버킷에
# objectViewer를 주지 않으면서 "Job이 이전 결과를 읽거나 삭제할 수 없다"를 명시적으로
#보장한다. 그 GSA에 이 버킷 전체 read를 주면 `code/` 아카이브까지 함께 열려 경계가
# 필요 이상으로 넓어지므로, 학습 입력 prefix로만 제한한다.
#
# 조건식은 `experiment_runtime.tf`의 registry/staging read와 같은 형태다.
# 조건부 IAM은 GCS에서 object 단위로 평가되므로 `objects.get`은 prefix로 좁혀지지만
# **`objects.list`는 bucket resource에 대해 평가돼 prefix 조건이 성립하지 않는다.**
# 즉 이 grant로는 목록 조회가 되지 않는다 — 애플리케이션은 스냅샷을 목록으로 찾지 않고
# content-addressed 경로(`by-hash/<dataset_sha256>/`)를 직접 지정해 읽으므로 문제없다.
# 목록이 필요해지면 그때 별도 검토한다(무조건 넓히지 않는다).
resource "google_storage_bucket_iam_member" "code_artifacts_experiment_job_snapshot_viewer" {
  bucket = google_storage_bucket.code_artifacts.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.experiment_job.email}"

  condition {
    title       = "experiment-job-training-snapshot-read"
    description = "학습 데이터셋 스냅샷 prefix만 읽도록 제한하고 코드 아카이브는 제외한다."
    expression  = "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.code_artifacts.name}/objects/${local.training_snapshot_prefix}')"
  }
}
