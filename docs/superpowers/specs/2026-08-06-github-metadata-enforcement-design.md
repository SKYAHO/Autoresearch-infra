# GitHub 메타데이터·브랜치 형식 강제 설계

Issue Form은 유형 label을 설정하지만 PR Markdown template은 GitHub metadata를 설정할 수 없고, 둘 다 동적 assignee를 설정할 수 없다. 따라서
GitHub Actions가 Issue·PR 생성 직후 메타데이터를 보정하고, PR check가 이슈 연결 영어
브랜치 형식을 검사한다. `pull_request_target` job은 checkout·시크릿 없이 GitHub API만
호출하며 `issues`·`pull-requests` write 권한만 갖는다.

Issue는 작성자 assignee를 설정하고 API 응답의 assignee 목록으로 결과를 확인한다. 작성자가
지정되지 않았거나 요청이 실패하면 repository variable `DEFAULT_GITHUB_ASSIGNEE`로 대체하고,
fallback 결과도 검증한다. PR은 synchronize마다 변경 경로로 `documentation`,
`terraform`·`gcp`, `ci-cd`, `chore` label을 더하고 같은 assignee 정책을 적용한다.

branch-name-policy는 `<type>/<issue-number>-<english-lowercase-hyphen-slug>`와 GitHub Revert 자동 브랜치만
통과시킨다. main ruleset의 required check로 등록해 형식 위반을 병합 전에 차단한다.
`DEFAULT_GITHUB_ASSIGNEE`는 merge 전 Repository variable로 등록한다. 롤백은 ruleset에서
해당 check를 제거한 뒤 workflow를 되돌리는 순서다.
