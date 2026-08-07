# 실험 Job 스냅샷 버킷 읽기 권한 구현 계획

> **에이전트 작업자 참고:** 이 계획은 `superpowers:executing-plans` 또는
> `superpowers:subagent-driven-development`로 단계별 실행할 수 있습니다. 각 단계는
> 독립적으로 검증합니다.

**Goal:** 실제로 게시된 `experiment-results` 버킷의 학습 스냅샷을 executor Job이 읽을 수 있도록 `experiment-job` GSA의 Terraform IAM 계약을 정정합니다.

**Architecture:** `terraform/envs/dev`가 실험 결과 버킷과 Job GSA를 함께 소유하므로 viewer binding을 `experiment_jobs.tf`에 둡니다. 버킷은 실험 전용이므로 prefix Condition 없이 버킷 수준 `roles/storage.objectViewer`를 사용하며, 기존 objectCreator와 상태 API viewer는 유지합니다. 이전 #577의 미적용 MLflow viewer 선언과 output 좌표는 실제 live 데이터 좌표인 experiment-results로 교체합니다.

**Tech Stack:** Terraform, Google Cloud Storage IAM, GKE Workload Identity, Markdown 운영 문서.

## Global Constraints

- GSA는 `autoresearch-dev-exp-job@autoresearch-503903.iam.gserviceaccount.com`입니다.
- 대상 버킷은 `gs://autoresearch-503903-autoresearch-dev-experiment-results`입니다.
- 추가 역할은 버킷 수준 `roles/storage.objectViewer`입니다.
- 프로젝트 수준 IAM, `roles/storage.objectAdmin`, 삭제 권한은 추가하지 않습니다.
- 기존 `roles/storage.objectCreator`와 상태 API GSA의 `roles/storage.objectViewer`는 유지합니다.
- 학습 객체 좌표는 `training-snapshots/by-hash/<sha256>/`입니다.
- 실제 `terraform apply`, GCP IAM 변경, Pod 실행 검증은 이 작업에서 수행하지 않습니다.
- 변경 후 롤백은 viewer binding과 관련 좌표를 되돌리는 Terraform revert로 합니다.

---

### Task 1: Terraform IAM 및 snapshot 좌표 정정

**Files:**

- Modify: `terraform/envs/dev/experiment_jobs.tf`
- Modify: `terraform/envs/dev/airflow.tf`
- Modify: `terraform/envs/dev/locals.tf`
- Modify: `terraform/envs/dev/outputs.tf`

**Interfaces:**

- Produces: `google_storage_bucket_iam_member.experiment_job_object_viewer` — `experiment_job` GSA의 `experiment_results` 버킷 viewer binding.
- Produces: `experiment_job_execution_contract.training_snapshot_root_url` — `experiment_results/training-snapshots/` 좌표.

- [x] **Step 1: 현재 Terraform 계약을 기준선으로 검증한다**

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
scripts/terraform-env --environment dev --root terraform/envs/dev init -backend=false -input=false
scripts/terraform-env --environment dev --root terraform/envs/dev validate
```

Expected: 기존 checkout이 포맷·구문 검증을 통과한다.

- [x] **Step 2: 전용 결과 버킷 viewer binding을 추가한다**

`terraform/envs/dev/experiment_jobs.tf`의 `experiment_job_object_creator` 뒤에 다음 리소스를 추가합니다.

```hcl
resource "google_storage_bucket_iam_member" "experiment_job_object_viewer" {
  bucket = google_storage_bucket.experiment_results.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.experiment_job.email}"
}
```

파일 상단과 `locals.tf`의 설명을 “객체 생성만”에서 “객체 생성과 게시된 학습 스냅샷 읽기”로 갱신합니다. objectCreator, API viewer, Workload Identity binding은 변경하지 않습니다.

- [x] **Step 3: 잘못된 구버전 MLflow 좌표를 제거·교체한다**

`terraform/envs/dev/airflow.tf`의 `experiment_job_mlflow_training_snapshot_viewer` 리소스와 관련 주석을 제거합니다. 해당 binding은 현재 live에 없으며 실제 snapshot 객체가 있는 버킷을 가리키지 않습니다.

`terraform/envs/dev/outputs.tf`의 `training_snapshot_root_url`을 다음 식으로 바꿉니다.

```hcl
training_snapshot_root_url = "gs://${google_storage_bucket.experiment_results.name}/${local.mlflow_training_snapshot_prefix}"
```

- [x] **Step 4: Terraform 검증을 다시 실행한다**

```bash
terraform -chdir=terraform/envs/dev fmt -recursive
scripts/terraform-env --environment dev --root terraform/envs/dev validate
git diff --check
```

Expected: exit code 0이며 IAM diff에 project-level binding이나 objectAdmin이 없습니다.

### Task 2: 운영 문서와 변경 이력 갱신

**Files:**

- Modify: `terraform/envs/dev/README.md`
- Modify: `docs/runbooks/2026-08-01-auto-research-experiment-job.md`
- Modify: `docs/CHANGE_HISTORY.md`

**Interfaces:**

- Documents: Job GSA가 결과 버킷에서 객체를 생성하고 게시된 `training-snapshots/by-hash/` 객체를 읽는다는 현재 계약.
- Documents: 실제 apply 전후 확인 명령과 viewer binding 제거를 통한 롤백 절차.

- [x] **Step 1: dev Terraform README의 권한 설명을 갱신한다**

실험 Job Workload Identity 항목과 GCS 권한 설명에 `objectCreator`와 버킷 수준 `objectViewer`, 그리고 `training-snapshots/by-hash/<sha256>/` 입력 좌표를 기록합니다. MLflow artifact bucket의 Airflow batch publisher 설명과 혼동되지 않도록 버킷 이름을 각각 명시합니다.

- [x] **Step 2: 실험 Job runbook의 권한·검증·롤백 설명을 갱신한다**

결과 권한 표와 GCP 신뢰 경계 문장을 생성·읽기 권한에 맞게 수정합니다. 적용 후에는 아래 명령으로 binding과 알려진 manifest를 확인하는 절차를 기록합니다.

```bash
gcloud storage buckets get-iam-policy \
  gs://<project>-autoresearch-dev-experiment-results --format=json

gsutil cat gs://<project>-autoresearch-dev-experiment-results/\
training-snapshots/by-hash/<sha256>/snapshot_manifest.json
```

실패 시 launcher를 먼저 suspend하고, 승인된 Terraform revert로 viewer binding과 snapshot root 좌표를 되돌리며, 버킷·GSA·KSA를 삭제하지 않는다고 명시합니다.

- [x] **Step 3: `docs/CHANGE_HISTORY.md`에 live 좌표 정정 근거를 기록한다**

2026-08-08 / #589 항목에 실제 live 확인 결과, target bucket, 역할, bucket-level 선택 이유, 이전 #577 MLflow binding 제거, apply는 별도 승인이라는 점을 요약합니다.

- [x] **Step 4: 문서·Terraform 최종 검증을 실행한다**

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
scripts/terraform-env --environment dev --root terraform/envs/dev validate
git diff --check
rg -n "experiment_job_object_viewer|experiment_job_mlflow_training_snapshot_viewer|training_snapshot_root_url|experiment-results" \
  terraform/envs/dev docs/runbooks/2026-08-01-auto-research-experiment-job.md
```

Expected: 새 target binding과 experiment-results 좌표가 존재하고, 구버전 `experiment_job_mlflow_training_snapshot_viewer` 선언은 검색되지 않습니다.
