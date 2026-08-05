# GKE Deployment Digest 승격 PR 설계

## 목적

`SKYAHO/Autoresearch` 릴리스가 검증한 immutable 이미지 digest를 이 저장소의
GKE 매니페스트에 반영하는 **Draft PR만** 자동 생성한다. 자동화가 main에 직접
push·merge하거나 ArgoCD sync, Terraform apply, GitHub Actions Variable 변경을
수행하지 않는다.

## 결정

- 자동 승격 범위는 serving, Agent Orchestration API·UI·Runner다. MLflow는 현재
  앱 release workflow가 해당 이미지의 검증 digest를 출력하지 않으므로 자동화에서
  제외하고 수동 PR 절차를 유지한다. MLflow release job을 별도 이슈에서 도입한 뒤
  이 도구의 `--mlflow-digest` 입력으로 확장한다.
  API digest는 다섯 container 참조를 한 트랜잭션처럼 같은 값으로 바꾼다.
- 치환 정본은 infra 저장소의 Python 도구로 둔다. 이 도구는
  `asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/`
  prefix와 `@sha256:` 64자리 소문자 hex digest만 허용한다.
- 각 대상은 기대한 횟수만 정확히 치환해야 한다. serving·MLflow·UI·Runner는
  각 1건, API는 5건이다. 누락·중복·기존 API digest 불일치는 실패한다.
- 앱 release workflow는 기존 GitHub App 토큰을 `Autoresearch-infra` 한 저장소에
  한정해 발급하고, 해당 저장소를 checkout한 뒤 도구를 실행한다. PR 생성 action의
  `add-paths`도 여섯 manifest 파일과 문서 파일만 허용한다.
- GitHub App installation에 `Autoresearch-infra`가 포함되지 않았다면 workflow는
  실패해야 하며, 권한을 넓히거나 PAT로 우회하지 않는다.

## 배포 경계

- serving Application은 main 추적·automated sync이므로, 사람이 승격 PR을 merge한
  뒤 ArgoCD가 반영한다.
- MLflow는 main 추적이나 manual sync다. merge 뒤 ArgoCD diff를 검토하고 운영자가
  sync한다.
- Agent Orchestration은 manifest commit SHA를
  `AGENT_ORCHESTRATION_TARGET_REVISION`으로 설정하고 reviewed admin apply 후
  manual sync해야 한다. Draft PR 생성 및 merge만으로는 배포되지 않는다.

## 보안·롤백

- workflow 기본 권한은 `contents: read`를 유지하고, 교차 저장소 쓰기는 GitHub
  App installation token으로만 수행한다.
- digest는 mutable tag가 아닌 release workflow가 검증한 `image@sha256:...`만
  수용한다. secret·state·tfvars는 도구 출력과 PR 본문에 포함하지 않는다.
- 승격 PR을 닫거나 revert하면 다음 sync 대상에서 새 digest가 제거된다. 이미
  sync된 배포의 롤백은 이전 검증 digest를 담은 별도 PR과 동일한 운영 게이트로
  수행한다.
