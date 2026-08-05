# agent-orchestration v0.7.0 롤아웃 설계

## 상태

- 관련 이슈: #525 (후속 자동화 분리: #526)
- 대상 소스 commit: `SKYAHO/Autoresearch@73bf762` (릴리스 `v0.7.0`)
- 대상 환경: dev (`autoresearch-503903`, `asia-northeast3`)
- 작성 언어: 한국어

## 목적

실험 워크벤치의 이슈 발행·Step 추적 기능이 머지·이미지 빌드까지 끝났는데 클러스터에
반영되지 않아 사용할 수 없습니다. 배포된 API의 OpenAPI에
`/experiments/{id}/issue`와 `/experiments/{id}/steps`가 없어 UI에서 실험을 제출하면
404가 납니다.

v0.7.0 이미지는 GAR에 이미 존재합니다. 이 문서는 그 이미지를 dev 클러스터에 1회
안전하게 반영하기 위한 설계를 기록합니다.

## 범위와 책임

| 항목 | 소유 | 이번 범위 |
| --- | --- | --- |
| 이미지 build·push | 앱 저장소 `release.yml` | 밖 (이미 완료) |
| Deployment digest·env·volume | 이 저장소 `deploy/agent-orchestration/` | 안 |
| NetworkPolicy egress 경계 | 이 저장소 `deploy/agent-orchestration/` | 안 |
| Alembic 실행 | 이 저장소 PreSync hook Job | 안 (기존 구성 재사용) |
| GitHub 토큰 발급·등록 | 운영자 (runbook 절차) | 안 (절차만) |
| 릴리스 → 롤아웃 자동화 | — | 밖 (#526) |

## 문제의 실제 형태

이슈 본문의 최초 진단은 "digest만 갱신하면 된다"였으나, 앱 저장소 `73bf762`를 검증한
결과 그대로 올리면 API Pod가 **CrashLoopBackOff** 됩니다. 차단 요인이 셋입니다.

### 1. 필수 환경변수 4종 신규

`agent_orchestration/app/config.py:143-160`이 `ORCH_GITHUB_TOKEN`,
`ORCH_GITHUB_REPOSITORY`, `ORCH_EXPERIMENT_DATASET_SOURCE`,
`ORCH_EXPERIMENT_TRAINING_CONFIG_REF`를 요구합니다. `load_settings()`는
`app/main.py:95-99`의 uvicorn lifespan에서 호출되므로 값이 없으면 기동 자체가
실패합니다. `0d2cd640..73bf762` diff 기준으로 이 4개만 새로 필수가 됐고, 기존 변수의
검증 규칙 변경은 없습니다.

이 중 셋은 시크릿이 아니라 평문 좌표라 manifest 리터럴로 채웁니다. 실재하는 값을
쓰기 위해 BigQuery와 앱 저장소를 직접 조회해 확인했습니다.

- `ORCH_GITHUB_REPOSITORY=SKYAHO/Autoresearch`
- `ORCH_EXPERIMENT_DATASET_SOURCE=feast://feast_offline_store/training_entity`
  (`purpose:feast-training-spine` 라벨이 붙은 실재 테이블. 앱 `.env.example`의 예시
  `ctr_training_v1`은 존재하지 않아 쓰지 않습니다)
- `ORCH_EXPERIMENT_TRAINING_CONFIG_REF=src/pipeline/config.yaml@main`
  (앱 저장소에 실재하는 파일)

### 2. `gh` CLI가 writable `/tmp`를 요구

발행은 HTTP 직접 호출이 아니라 `gh issue create` subprocess입니다
(`experiments/github_issues.py:125-132`). 호출마다
`HOME`·`GH_CONFIG_DIR`·`TMPDIR`용과 issue body 파일용 임시 디렉터리를 만드는데,
API 컨테이너는 `readOnlyRootFilesystem: true`이고 `/runtime`만 read-only로
mount하고 있었습니다.

### 3. API Pod에 GitHub egress 없음

`gh`는 전달 환경변수를 화이트리스트로 제한해 `HTTPS_PROXY`를 넘기지 않으므로
(`github_issues.py:69-80`) proxy로 대체할 수 없고 `api.github.com` TCP 443으로
직접 나가야 합니다. 기존 API egress에는 공개 인터넷 경로가 없었습니다.

## 선택한 구조

### 이미지 참조 — 6곳을 한 커밋에서 함께 갱신

API 이미지는 5곳에 같은 digest로 pin돼 있고
`scripts/check-agent-orchestration-timeout-contract.rb:141-170`이 일치를 강제합니다.
Runner 컨테이너까지 포함해 한 릴리스를 통째로 반영합니다.

```text
api-deployment.yaml      initContainers/bootstrap-db      API  0471c6ea…
api-deployment.yaml      containers/api                   API  0471c6ea…
api-migration-job.yaml   initContainers/bootstrap-db      API  0471c6ea…
api-migration-job.yaml   containers/migrate               API  0471c6ea…
runner-deployment.yaml   initContainers/bootstrap-codex   API  0471c6ea…
runner-deployment.yaml   containers/runner             Runner  cb0360c0…
ui-deployment.yaml       containers/ui                     UI  52685020…
```

Runner를 함께 올리는 이유는 기능이 아니라 정합성입니다. 이번 변경으로 발행 경로에서
Runner가 빠져 기능상 무관하지만, 올리지 않으면 Runner만 두 릴리스 뒤처진 상태로
남습니다. Runner는 post-sync `/chat` gate로 검증되며, 실패하면 Runner 컨테이너만
이전 digest로 되돌릴 수 있습니다.

### Alembic — 기존 PreSync hook 재사용

`api-migration-job.yaml`이 이미 `argocd.argoproj.io/hook: PreSync` +
`sync-wave: "-1"`로 등록돼 있어(`:8-13`) 새로 만들 것이 없습니다. digest를 올리고
**전체 sync**하면 앱 롤아웃 전에 `alembic upgrade head`가 v0.7.0 이미지로 실행돼
`0002`·`0003`이 적용됩니다.

단, 리소스를 골라 sync하면 hook이 건너뛰어집니다. 실제로 현재 고정 리비전
(`50c06d7`)에 대한 마지막 ArgoCD 작업이 UI Deployment 하나만 대상으로 한 선택
sync였고, 그래서 namespace에 Job 객체가 없습니다. 이번에는 전체 sync가 필수입니다.

### GitHub 토큰 — 운영자 등록 Kubernetes Secret

`ORCH_GITHUB_TOKEN`은 startup에 1회만 읽는 정적 env입니다. GitHub App installation
token은 1시간 만료라 앱 변경 없이는 성립하지 않으므로 fine-grained PAT을 씁니다.
권한은 `SKYAHO/Autoresearch` 한 저장소의 `Issues: Read and write`만이며,
`contents: write`는 부여하지 않습니다 — 이 토큰으로 코드를 쓸 수 없어야 한다는 것이
앱 저장소 spec의 격리 전제입니다.

주입 방식은 기존 `agent-orchestration-api-token`·`agent-orchestration-runner-token`과
동일하게 운영자가 수동 생성하는 Kubernetes Secret입니다. Secret Manager + bootstrap
initContainer 방식은 앱의 `bootstrap_secrets.py`에 대응 role이 없어 앱 변경 없이는
쓸 수 없습니다. API GSA에 Secret Manager accessor를 추가하지 않습니다.

발행된 이슈의 작성자가 개인 계정이 되는 점은 감수합니다(앱 저장소
`docs/specs/2026-08-04-hypothesis-to-auto-research-issue.md:475-478`의 미결 항목).

### egress — 공개 인터넷 443 + 사설 대역 `except`

이 클러스터의 NetworkPolicy provider는 Calico라 FQDN 규칙을 쓸 수 없어 CIDR로만
열 수 있습니다. 두 안을 비교했습니다.

| 안 | 장점 | 채택하지 않은 이유 |
| --- | --- | --- |
| GitHub meta CIDR 24개 고정 | 목적지가 좁다 | 24개 중 20개가 `/32`이고 GitHub이 수시로 교체한다. 교체되면 예고 없이 발행이 502로 깨지고, 원인 파악이 어렵다. 주기적 drift 점검 장치를 함께 만들어야 유지된다 |
| 공개 인터넷 443 + 사설 대역 `except` | 조용히 깨지지 않는다. Runner가 이미 쓰는 패턴과 같다 | — (채택) |

`except`는 `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`,
`169.254.0.0/16`, `127.0.0.0/8`입니다. RFC1918/RFC6598 기준이라 dev CIDR 변수가
바뀌어도 함께 고칠 필요가 없습니다. 내부 목적지(Runner, Cloud SQL, Kubernetes API,
private Google APIs VIP)는 각각의 명시적 rule로 이미 허용돼 있고 `except`가 그 rule을
무효화하지 않습니다 — NetworkPolicy의 egress rule은 OR로 합쳐지고 `except`는 자기
`ipBlock` 안에서만 차감합니다.

이 규칙이 넓히는 범위를 정확히 적습니다. 사설 대역 목적지에 대해서는 "손상된 API가
클러스터·VPC 내부 서비스에 도달한다"는 위협 모델이 유지됩니다. 다만 이 클러스터는
GKE DNS 엔드포인트가 `allow_external_traffic = true`(`terraform/envs/dev/gke.tf:151-155`)라
공개 주소를 가지므로, 이 규칙은 API Pod에서 그 엔드포인트로 가는 네트워크 경로를
새로 엽니다. 실제 도달에는 `container.clusters.connect` IAM이 필요하고 API GSA에는
그 권한이 없으며, 공개 IP 엔드포인트는 `master_authorized_networks`가 비어 있어
별도로 막혀 있습니다. 이 두 전제가 바뀌면 이 규칙을 다시 평가해야 합니다.

이 변경은 runbook에 명문화돼 있던 "API에 public HTTPS egress를 열지 않는다"는 경계를
바꾸는 것이므로 runbook을 같은 PR에서 갱신합니다.

## 실패와 롤백

| 실패 | 증상 | 대응 |
| --- | --- | --- |
| Secret 미등록 상태로 sync | API Pod `CreateContainerConfigError` 또는 startup 실패 | Secret 등록 후 Pod 재기동. 롤백 불필요 |
| migration 실패 | PreSync hook Job이 실패해 **Deployment가 갱신되지 않음** | Job log 확인 후 DB 권한 점검. 옛 Pod가 계속 서비스하므로 사용자 영향 없음 |
| 토큰이 잘못됨 | startup은 통과, 발행 시 502 `authentication_failed` | 토큰 교체 후 API Pod 재기동 |
| 새 이미지 기동 실패 | API Ready 실패 | 이전 digest로 되돌리는 새 manifest commit → target SHA 갱신 → admin apply → 전체 sync |

**migration은 되돌리지 않습니다.** `0003`은 nullable 컬럼 추가라 옛 이미지와
공존해도 문제가 없고, 되돌리면 새 이미지가 다시 깨집니다. 코드만 되돌리고 확장된
컬럼은 유지하는 것이 앱 spec에 기록된 운영 방침입니다.

egress를 축소하는 방향의 롤백은 순서가 반대입니다. 먼저 NetworkPolicy에서 규칙을
제거하고 그다음 코드를 되돌립니다.

## 비용

이미지 교체와 NetworkPolicy 규칙 추가뿐이라 신규 과금 리소스가 없습니다. `/tmp`
emptyDir 64Mi는 노드 로컬 디스크를 쓰며 별도 과금이 없습니다. replica 수 변화
없음.

## 완료 조건

- [ ] API 이미지 참조 5곳이 `sha256:0471c6ea…`로 일치하고 계약 검사를 통과한다
- [ ] UI가 `sha256:526850203a…`, Runner가 `sha256:cb0360c0…`로 갱신된다
- [ ] `agent-orchestration-github-token` Secret이 sync 전에 등록된다
- [ ] PreSync migration Job이 `succeeded=1`로 끝난 뒤 Deployment가 갱신된다
- [ ] 배포된 API `/openapi.json`에 `/experiments/{id}/issue`와
      `/experiments/{id}/steps`가 나타난다
- [ ] UI 사전등록 폼 제출로 `[AR]` 이슈가 열리고 `auto-experiment` label이 붙는다
- [ ] runbook에 Secret 등록 절차, 환경변수 계약, egress 경계 변경이 반영된다
