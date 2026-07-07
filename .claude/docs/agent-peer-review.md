# Peer Review Execution Guide

> Last Updated: 2026-07-07

코드/diff 리뷰에 사용하는 가이드입니다. 계획 문서 리뷰는
`agent-plan-review.md`를 사용합니다.

## When To Use This Doc

- 변경이 여러 리소스나 네트워크·IAM 경계에 걸칠 때
- workflow, ruleset, 배포 동작이 바뀌었을 때
- 커밋이나 PR 생성 전 최종 품질 점검이 필요할 때
- PR 리뷰를 수행할 때

## Default Review Perspectives

| 관점 | 초점 |
| --- | --- |
| Critic | 기존 저장소 패턴에 맞는가, 의도치 않은 리소스 교체·삭제가 없는가 |
| Code quality | 파일 구성이 규칙을 따르는가, 변수·locals·outputs 배치가 정당한가 |
| Convention | 이름, 변수 설명, 문서, 커밋 형식이 저장소 규칙을 따르는가 |
| Security | 시크릿, state, IAM, 네트워크 노출, workflow 권한이 안전한가 |
| Cost | 리소스 크기, 리전, 과금 요소가 dev 최소 비용 기준에 맞는가 |

IAM, 방화벽, workflow, 배포 설정이 바뀌었으면 Security 관점을 반드시
포함합니다.

## Review Focus (CLAUDE.md 리뷰 가이드와 동일)

심각도 순으로:

1. 정확성 버그와 기존 인프라 동작의 의도치 않은 변경 (destroy/replace)
2. 시크릿·자격 증명·state 노출 위험
3. IAM 권한 확대와 최소 권한 원칙 위반
4. 비용, quota, 리전 영향
5. 삭제/교체/권한 확대 변경의 롤백 방법 누락
6. workflow `permissions`와 GitHub secret 처리

## Review Prompt Template

```text
autoresearch-infra의 현재 diff를 critic, code quality, convention,
security, cost 관점에서 리뷰하라. 의도치 않은 리소스 교체·삭제, 시크릿
·state 노출, IAM 권한 확대, 비용 영향, CLAUDE.md 및 .claude/docs/*.md
위반에 집중하라. 발견 사항을 파일·라인 참조와 함께 심각도 순으로
반환하라. 발견 사항이 없으면 남은 검증 리스크를 명시하라.
```

## Output Rules

- 발견 사항을 심각도 순으로 먼저 제시합니다.
- 파일과 라인 참조를 포함합니다.
- 칭찬은 나열하지 않습니다.
- 요약보다 구체적 발견이 우선입니다.
- plan 검증 공백(plan 미실행, plan 결과 미첨부)을 명시적으로
  지적합니다.
- 구체적 이슈는 인라인 코멘트로, 요약 코멘트는 짧게 유지합니다.
