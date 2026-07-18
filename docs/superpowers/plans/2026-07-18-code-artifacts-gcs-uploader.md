# 코드 아카이브 배포용 GCS 버킷·업로더 SA·WIF 바인딩 구현 계획

> **For agentic workers:** 신규 GCS 버킷 + IAM + WIF 바인딩. 스레드 내 진행,
> 체크박스로 추적한다.
>
> Issue: #238 (앱 레포 구현 완료: `SKYAHO/Autoresearch#180`, `#182`)

**목표:** main 머지 시 코드를 GCS에 올리고 feast 파드가 시작 시 내려받아 실행하는
배포 경로의 인프라(버킷·업로더 SA·WIF·파드 읽기 권한)를 Terraform으로 추가한다.

**핵심 설계 결정 (WIF 바인딩 범위):** 업로더 SA는 objectAdmin을 갖는 민감
계정이라, 이슈가 예시로 든 `GAR_PUSHER_SA`식 `repository_ref`(repo@ref, 같은
저장소의 모든 워크플로우 허용)보다 더 좁게 바인딩한다. 같은 저장소
(`SKYAHO/Autoresearch`)를 이미 `workflow_ref`로 제한하는 `application_pusher`
패턴을 따라, `code-archive.yml@refs/heads/main` **workflow_ref**로만 가장을
허용한다. `code-archive.yml`은 `push:main` + `workflow_dispatch` 두 트리거 모두
main workflow file@ref를 assertion하므로 이 하나로 충분하다. bootstrap WIF
provider `allowed_github_repositories`에 `SKYAHO/Autoresearch`가 이미 있어
bootstrap 변경은 불필요하다.

---

## Task 1: Terraform 리소스 추가 (envs/dev)

- [x] `locals.tf`: `code_artifacts_bucket_name = "${var.project_id}-code-artifacts"`.
- [x] `github_actions.tf` locals: `code_uploader_sa_name`.
- [x] `variables.tf`: `code_uploader_workflow_ref`
  (default `SKYAHO/Autoresearch/.github/workflows/code-archive.yml@refs/heads/main`).
- [x] `storage.tf`: `google_storage_bucket.code_artifacts`(서울, versioning 없음,
  UBLA, PAP enforced, soft delete 0, `prevent_destroy`) +
  `code_artifacts_gke_app_object_viewer`(파드 읽기).
- [x] `github_actions.tf`: `google_service_account.code_uploader` +
  `code_uploader_wi`(workflow_ref 바인딩) +
  `code_uploader_object_admin`(버킷 단위 objectAdmin).
- [x] `outputs.tf`: `github_actions_code_uploader_service_account_email`,
  `code_artifacts_bucket_name`.

## Task 2: 문서 갱신

- [x] `docs/TERRAFORM_DEV.md`: 코드 아카이브 업로드 WIF 경로 섹션 추가(버킷·SA·
  파드 읽기·secret 매핑·롤백).
- [x] `terraform/envs/dev/README.md`: GCS·CI pusher·기능 bullet 갱신.
- [x] 이 plan 문서 작성.

## Task 3: 검증

- [x] `terraform -chdir=terraform/envs/dev fmt -check -recursive`
- [x] `terraform -chdir=terraform/envs/dev validate`
- [x] `git diff --check`
- [ ] merge 후 apply(사용자 승인 필요). plan 기대: 버킷 1 + SA 1 + IAM 3 add.
- [ ] apply 후 완료 조건:
  1. dev output `code_artifacts_bucket_name`, `github_actions_code_uploader_service_account_email`
     두 값을 앱 레포 담당(hyochangsung)에게 전달 → secret `CODE_ARTIFACTS_BUCKET`,
     `GCS_CODE_UPLOADER_SA` 등록.
  2. 앱 레포 `code-archive.yml`(workflow_dispatch) 성공 → 버킷에
     `code/<sha>.tar.gz`, `code/latest.txt` 생성 확인.

## 롤백

`code_uploader*`와 버킷 관련 리소스 제거 후 apply. 버킷은 `prevent_destroy`라
먼저 lifecycle 블록을 해제해야 삭제된다. IAM 멤버 삭제는 다른 리소스에 영향 없음.

## 비용/보안 영향

- 비용: 미미(수 MB 아카이브, 머지마다 1객체 추가, versioning 없음).
- 보안: 신규 objectAdmin은 code-artifacts 버킷 **단위**로만 부여하고,
  가장 주체를 정확한 `code-archive.yml@main` workflow_ref로 제한한다. 파드는
  objectViewer(읽기 전용). 새 public 노출·프로젝트 전역 권한·다른 저장소로의
  권한 전이는 없다.
