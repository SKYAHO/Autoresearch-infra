# Agent Orchestration Experiment API v0 배포 계획

> **실행 방식:** ArgoCD PreSync Alembic Job을 추가하고, #483 merge commit으로 발행한
> immutable API image를 다섯 container 참조에 원자적으로 반영합니다.

## 1. 배포 manifest와 정적 계약

- `api-migration-job.yaml`에 API KSA·memory `emptyDir`·기존 DB bootstrap을 사용한
  PreSync Job을 추가합니다.
- API digest 계약 checker를 다섯 container 참조로 확장하고, migration image 불일치 음성 테스트를
  추가합니다.
- `kubectl apply --dry-run=client`, Ruby checker와 self-test를 실행합니다.

## 2. 운영 문서

- runbook에 PreSync 실행 순서, API KSA 재사용 범위, migration 실패 처리,
  downgrade 없는 rollback, Experiment API와 `/chat` 공통 gate를 기록합니다.

## 3. 배포 실행

- release workflow가 #483 source SHA의 API digest를 검증해 출력한 뒤 manifest 다섯 container 참조에
  정확히 반영합니다.
- infra PR을 검토·머지한 뒤 merge SHA를 `AGENT_ORCHESTRATION_TARGET_REVISION`에 지정하고,
  reviewed Terraform admin apply와 ArgoCD manual sync를 순서대로 실행합니다.
- migration Job 성공, API rollout, OpenAPI endpoint, 인증된 Experiment API, `/chat`와
  PostgreSQL 저장을 확인합니다.

## 검증 체크리스트

- [ ] immutable digest 다섯 container 참조 일치
- [ ] PreSync Job은 OAuth·요청 토큰 mount 없음
- [ ] NetworkPolicy는 API 기존 egress 범위만 사용
- [ ] Ruby contract checker 및 self-test 통과
- [ ] Kubernetes client dry-run 통과
- [ ] `git diff --check` 및 시크릿 패턴 검사 통과
- [ ] ArgoCD sync 후 migration/API/기존 chat end-to-end gate 통과
