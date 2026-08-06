# GitHub 메타데이터·브랜치 형식 강제 구현 계획

1. 최소 권한 `github-metadata.yml`로 Issue·PR metadata 보정과 branch-name-policy check를 추가한다.
2. `branch_ruleset_main.json`에 required check를 선언하고 운영 가이드·PR template을 갱신한다.
3. actionlint, workflow 계약 확인, `git diff --check`를 실행한다.
4. PR merge 전 열린 PR의 branch 형식 영향을 감사하고, PR merge 후 GitHub main ruleset에 같은 required check를 반영한다.
