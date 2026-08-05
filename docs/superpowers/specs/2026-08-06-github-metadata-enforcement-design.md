# GitHub 메타데이터·브랜치 형식 강제 설계

Issue Form과 PR Markdown template은 동적 assignee·PR label을 설정할 수 없다. 따라서
GitHub Actions가 Issue·PR 생성 직후 메타데이터를 보정하고, PR check가 이슈 연결 영어
브랜치 형식을 검사한다. `pull_request_target` job은 checkout·시크릿 없이 GitHub API만
호출하며 `issues`·`pull-requests` write 권한만 갖는다.

Issue는 제목 prefix에 맞는 기본 label과 작성자 assignee를 설정한다. 권한 없는 외부
작성자는 기본 담당자 `hyeongyu-data`로 대체한다. PR은 변경 경로로 `documentation`,
`terraform`·`gcp`, `ci-cd`, `chore` label을 더하고 같은 assignee 정책을 적용한다.

branch-name-policy는 `<type>/<issue-number>-<english-lowercase-hyphen-slug>`만
통과시킨다. main ruleset의 required check로 등록해 형식 위반을 병합 전에 차단한다.
롤백은 ruleset에서 해당 check를 제거한 뒤 workflow를 되돌리는 순서다.
