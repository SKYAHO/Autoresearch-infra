# Agent Orchestration Experiment API v0 배포 설계

## 상태

- 관련 이슈: [#509](https://github.com/SKYAHO/Autoresearch-infra/issues/509)
- 대상 소스: `SKYAHO/Autoresearch` merge commit `7d1a46c25bc529876ae0bd75d583b081414de6af` (#483)
- 대상 환경: GCP dev / GKE `autoresearch-dev-gke`
- 작성 언어: 한국어

## 목적

#483의 Experiment API v0와 Alembic migration을 기존 Agent Orchestration API에
안전하게 반영한다. 기존 `/chat` 요청·Codex OAuth Runner·`chat_interactions` 저장
동작은 유지해야 한다.

## 범위와 책임

- 이 저장소는 immutable API digest, ArgoCD sync 순서, migration 실행 경계와 운영
  검증을 제공한다.
- 앱 저장소는 Experiment API 모델·Alembic migration·HTTP 계약을 제공한다.
- 새 GCP 리소스, 외부 Ingress, API/Runner OAuth 공유, DB role/IAM 확대는 이번
  변경 범위가 아니다.

## 선택한 구조

ArgoCD `PreSync` hook Job을 API Deployment보다 먼저 한 번 실행한다. Job은 API와
같은 immutable image와 기존 `agent-orchestration-api` KSA를 사용하고,
`bootstrap-db` init container가 현재 API와 동일하게 `/runtime/db.env`를 만든다.
주 컨테이너는 그 파일의 `ORCH_DATABASE_URL` 한 항목만 환경 변수로 설정해
`alembic -c agent_orchestration/alembic.ini upgrade head`를 실행한다.

```text
ArgoCD manual sync
  -> PreSync migration Job (API KSA, DB bootstrap, no OAuth/token mounts)
  -> Alembic upgrade head
  -> API/Runner rollout
  -> authenticated Experiment API + /chat end-to-end gate
```

Job은 OAuth PVC, `ORCH_API_TOKEN`, `ORCH_RUNNER_TOKEN`을 mount하지 않는다. 기존 API
KSA의 DB password bootstrap 접근을 재사용하되, 새 IAM 또는 database privilege는
추가하지 않는다. Job label은 API egress NetworkPolicy selector와 같아 Cloud SQL,
DNS, Workload Identity, Private Google APIs에만 도달한다.

## 실패와 롤백

- migration Job 실패 시 `PreSync`가 sync를 중단하므로 새 API rollout을 시작하지
  않는다. Job log는 credential을 출력하지 않는 범위에서 원인을 확인한다.
- Migration은 `upgrade head`라 재실행 가능하다.
- API digest를 이전 성공 revision으로 되돌릴 수 있다. 기존 API는 추가된
  experiment table을 사용하지 않으므로 DB migration downgrade는 자동 실행하지
  않는다. downgrade는 데이터 손실 위험 때문에 별도 승인·복구 계획이 있어야 한다.

## 완료 조건

- API digest 다섯 container 참조(API main, API DB bootstrap, Runner OAuth bootstrap,
  migration Job의 DB bootstrap과 migration container)가 같은 `@sha256` digest다.
- PreSync Job이 성공한 뒤 Experiment endpoint가 OpenAPI에 노출되고, 인증된 create와
  조회가 성공한다.
- `/chat` 실제 호출과 `chat_interactions` 저장이 계속 성공한다.
- 새 외부 노출, secret 값, IAM 권한 확대가 없다.
