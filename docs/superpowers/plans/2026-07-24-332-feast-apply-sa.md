# feast apply GitHub Actions용 SA 신설 및 WIF 바인딩 (#332)

관련 이슈: SKYAHO/Autoresearch-infra#332 (연계: SKYAHO/Autoresearch#321)

`SKYAHO/Autoresearch`의 `feast-apply.yml` 워크플로우(main merge 시 `feast apply`로
GCS registry 갱신)가 WIF로 인증할 전용 service account를 신설한다. 기존
목적별 SA 관례(`GCS_CODE_UPLOADER_SA`, `GAR_PUSHER_SA`)를 따른다.

## 설계 결정

- **정의 위치**: `terraform/envs/dev/github_actions.tf` — GitHub Actions 전용
  WIF SA 3종이 모여 있는 파일. 신규 SA를 4번째로 추가한다.
- **SA 이름**: 기존 local 네이밍 관례(`${local.resource_prefix}-<역할>`)를 따라
  `feast_apply_sa_name = "${local.resource_prefix}-feast-apply"`
  (account_id `autoresearch-dev-feast-apply`, 28자로 30자 제한 내).
  이슈 본문의 `feast-apply-gha@...`는 예시이며 저장소 관례가 우선.
- **WIF 제한**: `workflow_ref` 단위 단일 바인딩. 대상 워크플로우는 push(main)와
  `workflow_dispatch`(main) 두 트리거 모두 동일 workflow_ref로 도달하므로
  `code_uploader_wi`(code_artifacts.tf)와 동일하게 바인딩 1개로 충분하다.
  - 변수: `feast_apply_workflow_ref`
    (default `SKYAHO/Autoresearch/.github/workflows/feast-apply.yml@refs/heads/main`),
    `code_uploader_workflow_ref` 변수 패턴 준수.
  - bootstrap의 `allowed_github_repositories`에 `SKYAHO/Autoresearch`가 이미
    포함되어 있으므로 bootstrap state 변경은 불필요.
- **GCS 권한**: `google_storage_bucket.feast_registry` 버킷에 bucket-level
  `roles/storage.objectAdmin`. registry는 전체 blob 덮어쓰기 방식이라
  `storage.objects.get/create/delete`가 모두 필요하고, 저장소의 기존
  read-write 사례(`code_uploader_object_admin`,
  `feast_registry_gke_app_object_user`)와 동일한 role이다.
  - `roles/storage.legacyBucketReader`도 부여한다(#204 선례: Feast GCS
    registry client는 read/write 시 `bucket.reload()`로 `storage.buckets.get`을
    호출하는데 `objectAdmin`에는 이 권한이 없어 `feast_registry_gke_app_object_user`
    등 동일 버킷을 쓰는 기존 SA 3종이 모두 `legacyBucketReader`를 함께 보유한다.
    `feast apply`도 동일한 Feast SDK GCSRegistryStore 경로로 registry를
    read/write하므로 동일하게 필요하다).
- **BigQuery 권한**: `google_bigquery_dataset.feast_offline_store` dataset에
  dataset-level `roles/bigquery.metadataViewer`. `feast apply` source
  validation은 테이블 존재 확인(`bigquery.tables.get`)만 수행하므로
  `dataViewer`(tables.getData 포함)나 project-level `jobUser`는 부여하지 않는다.
- **불필요 권한**: Redis/Memorystore(`full_scan_for_deletion: false`),
  Secret Manager(`REDIS_TLS_CA_PATH` 미설정) — 이슈 명시대로 부여하지 않음.
- **output**: `github_actions_feast_apply_service_account_email` —
  기존 `<도메인>_<역할>_service_account_email` 관례, description에
  "Autoresearch 저장소 secrets.FEAST_APPLY_SA 값으로 사용" 명시.

## 변경 (코드, 이 PR)

1. `terraform/envs/dev/github_actions.tf`
   - locals에 `feast_apply_sa_name` 추가
   - `google_service_account.feast_apply` 신설
   - `google_service_account_iam_member.feast_apply_wi` —
     `principalSet://.../attribute.workflow_ref/${var.feast_apply_workflow_ref}`
   - `google_storage_bucket_iam_member.feast_apply_registry_object_admin` —
     feast_registry 버킷 `roles/storage.objectAdmin`
   - `google_storage_bucket_iam_member.feast_apply_registry_bucket_reader` —
     feast_registry 버킷 `roles/storage.legacyBucketReader`(#204 선례)
   - `google_bigquery_dataset_iam_member.feast_apply_offline_store_metadata_viewer`
     — feast_offline_store dataset `roles/bigquery.metadataViewer`
2. `terraform/envs/dev/variables.tf` — `feast_apply_workflow_ref` 변수 추가
   (기존 workflow_ref 변수들 옆, default 포함)
3. `terraform/envs/dev/outputs.tf` —
   `github_actions_feast_apply_service_account_email` output 추가
4. 문서 갱신 (같은 PR)
   - `terraform/envs/dev/README.md` — github_actions.tf 설명과 "CI pusher"
     표에 신규 SA 반영
   - `CLAUDE.md` — github_actions.tf 설명(“WIF pusher SA 3종” → 4종) 갱신
   - `docs/CHANGE_HISTORY.md` — `## 2026-07-24: feast apply GHA용 SA·WIF (#332)`
     섹션 추가 (기존 #238 항목 형식)

## 운영 적용 (apply 단계, 이 PR 이후)

1. PR merge 후 `terraform plan`/`apply` (dev root) — 사용자 확인 필수
2. apply output의 SA 이메일을 `SKYAHO/Autoresearch` 저장소 Actions secret
   `FEAST_APPLY_SA`로 등록
3. `SKYAHO/Autoresearch`의 `feast-apply` 워크플로우 `workflow_dispatch` 수동
   실행으로 인증·apply 성공 확인

## 검증 체크리스트 (이 PR)

- [x] `terraform -chdir=terraform/envs/dev fmt -check -recursive`
- [x] `terraform -chdir=terraform/envs/dev init -backend=false` +
      `validate`
- [x] `git diff --check`
- [x] diff에서 project-level IAM 신설 없음 확인 (모두 resource-level)
- [x] 기존 리소스 변경·교체 없음 (추가만)

## 롤백

신규 리소스 5종(SA, WIF 바인딩, 버킷 IAM 2종, dataset IAM)과 변수/output만
추가하는 변경이므로, 해당 리소스 블록 제거 후 apply로 완전 롤백 가능.
기존 리소스에는 영향 없음. secret `FEAST_APPLY_SA`는 Autoresearch 저장소에서
삭제하면 된다.
