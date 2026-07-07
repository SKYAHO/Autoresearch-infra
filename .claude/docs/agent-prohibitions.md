# Agent Prohibitions

> Last Updated: 2026-07-07

이 저장소에서 에이전트가 해서는 안 되는 일의 목록입니다.

## Git / GitHub

- `main`에 직접 push하지 않습니다. 모든 변경은 PR을 거칩니다.
- 사용자 확인 없이 GitHub 원격에 영향을 주는 작업을 하지 않습니다:
  issue 생성·수정·close, label 변경, PR 생성·수정·merge, 원격 branch
  push·삭제, Project·Ruleset·Secrets·remote URL 변경.
- 시크릿(`.env`, `keys/`, service account key), Terraform state
  (`*.tfstate`), 실값 `terraform.tfvars`, plan 파일을 커밋하지 않습니다.
- 컨벤션 외 커밋 type을 사용하지 않습니다. 허용:
  `feat`, `fix`, `exp`, `docs`, `refactor`, `test`, `chore`.
- 이미 push된 브랜치를 사용자 동의 없이 force push하지 않습니다
  (rebase 후 `--force-with-lease`는 예외).

## Infrastructure

- 사용자가 명확히 요청하지 않는 한 `terraform apply`/`destroy`를
  실행하지 않습니다. 검증은 `fmt`/`validate`/`plan`까지입니다.
- Terraform state를 직접 조작(mv, rm, import)하지 않습니다. 필요하면
  사용자에게 계획을 설명하고 확인받습니다.
- 요청된 변경에 필요하지 않은 광범위한 리팩터링을 하지 않습니다.
- 리소스 변경과 구조 변경(파일 이동, 이름 변경)을 한 커밋에 섞지
  않습니다.
- 자격 증명, API 키, project id, 버킷 이름을 코드에 하드코딩하지
  않습니다. 변수와 Secret을 사용합니다.
- IAM 권한을 필요 이상으로 확대하지 않습니다 (`roles/owner`,
  `roles/editor` 금지).
- `deletion_protection` 해제, 리소스 삭제·교체를 유발하는 변경은 PR에
  명시 없이 포함하지 않습니다.
- `google_project_service` 리소스를 추가하지 않습니다 (API 수동 활성화
  정책).

## Docs

- 동작, 명령어, 설정이 바뀌었는데 문서를 갱신하지 않은 채 작업을
  끝내지 않습니다.
- 규칙 문서(`CLAUDE.md`, `CONTRIBUTING.md`, `.claude/docs/`) 간에
  충돌하는 내용을 새로 만들지 않습니다. 충돌을 발견하면 사용자에게
  보고합니다.
- 로컬 전용 문서(`agent.md`, `docs/NOTION_PROGRESS_TIMELINE.md`)를
  커밋하지 않습니다.
