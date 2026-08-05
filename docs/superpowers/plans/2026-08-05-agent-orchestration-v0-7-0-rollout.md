# agent-orchestration v0.7.0 롤아웃 실행 계획

> **실행 방식:** 1단계는 이 PR에서 끝납니다. 2단계부터는 머지 이후 운영자가 순서대로
> 수행하며, 각 단계의 확인이 통과해야 다음으로 넘어갑니다. 설계 근거는
> `docs/superpowers/specs/2026-08-05-agent-orchestration-v0-7-0-rollout-design.md`,
> 상시 운영 절차는 `docs/runbooks/2026-07-30-agent-orchestration-gke.md`가 정본입니다.

## 1. 매니페스트·문서 변경 (이 PR)

1. `deploy/agent-orchestration/`의 이미지 참조 6곳을 `v0.7.0` digest로 갱신합니다.
   API 5곳은 반드시 같은 값이어야 합니다.
2. `api-deployment.yaml`의 API 컨테이너에 환경변수 4종을 추가합니다.
   `ORCH_GITHUB_TOKEN`만 `secretKeyRef`이고 나머지 셋은 리터럴입니다.
3. 같은 컨테이너에 `/tmp` emptyDir(64Mi)을 mount합니다.
4. `network-policy.yaml`의 `agent-orchestration-api-egress`에 공개 인터넷 TCP 443
   규칙을 사설 대역 `except`와 함께 추가합니다.
5. runbook에 Secret 등록 절차, 환경변수 계약, egress 경계 변경을 반영합니다.

확인:

```bash
ruby scripts/check-agent-orchestration-timeout-contract.rb
ruby scripts/test-agent-orchestration-timeout-contract.rb
git diff --check
```

## 2. GitHub 토큰 발급·등록 (머지 전에 끝내도 됩니다)

`SKYAHO/Autoresearch` 한 저장소에만 `Issues: Read and write`를 준 fine-grained PAT을
발급하고, runbook의
[이슈 발행 GitHub 토큰 등록](../../runbooks/2026-07-30-agent-orchestration-gke.md#이슈-발행-github-토큰-등록-525)
절차로 Secret을 만듭니다.

**이 단계를 건너뛰고 sync하면 API Pod가 기동하지 못합니다.**

확인:

```bash
kubectl -n autoresearch get secret agent-orchestration-github-token \
  -o jsonpath='{.data.ORCH_GITHUB_TOKEN}' | base64 -d | od -c | tail -2
# 길이가 0이 아니어야 하고, 마지막 바이트가 \n 이 아니어야 합니다.
# 값 자체가 터미널에 찍히므로 화면 공유 중에는 실행하지 마십시오.
```

## 3. 머지와 target revision 갱신

1. 이 PR을 squash merge하고 머지 커밋의 소문자 40자 SHA를 확인합니다.
2. Actions Variable `AGENT_ORCHESTRATION_TARGET_REVISION`을 그 SHA로 갱신합니다.
   `AGENT_ORCHESTRATION_DEPLOYMENT_ENABLED`는 이미 `true`입니다.
3. `apply.yml`을 `scope: admin`으로 실행해 reviewed plan을 확인한 뒤 apply합니다.

확인:

```bash
kubectl -n argocd get application agent-orchestration \
  -o jsonpath='{.spec.source.targetRevision}{"\n"}'
# 2번에서 넣은 SHA와 일치해야 합니다
```

## 4. ArgoCD 전체 sync

ArgoCD UI에서 diff를 확인한 뒤 **전체 sync**를 실행합니다. 리소스를 골라 sync하면
PreSync hook이 건너뛰어져 Alembic이 실행되지 않은 채 새 이미지만 올라갑니다.

확인:

```bash
kubectl -n autoresearch get job agent-orchestration-api-migration \
  -o jsonpath='{.status.succeeded}{"\n"}'   # 1

kubectl -n autoresearch get deploy \
  -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
kubectl -n autoresearch rollout status deploy/agent-orchestration-api --timeout=180s
```

migration Job이 실패하면 Deployment는 갱신되지 않고 옛 Pod가 계속 서비스합니다.
`kubectl -n autoresearch logs job/agent-orchestration-api-migration -c migrate`로
원인을 확인하고, 해결 전까지 다음 단계로 넘어가지 않습니다.

## 5. 배포 확인

runbook의 [공통 post-sync end-to-end gate](../../runbooks/2026-07-30-agent-orchestration-gke.md#공통-post-sync-end-to-end-gate)를
먼저 통과시킨 뒤, 이번 롤아웃 고유의 확인을 수행합니다.

```bash
kubectl -n autoresearch port-forward svc/agent-orchestration-api 8000:8000 &
curl -s localhost:8000/openapi.json | jq -r '.paths | keys[]' \
  | grep -E '/experiments/\{experiment_id\}/(issue|steps)'
# 두 줄이 모두 나와야 합니다
```

마지막으로 UI 사전등록 폼에서 실험을 제출해 `[AR]` 이슈가 열리고
`auto-experiment` label이 붙는지 확인합니다. 발행이 502면 토큰 또는 egress 문제이며,
`kubectl -n autoresearch logs deploy/agent-orchestration-api`로 분류를 확인합니다.

## 검증 체크리스트

- [ ] `ruby scripts/check-agent-orchestration-timeout-contract.rb` 통과
- [ ] `git diff --check` 통과
- [ ] `agent-orchestration-github-token` Secret 등록 확인
- [ ] Application `targetRevision`이 머지 SHA와 일치
- [ ] migration Job `succeeded=1`
- [ ] API·UI·Runner Deployment가 `v0.7.0` digest로 Ready
- [ ] `/openapi.json`에 `/issue`·`/steps` 노출
- [ ] UI 제출로 `[AR]` 이슈 발행 + `auto-experiment` label 확인
- [ ] `/chat` gate 통과 (Runner digest 승격 검증)
