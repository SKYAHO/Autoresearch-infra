# Agent Orchestration digest 자동 승격 설계

검증을 마친 Autoresearch release가 infra `main`의 Agent Orchestration image digest를 자동으로 갱신하고, ArgoCD가 이를 sync한다.

release workflow는 API·UI·launcher·runner·executor digest가 OCI revision과 non-root 계약을 통과한 뒤에만 전용 GitHub App token을 발급한다. 이 token은 infra 저장소에만 `contents: write` 권한을 가진다. workflow는 infra `main`을 checkout해 저장소 소유 Ruby 승격 스크립트를 실행하고, script가 API 일곱 참조와 UI·launcher·runner·executor 각 한 참조를 같은 release 입력 값으로 바꾼 경우에만 bot commit을 push한다.

입력은 immutable `repository@sha256:<64 hex>` 형식이며, 다섯 repository가 각각 고정된 GAR 이름과 일치해야 한다. script는 허용된 YAML 파일의 고정된 참조 수만 바꾸고, 현재 API 일곱 참조와 네 개의 단일 참조가 불일치하거나 잘못된 digest·의도하지 않은 변경이 있으면 즉시 실패시킨다. 동일 digest면 commit 없이 성공한다. 동시 release는 application workflow concurrency로 직렬화한다.

GitHub App의 ID와 private key는 Autoresearch repository secret으로만 등록한다. 값은 코드·로그·PR에 남기지 않는다. App 설치 권한은 Autoresearch-infra 단일 repository의 Contents read/write로 제한한다. `main-protection` Ruleset에는 이 App만 bypass actor로 등록해, 사람과 일반 token의 직접 push 금지를 유지한다. rollback은 이전 검증 digest를 workflow_dispatch 입력으로 다시 승격하거나, infra main의 이전 digest commit을 revert한다.
