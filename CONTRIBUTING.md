# 기여 가이드 (Contributing Guide)

autoresearch-infra 저장소에 기여해 주셔서 감사합니다.
이 저장소는 AutoResearch 프로젝트의 GCP 기반 인프라와 GitHub 운영 자동화를 관리합니다.
원활한 협업을 위해 아래 규칙을 따라 주세요.

---

## 워크플로우

```
이슈 등록 → 작업 브랜치 생성 → 작업/검증 → Draft PR 생성 → 셀프 리뷰 및 설명 보강
       → Ready for review 전환 → 에이전트 리뷰 실행 → 이해도 체크 inline 답변
       → 팀원 리뷰 요청 → 최소 2명 승인 → Squash merge
```

1. **이슈 등록**: 작업 시작 전 반드시 이슈를 먼저 만듭니다.
   `Issues > New issue`에서 Issue Form(Feature / Bug / Experiment)을 선택해 작성해 주세요. Form을 선택하면 제목 prefix와 label이 자동으로 적용됩니다.

2. **작업 브랜치 생성**: `main`에서 분기하여 작업 브랜치를 만듭니다.
   브랜치 네이밍 규칙은 아래를 따릅니다.

3. **작업 및 검증**: 커밋 컨벤션에 따라 커밋 메시지를 작성합니다. 인프라 변경은 `git diff --check`, Terraform `fmt`/`validate`(필요 시 `plan`)를 통과시킵니다.

4. **Draft PR 생성**: 작업이 완료되면 Draft PR을 엽니다. PR 템플릿을 채우고 본문에 `Closes #이슈번호`를 포함합니다.

5. **셀프 리뷰 및 설명 보강**: 본인이 diff를 처음부터 끝까지 읽고 PR 설명, 검증 결과, 영향 범위(IAM/비용/리전/롤백)를 보강합니다.

6. **Ready for review 전환**: 설명이 충분해지면 Draft를 해제해 리뷰를 요청할 수 있는 상태로 전환합니다.

7. **에이전트 리뷰 실행**: Ready로 전환되면 Claude Code PR Review workflow가 자동 실행됩니다. (Draft에서는 실행되지 않습니다.)

8. **이해도 체크 inline 답변**: 에이전트가 남긴 `이해도 확인:` inline comment 각각에 같은 스레드에서 답변하고, 필요하면 로컬에서 검증한 뒤 resolve합니다.

9. **팀원 리뷰 요청**: CODEOWNERS 및 담당 팀원에게 리뷰를 요청합니다.

10. **최소 2명 승인**: 팀원 **최소 2명**의 Approve와 모든 대화 resolve가 있어야 머지할 수 있습니다.

11. **Squash merge**: 머지 방식은 **squash만 허용**합니다.
    머지 커밋 제목은 `<type>: <설명> (#PR번호)` 형식으로 작성합니다.

---

## 브랜치 네이밍 규칙

| 유형 | 패턴 | 예시 |
|------|------|------|
| 기능 개발 | `feat/이슈번호-간략한-설명` | `feat/42-add-cloud-run-job` |
| 버그 수정 | `fix/이슈번호-간략한-설명` | `fix/57-iam-permission-error` |
| 실험 | `exp/이슈번호-간략한-설명` | `exp/61-terraform-state-backend` |
| 문서 | `docs/이슈번호-간략한-설명` | `docs/30-update-readme` |
| 리팩터링 | `refactor/이슈번호-간략한-설명` | `refactor/48-split-terraform-module` |
| 기타 | `chore/이슈번호-간략한-설명` | `chore/10-setup-ci` |

- 영어 소문자와 하이픈(`-`)만 사용합니다.
- 이슈 번호를 반드시 포함합니다.

---

## 커밋 컨벤션

```
<type>: <설명>
```

### Type 목록

| type | 사용 상황 |
|------|-----------|
| `feat` | GCP 인프라 리소스, IaC, GitHub 자동화 추가 |
| `fix` | 인프라 설정, 권한, workflow, 문서 오류 수정 |
| `refactor` | 동작 변화 없는 IaC/문서/설정 구조 정리 |
| `docs` | 문서 추가·수정 |
| `chore` | 저장소 기본 설정, CODEOWNERS, 관리 작업 |
| `exp` | GCP 구성, Terraform 방식, 운영 자동화 실험 |

### 예시

```
feat: Cloud Run Job 인프라 정의 추가
fix: Secret Manager 접근 권한 수정
exp: Terraform state backend 구성 비교
docs: GCP 운영 가이드 초안 작성
```

- 설명은 한국어로 작성합니다.
- 제목은 현재형 동사로 시작합니다 (추가, 수정, 삭제, ...).
- 제목은 50자 이내로 작성합니다.

---

## main 브랜치 보호 규칙

`main` 브랜치에는 아래 보호 규칙이 적용되어 있습니다.

- **직접 push 금지**: 모든 변경은 PR을 통해서만 반영됩니다.
- **리뷰 승인 필수**: 최소 2명의 팀원 Approve와 모든 대화 resolve가 있어야 머지할 수 있습니다.
- **PR 통과 후 머지**: 설정한 필수 체크가 모두 통과해야 머지할 수 있습니다.
- **머지 방식**: squash만 허용.

> GitHub 레포 설정 → Settings → Branches → Branch protection rules 에서 확인할 수 있습니다.

## 인프라 변경 리뷰 원칙

- GCP 리소스의 프로젝트, 리전, 이름, 비용 영향을 확인합니다.
- IAM 권한은 최소 권한 원칙을 따릅니다.
- Secret 값은 코드, 로그, PR 본문에 포함하지 않습니다.
- Terraform state, service account key, `.env` 파일은 커밋하지 않습니다.
- 삭제/교체/권한 확대 변경은 롤백 방법을 PR에 적습니다.
