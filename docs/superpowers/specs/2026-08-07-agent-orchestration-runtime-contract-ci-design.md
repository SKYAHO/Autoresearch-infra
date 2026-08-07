# Agent Orchestration 런타임 계약 CI 검증 설계

## 목적

앱 이미지가 요구하는 환경 변수와 Kubernetes 배포 매니페스트의 연결을 PR 단계에서 대조한다. Secret 값은 읽거나 기록하지 않는다.

## 배경

Phase 2 API 이미지가 `ORCH_EXECUTOR_API_TOKEN`을 필수로 요구하지만 배포 매니페스트가 이를 전달하지 않아 API Pod가 기동하지 못했다. 개별 YAML과 이미지가 각각 유효해도 두 저장소의 계약이 어긋날 수 있다.

## 결정

앱 저장소가 변수명, Secret key, 역할 분리 규칙만 담은 정적 JSON 계약을 제공한다. infra 저장소의 Ruby 계약 검사가 해당 JSON과 `deploy/agent-orchestration/api-deployment.yaml`을 함께 읽어 다음을 검증한다.

- API 필수 환경 변수가 존재한다.
- Secret 기반 변수는 지정된 Secret key를 참조한다.
- executor 보고 토큰은 API 요청 토큰 및 Runner 토큰과 다른 Secret 참조를 사용한다.

검사는 JSON 값과 manifest의 이름·key만 다루며 Secret 객체, 토큰 원문, Terraform state, 실제 tfvars에는 접근하지 않는다. 앱 계약은 immutable source SHA로 가져오지 않고 infra 저장소에 검토 가능한 복사본으로 둔다. 계약 변경은 앱 PR과 infra PR을 함께 검토해야 한다.

## 범위

이번 변경은 API Deployment의 런타임 환경 변수 계약만 다룬다. migration Job·launcher·executor Pod의 이미지 digest 정합과 실제 GKE smoke는 별도 계약으로 유지하거나 후속 변경에서 확장한다.

## 실패와 롤백

검증 오류는 `lint`를 실패시켜 merge를 막는다. 배포 리소스, IAM, Secret 값은 바꾸지 않으므로 운영 롤백은 infra PR을 revert해 이전 검증 규칙으로 되돌리는 것이다. 단, 누락을 허용하도록 검사를 약화하는 롤백은 API 배포 전에만 승인할 수 있다.

## 검증

- 정상 계약과 정상 매니페스트는 통과한다.
- `ORCH_EXECUTOR_API_TOKEN` 누락 fixture는 실패한다.
- 잘못된 Secret key와 토큰 역할 재사용 fixture는 실패한다.
- Ruby self-test, `git diff --check`, actionlint를 실행한다.
