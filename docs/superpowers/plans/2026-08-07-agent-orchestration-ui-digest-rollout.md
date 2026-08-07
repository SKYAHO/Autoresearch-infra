# Agent Orchestration UI digest 롤아웃 실행 기록

## 목적

Autoresearch PR #572에서 구현한 Streamlit 가설 등록·상세 화면 분리를 dev GKE의
`agent-orchestration-ui`에 반영한다.

## 검증된 이미지

- Source SHA: `6dd896c2a7f2d0ad3f20b96269100c3a901ee407`
- Release workflow: `https://github.com/SKYAHO/Autoresearch/actions/runs/31144135384`
- UI digest: `sha256:daa61f264b8e269c6f004016321fe5fe0778754da7f98d8e03c8fb739cde26a2`
- 이전 digest: `sha256:526850203a717a0d9264a83c35be9bd8e915008254474587ac7a6dc34e5e4c9c`

## 변경 범위

- `deploy/agent-orchestration/ui-deployment.yaml`의 UI image digest만 갱신한다.
- API, Runner, Launcher, Executor image와 Kubernetes 설정은 변경하지 않는다.
- IAM, Secret, 네트워크, 리전, 비용 영향은 없다.

## 적용과 확인

1. infra PR을 squash merge한다.
2. `main`을 추적하는 Argo CD auto-sync가 새 manifest를 적용한다.
3. `agent-orchestration-ui` Deployment rollout과 `/_stcore/health`를 확인한다.
4. 문제가 있으면 이전 digest로 되돌리는 PR을 생성해 롤백한다.
