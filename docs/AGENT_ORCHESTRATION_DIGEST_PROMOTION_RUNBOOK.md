# Agent Orchestration Digest 자동 승격 Runbook

검증된 `Autoresearch` release의 Agent Orchestration API·UI·launcher·runner·executor immutable digest를
`Autoresearch-infra`의 `main` manifest에 자동 반영하는 운영 절차입니다. `main`
갱신 뒤에는 Agent Orchestration ArgoCD Application이 automated sync하고, PostSync
검증 Job이 배포 결과를 확인합니다.

## 신뢰 경계

- `Autoresearch` release workflow는 OCI revision·non-root 검증을 통과한 API·UI·launcher·runner·executor
  digest만 승격 입력으로 사용합니다.
- GitHub App은 `Autoresearch-infra` 단일 저장소에만 설치하고 Contents
  read/write 권한만 부여합니다. Actions, Pull requests, Administration 등 다른
  repository 권한은 부여하지 않습니다.
- App ID와 private key는 `Autoresearch` repository secret `APP_ID`,
  `APP_PRIVATE_KEY`로만 보관합니다. 값은 workflow 출력, commit, PR, 문서에
  기록하지 않습니다.
- `main-protection` Ruleset bypass actor에는 이 GitHub App만 등록합니다. 사람,
  `GITHUB_TOKEN`, 개인 access token은 직접 push할 수 없어야 합니다.
- infra 저장소의 `scripts/promote-agent-orchestration-digests.rb`는 API 일곱,
  UI·launcher·runner·executor 각 한 참조만 허용하며, 고정 GAR repository와
  `@sha256:<64자리-소문자-hex>` 형식이 아닌 입력은 실패시킵니다.

## 최초 설정

1. GitHub App을 `SKYAHO/Autoresearch-infra`에만 설치하고 Contents read/write
   권한만 허용합니다.
2. App의 ID와 private key를 `SKYAHO/Autoresearch` repository secret으로
   등록합니다. secret 값의 화면 캡처·CLI 출력·문서 기록은 금지합니다.
3. **Autoresearch release workflow 호출부가 merge된 뒤에만**, GitHub 관리자만
   `main-protection` Ruleset의 bypass actor에 해당 GitHub App을
   추가합니다. bypass는 `Autoresearch-infra`의 release digest 갱신에만
   사용하며, 다른 App·사용자·token은 추가하지 않습니다.
4. `Autoresearch` release workflow의 자동 승격 Job을 활성화합니다.
5. 검증된 release 한 건으로 실행한 뒤, infra commit의 변경 파일이
   `deploy/agent-orchestration/`의 허용 manifest 여섯 개뿐인지, ArgoCD sync와
  PostSync Job이 성공했는지 확인합니다.

## 신뢰 경계의 한계

infra script는 호출될 때만 manifest 범위를 강제합니다. App token은 Contents
write와 `main` bypass를 가지므로 실질적인 신뢰 경계는 `Autoresearch`의 release
workflow 변경 권한과 release 게시 승인입니다. 해당 workflow 파일은 CODEOWNERS
승인으로 보호하고, App key를 읽을 수 있는 workflow·secret 접근자를 최소화해야
합니다.

## 일상 확인

자동 승격 commit에는 source release SHA와 workflow run URL을 남깁니다. 운영자는
다음 순서로 확인합니다.

1. `Autoresearch` release workflow에서 API·UI·launcher·runner·executor build, OCI revision, non-root,
   infra promotion Job이 모두 성공했는지 확인합니다.
2. infra `main` commit에서 API 일곱 참조와 UI·launcher·runner·executor 각 한 참조가
   같은 release의 immutable digest로만 바뀌었는지 확인합니다.
3. ArgoCD Application이 `Synced`와 `Healthy`인지, PostSync verification Job이
   성공했는지 확인합니다. 세부 확인은
   [`ARGOCD_OPERATIONS_RUNBOOK.md`](ARGOCD_OPERATIONS_RUNBOOK.md)를 따릅니다.

## 실패와 롤백

- 승격 script가 repository, digest 형식, 참조 수, 기존 API digest 불일치를
  감지하면 commit 없이 실패합니다. 원인을 수정하기 전 수동 manifest 편집이나
  Ruleset 완화로 우회하지 않습니다.
- App token 생성 또는 push가 실패하면 App 설치 범위와 Ruleset bypass actor를
  읽기 전용으로 확인합니다. `main`의 직접 push 금지를 해제하지 않습니다.
- 잘못된 digest가 배포된 경우에는 이전에 검증된 다섯 image digest를 release
  `workflow_dispatch` 입력으로 다시 승격합니다. 자동화 경로 자체가 장애이면
  이전 digest를 반영하는 일반 infra rollback PR을 squash merge하고 ArgoCD sync와
  PostSync 결과를 확인합니다.
- 긴급 복구를 위해 `kubectl apply`로 Git desired state를 우회하지 않습니다.
  Git 이력이 배포 이력이며, 긴급 조치는 반드시 후속 revert commit으로 정합을
  복구합니다.
