# Agent Orchestration API v0.9.0 승격 설계

> 대상 환경: dev
>
> 기반 변경: [Autoresearch-infra PR #592](https://github.com/SKYAHO/Autoresearch-infra/pull/592)
>
> 애플리케이션 release: v0.9.0

## 목적

launcher와 executor가 이미 v0.9.0으로 배포된 상태에서 API만 이전 digest에 남아 있다.
API v0.9.0 digest를 모든 실행 참조에 반영해 같은 release의 API·migration·검증 경로가
동일한 immutable image를 사용하도록 한다.

## 결정

### 1. API image 참조 전체를 원자적으로 교체

현재 API digest는
`sha256:e8886396c00a6c919cb28d49c7ad4de836b0de07a685da5db7a166384e72f066`이고,
v0.9.0 적용 digest는
`sha256:4d7d156cd08d1e5ebfa0c0283026d72ea7504dfaa40aa837edc917627b107c24`이다.

다음 7개 참조를 모두 새 digest로 교체한다.

| manifest | 참조 수 | 역할 |
|---|---:|---|
| `api-deployment.yaml` | 2 | API 본 컨테이너·DB bootstrap |
| `api-migration-job.yaml` | 2 | migration bootstrap·migration |
| `deployment-verification-job.yaml` | 1 | PostSync API 검증 |
| `runner-deployment.yaml` | 1 | runner Codex auth bootstrap |
| `launcher-cronjob.yaml` | 1 | launcher DB bootstrap |

저장소의 digest promotion helper가 API repository에 대해 위 파일·참조 수를 고정하고
있으므로, 일부 manifest만 교체하는 부분 승격은 허용하지 않는다.

### 2. 변경하지 않는 범위

기존 PR #592에서 적용한 launcher/executor digest와 학습 환경 변수는 유지한다. UI와
runner application image digest, 자원 request/limit, CronJob `suspend`, IAM/GCP resource,
NetworkPolicy는 변경하지 않는다. API image를 v0.9.0으로 맞추는 데 필요한 7개 참조만
변경한다.

### 3. 운영·rollback

ArgoCD sync 후 API Deployment와 migration/PostSync hook이 모두 새 digest를 사용했는지
확인한다. launcher 재개와 학습 실험 검증은 기존 운영 경계를 유지한다.

장애 시 launcher를 먼저 suspend하고 API image 7개 참조를 직전
`sha256:e8886396c00a6c919cb28d49c7ad4de836b0de07a685da5db7a166384e72f066`로 함께
되돌린다. launcher/executor 학습 배선과 snapshot bucket IAM은 rollback 대상이 아니다.

## 검증

- API digest promotion self-test가 repository·파일·참조 수와 immutable 형식을 검증한다.
- Agent Orchestration timeout/deployment verification contract와 self-test가 API image
  동등성, API token 참조, PostSync 검증 경계를 계속 확인한다.
- 전체 lint workflow의 Ruby/shell contract, Terraform admin contract test,
  actionlint를 실행한다.
- `git diff --check`와 API old/new digest scan으로 변경 범위를 확인한다.
