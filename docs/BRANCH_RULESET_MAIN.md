# main 브랜치 Ruleset

이 문서는 `branch_ruleset_main.json`으로 적용하는 GitHub Repository Ruleset을 설명합니다.

## 적용 대상

- Repository: `SKYAHO/Autoresearch-infra`
- Branch: `main`
- Enforcement: `active`

## 강제 규칙

| 규칙 | 내용 | 목적 |
|---|---|---|
| Pull Request 필수 | `main`에는 직접 push하지 않고 PR을 통해서만 반영합니다. 최소 2명 승인과 모든 review thread 해결이 필요합니다. | 검증 없는 변경이 기준 브랜치에 들어가는 것을 방지합니다. |
| 필수 status checks | `lint` status check가 통과해야 merge할 수 있습니다. | 최소한의 자동 검증 없이 기준 브랜치에 반영되는 것을 방지합니다. |
| stale review 무효화 | 새 커밋이 PR에 push되면 기존 승인을 무효화합니다. | 리뷰 이후 바뀐 코드가 승인 없이 merge되는 것을 막습니다. |
| force push 차단 | `main`에 대한 non-fast-forward push를 차단합니다. | 기준 브랜치 히스토리 손상을 방지합니다. |
| branch 삭제 차단 | `main` 브랜치 삭제를 차단합니다. | 기준 브랜치 삭제 사고를 방지합니다. |

## 적용 파일

```text
branch_ruleset_main.json
```

## 적용 방법

관리자 권한이 있는 GitHub token으로 아래 API를 호출합니다.

```bash
gh api \
  --method POST \
  repos/SKYAHO/Autoresearch-infra/rulesets \
  --input branch_ruleset_main.json
```

이미 같은 이름의 ruleset이 있으면 새로 만들지 말고 기존 ruleset을 update합니다.

## 주의사항

- `bypass_actors`가 비어 있어 관리자 포함 모든 사용자에게 동일하게 적용됩니다.
- `lint` check는 GitHub Actions workflow 문법을 actionlint로 확인합니다.
- merge method는 `squash`만 허용합니다.
