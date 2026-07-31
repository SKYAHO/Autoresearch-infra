# Agent Orchestration GPT-5.6 Luna 전환 설계

## 목적

공용 Codex OAuth Runner의 전역 기본 모델을 `gpt-5.3-codex-spark`에서
`gpt-5.6-luna`로 전환한다. 현재 MVP의 단일 채팅 응답 생성·PostgreSQL 저장 흐름에서
비용 효율을 우선한다.

## 변경 범위

- `deploy/agent-orchestration/runner-deployment.yaml`의 Runner `CODEX_MODEL` 값을
  `gpt-5.6-luna`로 변경한다.
- 변경 commit의 고정 SHA를 Argo CD Application target revision으로 적용하고 manual
  sync한다.
- 내부 `/chat` 호출로 HTTP 201, 반환 모델명, PostgreSQL 저장 ID를 확인한다.

## 변경하지 않는 범위

- 공용 Codex OAuth bootstrap 시크릿과 Runner PVC
- API·Runner 요청 토큰, Cloud SQL 연결·권한, API JSON 계약
- 이미지 digest, NetworkPolicy, 사용자별 모델 선택

## 설계 결정

모델 값은 GitOps manifest의 `CODEX_MODEL` 단일 출처로 유지한다. `kubectl set env`나
Pod 직접 수정은 Argo CD의 다음 동기화에서 되돌아갈 수 있으므로 사용하지 않는다.
`gpt-5.6-luna`의 Codex OAuth 계정 호환성은 manifest 변경만으로 보장할 수 없으므로,
배포 뒤 실제 `/chat` 요청으로 검증한다.

## 실패 처리와 롤백

Runner가 Ready가 되지 않거나 `/chat` 호출이 201을 반환하지 않으면 추가 호출을
중단한다. 직전 검증 commit의 `CODEX_MODEL` 값으로 되돌린 새 manifest commit을 만들고,
동일한 target revision apply 및 Argo CD manual sync 절차로 복구한다. OAuth 시크릿·PVC·DB
권한은 변경하지 않으므로 이 전환의 롤백 대상이 아니다.

## 완료 조건

1. Argo CD Application이 `Synced` 및 `Healthy`다.
2. API와 Runner Pod가 Ready이고 재시작이 없다.
3. 인증된 내부 `POST /chat`이 HTTP 201을 반환한다.
4. 응답의 `model`은 `gpt-5.6-luna`이고 저장 행 `id`가 반환된다.
