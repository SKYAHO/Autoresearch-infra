# agent-orchestration v0.8.0 롤아웃 실행 기록

## 목적

`SKYAHO/Autoresearch` v0.8.0 릴리즈가 빌드한 API·UI 이미지를 dev GKE의
`agent-orchestration`에 반영한다. 릴리즈 파이프라인은 batch·training·feast에는
승격 PR을 자동 생성하지만 agent-orchestration 계열은 job summary에 digest만 기록하고
끝나므로, 이 승격은 사람이 수행한다.

이 단계를 건너뛰면 릴리즈가 성공해도 클러스터는 이전 digest를 계속 서비스한다.
실제로 v0.8.0 게시(2026-08-07T08:08:56Z) 뒤에도 UI Pod는 이전 이미지로 남아 있었다.

## 검증된 이미지

- Release: `v0.8.0`
- Release workflow: `https://github.com/SKYAHO/Autoresearch/actions/runs/31160511444`
- API digest: `sha256:e8886396c00a6c919cb28d49c7ad4de836b0de07a685da5db7a166384e72f066`
  - 이전: `sha256:be70b05db1a6a7bae0bb283f43c58137cb9c3090bef32bbea58fd0fcfe4e1b21`
- UI digest: `sha256:c354c4b975b2b978b1de94a5a74fe0568cb6aef93297dc0cde4b0eb14dd9e500`
  - 이전: `sha256:daa61f264b8e269c6f004016321fe5fe0778754da7f98d8e03c8fb739cde26a2`

## 변경 범위

- API image 참조 6곳을 갱신한다. 여섯 곳은 반드시 같은 값이어야 한다 —
  `api-deployment.yaml`(컨테이너·initContainer), `api-migration-job.yaml`(2곳),
  `launcher-cronjob.yaml` bootstrap initContainer, `runner-deployment.yaml`
  initContainer.
- `ui-deployment.yaml`의 UI image digest를 갱신한다.
- `scripts/check-experiment-launcher-manifest-contract.rb`의 기대 bootstrap image를
  같은 값으로 맞춘다. 이 스크립트가 API digest를 하드코딩하므로 매니페스트만 바꾸면
  계약 검사가 실패한다.
- Runner(`sha256:16d6383e7393…`), Launcher(`sha256:9462365e1ed0…`),
  Executor(`sha256:b80b290db63d…`) 이미지도 같은 릴리즈에서 빌드됐으나 이 PR에서는
  건드리지 않는다. 필요하면 별도 이슈로 승격한다.

## 이번 롤아웃에 담기는 애플리케이션 변경

`SKYAHO/Autoresearch` #573이 사전등록 계약을 바꿨다.

- Streamlit 사전등록 폼이 실험 제목과 마크다운 가설 두 칸으로 줄었다.
- `IssuePublicationRequest`에서 `allowed_scope`가 사라졌다. UI가 보내지 않는 방향의
  변경이라 옛 API도 새 UI의 요청을 받아들이지만, 발행되는 이슈 본문이 줄어드는 것은
  API 쪽 변경이므로 **API를 함께 올려야 효과가 난다.**
- 이슈 본문이 heading 21개에서 `### 연구 가설` 하나로 줄었다. 파서는 `연구 가설`만
  필수로 본다.

## 검증

```bash
ruby scripts/check-agent-orchestration-timeout-contract.rb
ruby scripts/test-agent-orchestration-timeout-contract.rb
ruby scripts/check-experiment-launcher-manifest-contract.rb
ruby scripts/test-check-experiment-launcher-manifest-contract.rb
git diff --check
```

## 머지 이후 확인

Application `agent-orchestration`의 `targetRevision`은 `main`이므로 머지하면 ArgoCD가
따라온다(#526 automated sync). 상시 절차는
`docs/runbooks/2026-07-30-agent-orchestration-gke.md`가 정본이다.

API image가 바뀌므로 PreSync migration Job이 다시 돈다. 실패하면 Deployment는
갱신되지 않고 옛 Pod가 계속 서비스한다.

```bash
kubectl -n autoresearch get job agent-orchestration-api-migration \
  -o jsonpath='{.status.succeeded}{"\n"}'   # 1

kubectl -n autoresearch get deploy \
  -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
kubectl -n autoresearch rollout status deploy/agent-orchestration-api --timeout=180s
kubectl -n autoresearch rollout status deploy/agent-orchestration-ui --timeout=180s
```

runbook의 공통 post-sync end-to-end gate를 통과시킨 뒤, 이번 롤아웃 고유의 확인을
수행한다.

```bash
kubectl -n autoresearch port-forward svc/agent-orchestration-ui 8501:8501
```

사전등록 화면에 입력칸이 **실험 제목과 가설 둘만** 보이고, 가설 편집창 옆에 미리보기가
붙어 있으면 UI가 갱신된 것이다. 제출해서 열린 `[AR]` 이슈 본문이 `### 연구 가설`
하나로 끝나면 API까지 갱신된 것이다.

## 검증 체크리스트

- [ ] 계약 스크립트 4종 통과
- [ ] `git diff --check` 통과
- [ ] migration Job `succeeded=1`
- [ ] API·UI Deployment가 v0.8.0 digest로 Ready
- [ ] 사전등록 화면 입력칸이 제목·가설 둘
- [ ] 발행된 `[AR]` 이슈 본문이 `### 연구 가설` 하나
