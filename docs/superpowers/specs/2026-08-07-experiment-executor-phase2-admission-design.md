# 실험 Job 어드미션 계약 일반화와 Phase 2 executor 경계 설계

## 상태

- 관련 이슈: [#562](https://github.com/SKYAHO/Autoresearch-infra/issues/562)
- 후속 버그: [#575](https://github.com/SKYAHO/Autoresearch-infra/issues/575) —
  API의 executor token 소비 경계 누락 복구
- 인접 이슈: [#561](https://github.com/SKYAHO/Autoresearch-infra/issues/561) —
  판정 Job 계약. 본 설계가 도입하는 **계약 골격을 공유**한다(아래 3.1 결정).
- 애플리케이션 정본: `SKYAHO/Autoresearch#557`, PR #564 →
  **PR #568로 갱신** (merged source SHA
  `e5ce030979f573dfcd9117a1bfaf456e4a6aff75`, 2026-08-07)
- 상태: Phase 2 인프라 구현·apply 완료. 운영 smoke 직전 새 API Pod에서
  `ORCH_EXECUTOR_API_TOKEN` 주입 누락을 발견해 #575로 복구 중이다(9절).
- 대상 환경: GCP dev / GKE `autoresearch-dev-gke`
- 작성 언어: 한국어

## 1. 목적

`autoresearch-experiments` namespace의 어드미션 계약은 현재 Phase 1
`branch-bootstrap` Job **한 종류의 생김새만** 통과시킨다. Phase 2 executor Job은
컨테이너 구성이 완전히 다르므로 생성 자체가 거부된다.

이번 변경은 그 계약을 **Job 종류(`app.kubernetes.io/component`)별 계약**으로
일반화하고, Phase 2 executor 계약을 추가한다. 기존 `branch-bootstrap` 계약은
동등하게 보존한다.

핵심은 규칙을 **넓히는 것이 아니라 다시 쓰는 것**이다. 현행 규칙 하나는 Phase 2
형태에 그대로 적용하면 의도가 정반대로 뒤집힌다(3.2절).

## 2. 관찰된 Phase 2 executor Job의 실제 형태

정본은 `agent_orchestration/launcher/jobs.py`의 `build_executor_job()`이다.
아래는 merged SHA `e5ce030`에서 읽은 값이며, 추정이 아니다.

`app.kubernetes.io/component: experiment-executor` (Job metadata·Pod template 양쪽).
"8-container"는 **initContainer 7 + app container 1**이다. initContainer는
`restartPolicy`를 설정하지 않으므로 native sidecar가 아닌 **순차 실행**이다.

| 순서 | 컨테이너 | 마운트하는 자격 증명 | 비고 |
| --- | --- | --- | --- |
| init 1 | `branch-token-minter` | private key(RO), `branch-token`(RW) | |
| init 2 | `branch-creator` | `branch-token`(RO) | |
| init 3 | `clone-token-minter` | private key(RO), `clone-token`(RW) | |
| init 4 | `workspace-preparer` | `clone-token`(RO) | clone 수행 |
| init 5 | `codex-worker` | `codex-home`의 `auth.json`(RO, subPath) | Codex 실행. **GitHub 자격 증명은 없음** |
| init 6 | `candidate-verifier` | **없음** | |
| init 7 | `push-token-minter` | private key(RO), `push-token`(RW) | |
| app | `candidate-finalizer` | `push-token`(RO), `executor-api-token`(RO), `codex-home`의 `auth.json`(RO, subPath) | push·보고·리포트(Codex #2). `codex-home`은 v0.12.0(#611)에서 추가 |

volume 10개:

| volume | 종류 | 비고 |
| --- | --- | --- |
| `github-app-private-key` | Secret (mode 0440) | |
| `branch-token` / `clone-token` / `push-token` | emptyDir Memory 1Mi | 용도별 분리 |
| `executor-state` | emptyDir Memory 1Mi | |
| `verification-result` | emptyDir Memory 1Mi | |
| `executor-tmp` | emptyDir Memory 1Gi | |
| `workspace` | emptyDir **디스크** sizeLimit 설정값 | clone 대상 |
| `codex-home` | **Secret** (`auth.json` key, mode 0440) | Codex(OpenAI) 인증 |
| `executor-api-token` | Secret (mode 0440) | |

`codex-home`은 PR #568에서 **PVC에서 Secret으로 바뀌었다.** 앱 측 근거는
`standard-rwo` PVC가 단일 노드 attach라 여러 Pod의 동시 시작을 막을 수 있고, 작은
read-only `auth.json`에는 각 Pod가 독립으로 마운트하는 Secret이 맞다는 것이다.
이 저장소 입장에서는 신설 리소스가 PVC가 아니라 Secret이 되고, "PVC를 무엇으로
채우는가"라는 미결 항목이 사라진다.

토큰은 `token_minter.py`가 용도별 최소 권한으로 발급한다:
`branch`=`contents:write`, `clone`=`contents:read`+`issues:read`,
`push`=`contents:write`.

**앱 측 설계는 이 저장소가 강제하려는 경계를 이미 지키고 있다** — private key는
minter 3개만 보고, Codex 컨테이너는 GitHub 자격 증명(키·토큰)도 내부 API 토큰도
갖지 않는다. Codex가 갖는 것은 자기 실행에 필요한 `auth.json` 하나뿐이다. 이번
변경은 그 경계를 서버 측에서 강제해 앱 코드가 바뀌어도 유지되게 만든다.

## 3. 설계 결정

### 3.1 계약 골격은 #562가 소유하고 #561이 승계한다

`component` 값에 따라 허용 형태를 고르는 골격은 #561과 #562 양쪽에 필요하다.
#562가 먼저 도입한다.

근거: 3.2의 규칙 반전을 발견한 근거가 Phase 2의 실제 형태(Codex가 initContainer로
들어온다)에서 나왔다. #561의 판정 Job은 애플리케이션 구현
(`SKYAHO/Autoresearch#563`)이 아직 없어 같은 검증을 할 수 없다. 근거를 가진 쪽이
골격을 쓴다.

#561은 이 골격의 `experiment_job_contracts` map에 항목 하나를 추가하는 형태로
합류한다.

### 3.2 private key 규칙을 반전한다 (이번 변경의 핵심)

현행 `terraform/admin/autoresearch-k8s/experiment_jobs.tf:383`:

```
initContainers.all(c, ... 'github-app-private-key'를 readOnly로 마운트 ...)
```

문장 그대로는 **"모든 initContainer가 private key를 마운트해야 한다"** 이다.
initContainer가 정확히 1개(minter)로 고정돼 있던 조건에서는 "minter가 키를
읽는다"와 동치였다.

Phase 2에서 initContainer는 7개가 되고 그중 하나가 `codex-worker`다. **같은
문장이 "codex-worker도 private key를 마운트해야 한다"는 요구가 된다.** 정책이
지키려던 것의 정반대다.

지금은 executor Job이 다른 규칙에서 먼저 거부되므로 사고로 이어지지 않는다
(fail-closed). 위험한 것은 일반화 방식이다. 개수·이름 제한만 풀고 이 규칙을
남기면 계약이 Codex 컨테이너에 개인키를 넣으라고 **요구**하게 되고, "왜 통과가
안 되는가"를 푸는 압력이 정확히 그 방향으로 작용한다.

따라서 규칙을 **마운트 주체 allowlist**로 다시 쓴다:

> 각 자격 증명 volume은 **명시된 컨테이너만** 마운트할 수 있다. minter로 지정된
> 컨테이너는 private key를 readOnly로 정확히 하나 마운트해야 하고, **그 외 어떤
> 컨테이너도(init·app 불문) 마운트할 수 없다.**

`branch-bootstrap`에 대해서는 기존과 동치다(initContainer가 `github-token-minter`
하나로 고정돼 있으므로 "모두 마운트"와 "minter만 마운트"가 같은 집합이다).
`experiment-executor`에 대해서는 **오늘보다 강한 규칙**이 된다.

### 3.3 자격 증명별 마운트 주체를 개별로 고정한다

3.2를 private key에만 적용하지 않고 자격 증명 volume 전체로 확장한다.

| volume | 마운트 허용 컨테이너 |
| --- | --- |
| `github-app-private-key` | `branch-token-minter`, `clone-token-minter`, `push-token-minter` (RO 필수) |
| `branch-token` | `branch-token-minter`(RW), `branch-creator`(RO) |
| `clone-token` | `clone-token-minter`(RW), `workspace-preparer`(RO) |
| `push-token` | `push-token-minter`(RW), `candidate-finalizer`(RO) |
| `executor-api-token` | `candidate-finalizer`(RO) |
| `codex-home` | `codex-worker`(RO), `candidate-finalizer`(RO) |

이 표의 결과로 다음이 규칙에서 직접 따라 나온다.

- **`codex-worker`는 GitHub 자격 증명과 내부 API 토큰을 가질 수 없다.** 가질 수
  있는 것은 자기 실행에 필요한 `codex-home`의 `auth.json` 하나뿐이다.
- **`candidate-verifier`는 어떤 자격 증명도 가질 수 없다.**
- `codex-home`을 마운트할 수 있는 컨테이너는 Codex를 직접 실행하는 둘뿐이며,
  쓰기 주체는 없다.

#### 3.3.1 v0.12.0(#611)에서 무른 역방향 경계

초판 계약은 `codex-home`을 `codex-worker` 하나로 묶어 **"Codex 인증이 GitHub을
만지는 컨테이너로 새는 경로"까지 함께 닫았다.** v0.12.0에서 리포트를 쓰는
Codex #2가 `candidate-finalizer`에서 돌게 되면서 이 역방향 경계를 뺐다. 채점
결과가 나오는 시점이 그 컨테이너이고, `report.md`는 git 커밋 대상이 아니라 GCS
게시 산출물이라 push 뒤에 와도 되기 때문이다.

결과적으로 **push token·내부 API token과 Codex 인증이 한 컨테이너에 함께 있다.**
Codex sandbox는 `danger-full-access`라 그 안에서 토큰 파일을 읽는 것을 코드로
막지 않으며, 금지는 애플리케이션 측 하네스 지침이 담당한다. 감수하는 위험은
"Codex #2가 push token을 볼 수 있다"이고, 이를 없애는 방법은 계약을 더 푸는 것이
아니라 컨테이너 분리다(애플리케이션 Stage 2의 8 → 4/5 재구성).

`codex-worker` 쪽 경계(GitHub 자격 증명·API 토큰 없음)는 그대로 유지한다. 이
예외는 `candidate-finalizer` 하나에 한정되며, 계약 표와 `tftest` 고정값이 그
목록을 두 개로 못 박아 "한 컨테이너 더"가 조용히 추가되지 않게 한다.

3.4가 설명하듯 이 자격 증명 분리가 유일하게 강제 가능한 경계다.

### 3.4 컨테이너별 네트워크 분리는 불가능하다 — 자격 증명 분리가 유일한 경계

NetworkPolicy는 Pod 단위인데 8개 컨테이너가 한 Pod에 있다. 또한 이 클러스터의
dataplane은 Calico라 `FQDNNetworkPolicy`를 쓸 수 없어 공개 443을 통째로 연다
(기존 branch-bootstrap egress와 같은 판단).

따라서 `codex-worker`도 GitHub·OpenAI에 **네트워크로는 도달한다.** 이를 막을
방법은 없다.

실질 방어는 3.3의 자격 증명 분리 하나뿐이다. `codex-worker`가 GitHub에 닿아도
쓸 토큰이 없다. 이 판단을 문서에 남기는 이유는, 이후 "네트워크로 막혀 있다"는
잘못된 전제로 자격 증명 규칙을 완화하는 변경을 막기 위해서다.

### 3.5 `branch-bootstrap` 계약 보존은 롤백 경로다

애플리케이션 `launcher/main.py`는 `ensure_executor_job`만 호출한다. Phase 1/2를
고르는 스위치가 **없다.** 즉 launcher image digest를 올리는 순간 전체가 Phase 2로
전환되며, 점진 배포 경로가 없다.

그러므로 롤백은 **launcher image digest를 직전 값으로 되돌리는 것**이고, 그때
생성되는 Job은 다시 `branch-bootstrap` 형태다. `branch-bootstrap` 계약을 지우면
**롤백 자체가 어드미션에서 거부된다.** 계약 보존은 정리 누락이 아니라 롤백
전제조건이다.

## 4. 신설하는 리소스와 executor API token 소비 경계

`terraform/admin/autoresearch-k8s/`에 아래 두 개가 없음을 확인했다. 둘 다
`autoresearch-experiments` namespace의 Kubernetes Secret이며, #562에서 만들었다.

- **Codex 인증 Secret** (`codex-home` volume의 원본) — `auth.json` key 하나를
  제공한다. `codex-worker`와 `candidate-finalizer`(3.3.1)가
  `/var/lib/codex/auth.json`에 readOnly `subPath`로 마운트한다. `defaultMode` 0440은 launcher가 지정하므로 이 저장소는 Secret과 key
  존재만 소유한다.
- **`executor-api-token` Secret** — `candidate-finalizer`가 in-cluster Experiment
  API에 보고할 때 쓰는 토큰. 이름은
  `autoresearch-experiment-executor-api-token`, key는 `token`이다.

두 Secret 모두 값은 기존 `github-app-private-key`와 같은 경로로 배치하고 Git·PR·
로그에 남기지 않는다.

### 4.1 같은 token의 API namespace 사본이 필요하다 (#575)

candidate 보고 인증은 양쪽이 같은 token을 가져야 성립한다.

- 발신자 `candidate-finalizer`는 `autoresearch-experiments` namespace의
  `autoresearch-experiment-executor-api-token/token`을 파일로 마운트한다.
- 수신자 API는 `autoresearch` namespace의 같은 이름·key Secret을
  `ORCH_EXECUTOR_API_TOKEN` 환경 변수로 읽는다.

Kubernetes Secret은 namespace-scoped이므로 한 Secret을 두 Pod가 직접 공유할 수
없다. 따라서 **같은 payload를 가진 Secret 객체가 두 namespace에 각각 하나씩**
있어야 한다. manifest에는 Secret 이름과 key 참조만 두고 값은 운영자가 runbook
절차로 주입한다. API Deployment는 `envFrom`이 아니라 아래의 단일 key
`secretKeyRef`만 사용한다.

```yaml
- name: ORCH_EXECUTOR_API_TOKEN
  valueFrom:
    secretKeyRef:
      name: autoresearch-experiment-executor-api-token
      key: token
```

두 사본의 불일치는 candidate 보고를 401로 실패시키므로 회전은 실행 중 Experiment가
없는 시점에 양쪽 Secret을 함께 갱신하고 API를 재시작한다. Secret 값이나 hash를
로그·PR에 출력해 동일성을 증명하지 않는다. 대신 새 API의 Ready 상태와 인증된
candidate smoke 결과로 end-to-end 일치를 검증한다.

**롤아웃 순서가 정해져 있다.** 두 namespace의 executor token Secret과
`auth.json` key를 **먼저 생성한 뒤**, API Deployment의 token 참조를 배포하고 새
API가 Ready인 것을 확인한 다음 launcher를 활성화한다. executor namespace의 Secret이
없으면 Pod가 `Pending`에 머물고, API namespace의 Secret 또는 env 참조가 없으면 API가
`CreateContainerConfigError` 또는 startup 실패에 머문다. 어느 경우에도 smoke를
시작하지 않는다.

`subPath` 마운트는 실행 중 Secret 갱신을 전파하지 않으므로, Secret 교체는 새
Experiment부터 적용된다.

## 5. 네트워크 경계 변경

`experiment-jobs-branch-bootstrap-egress`를 본으로, `component=experiment-executor`
대상 정책을 신설한다. 기존 정책은 그대로 둔다(3.5의 롤백 경로).

executor Pod가 필요로 하는 목적지:

| 목적지 | 필요 컨테이너 | 경로 |
| --- | --- | --- |
| GitHub API·Git (공개 443) | minter 3종, `workspace-preparer`, `candidate-finalizer` | 공개 443 (사설 대역 except) |
| OpenAI (공개 443) | `codex-worker` | 위와 동일 규칙에 포함 |
| in-cluster Experiment API | `candidate-finalizer` | `autoresearch` namespace의 API Service |

세 번째 항목이 기존 branch-bootstrap 정책과의 차이다. 기본 egress 정책이 사설
대역을 `except`로 막고 있으므로, API Service로 가는 egress를 별도로 열어야 한다.
Cloud SQL은 계속 닫아 둔다 — 보고 경로가 API 경유이므로 DB 직접 연결은 필요 없다.

## 6. 자원·quota 영향

**LimitRange는 현재 값 그대로 통과한다.** initContainer가 순차 실행이므로 Pod
실효 요청은 `max(initContainer 최대, app container 합)` = `max(500m, 500m)` =
500m, 메모리 `max(1Gi, 1Gi)` = 1Gi로 Pod 상한(1 CPU / 2Gi) 안에 든다. 컨테이너가
8개로 늘어도 상한을 올릴 필요가 없다.

단, `experiment_jobs.tf:98-115`의 주석은 branch-bootstrap 형태만 설명하므로
Phase 2 계산을 반영해 갱신한다. "token-minter를 native sidecar로 바꾸면 상한에
걸린다"는 제약은 Phase 2에서도 그대로 유효하다.

**`ephemeral-storage` 통제가 비어 있다.** `workspace`는 Memory가 아닌 디스크 기반
emptyDir인데 ResourceQuota·LimitRange 어디에도 `ephemeral-storage` 항목이 없다.
repository clone과 Codex 작업물이 노드 디스크를 채우면 노드 압박 축출이 발생하고,
같은 노드의 다른 Job까지 영향을 받는다. quota에 `requests.ephemeral-storage`와
LimitRange 기본값·상한을 추가한다.

## 7. 계약 대조 결과 (구현 당시 기준)

거부되는 규칙 6건:

| 위치 | 현행 규칙 | executor 실제 |
| --- | --- | --- |
| `:359` | initContainer 1개, `github-token-minter` | 7개, 이름 전부 다름 |
| `:363` | app container 이름 `branch-bootstrap` | `candidate-finalizer` |
| `:373` | volume 정확히 2개 | 10개 |
| `:383` | 모든 initContainer가 키 마운트 | 3개만 (3.2절) |
| `:407` | label `component=branch-bootstrap` | `experiment-executor` |
| `:414` | 모든 container가 `github-token` RO 마운트 | `push-token` 사용 |

그대로 통과하는 규칙: 이미지 digest 고정, 이미지 prefix allowlist,
`serviceAccountName`, `nodeSelector`, `automountServiceAccountToken: false`,
`envFrom`/`valueFrom` 금지, `suspend`, `activeDeadlineSeconds`,
`ttlSecondsAfterFinished`. 앱 측이 기존 제약을 승계했다.

## 8. 검증 전략

세 층으로 나눈다. 각 층이 증명하는 것이 다르다.

1. **`terraform test`** (`tests/experiment_jobs_contract.tftest.hcl` 신설) —
   렌더링된 정책 문자열이 의도한 계약을 담고 있는지. 특히 3.2 반전이 실제로
   적용됐는지와 `branch-bootstrap` 계약이 동등하게 남아 있는지.
2. **server dry-run** — `kubectl apply --dry-run=server`. 어드미션 판정만 받고
   Pod를 만들지 않으므로 private key·네트워크·Codex가 관여하지 않는다. 두 개를
   나란히 돌린다: 신규 executor Job은 **통과해야 하고**, 기존 branch-bootstrap
   Job은 **여전히 통과해야 한다**(회귀).
3. **plain manifest 계약 검사** — API Deployment가
   `ORCH_EXECUTOR_API_TOKEN`을 정확한 Secret 이름·key의 단일
   `secretKeyRef`로 읽는지 고정한다. Secret 값은 검사 대상이 아니다.
4. **운영 smoke** — 실제 Experiment 1건. 9절의 배포 게이트가 모두 풀린 뒤에만
   시작한다.

dry-run이 증명하지 못하는 것: 네트워크 도달성(NetworkPolicy는 런타임에 작용),
Codex·verifier의 실제 동작, 토큰 발급·push 성공. 이는 4층 운영 smoke에서만
확인된다.

## 9. 운영 smoke 배포 게이트

이 설계의 이전 판은 `activeDeadlineSeconds`가 300초로 고정돼 있고
`from_environment()`가 그 필드를 읽지 않아 **Phase 2 Job이 완주할 수 없다**고
기록했다. 애플리케이션 PR #568(`SKYAHO/Autoresearch`, merged 2026-08-07)이 이를
해결했다.

- `ORCH_ACTIVE_DEADLINE_SEC`가 필수 양의 정수 환경 변수로 추가됐다. 기본값이
  없으므로 launcher CronJob manifest가 반드시 공급해야 한다.
- `codex_timeout_sec >= active_deadline_sec`이면 launcher가 기동 시
  `LauncherConfigError`로 거부한다. 두 값의 순서가 설정 계층에서 강제된다.
- 앱 spec이 고정한 MVP 운영값은 **Job 전체 3600초, Codex 1800초**다.

3600초는 이 저장소 계약의 `activeDeadlineSeconds` 상한(1~3600)과 정확히 맞는다.
따라서 **어드미션 계약은 이 건으로 바꿀 필요가 없다.** 앱 spec도 "admission 허용
상한 안에서" 값을 골랐다고 명시한다.

남는 것은 두 저장소가 같은 값을 갖고 있어야 한다는 결합이다. 이 저장소는
`ORCH_ACTIVE_DEADLINE_SEC`를 3600 이하로 공급해야 하며, 이를 넘기면 launcher는
통과하지만 어드미션이 Job을 거부한다. 그 실패는 launcher 로그에만 남고 Job은
생성되지 않으므로, manifest 계약 검사에서 상한을 함께 검증한다(계획 Task 8).

실행 상한 의존은 해소됐지만, #575에서 다음 누락을 운영 중 확인했다.

- 새 API image는 `ORCH_EXECUTOR_API_TOKEN`을 필수로 읽는다.
- `autoresearch-experiments`의 executor token Secret은 존재하지만
  `autoresearch`에는 namespace 사본이 없다.
- API Deployment에도 해당 env `secretKeyRef`가 없다.
- 결과적으로 새 API Pod는 startup에서 실패하고 Service는 candidate endpoint가 없는
  직전 API Pod만 Ready endpoint로 유지한다.

따라서 운영 smoke의 추가 선행 게이트는 다음 네 가지다.

1. `autoresearch` namespace에 같은 이름·key·payload의 Secret을 등록한다. 토큰
   값은 **디코딩 기준 32자 이상**이고 `ORCH_API_TOKEN`·`ORCH_RUNNER_TOKEN`과
   달라야 한다(`app/config.py`가 startup에서 강제). base64 인코딩 길이로
   판단하지 않는다 — #575에서 20자 토큰을 28자로 오독한 사례가 있다.
2. API Deployment에 4.1의 `secretKeyRef`를 반영한다.
3. 새 API Pod의 rollout과 `/healthcheck` 200을 확인한다.
4. Service OpenAPI에 `POST /internal/executor/experiments/{experiment_id}/candidate`가 노출되는지
   확인한다.

이 네 조건 전에는 Experiment를 등록하지 않는다.

## 10. 롤백

| 대상 | 절차 |
| --- | --- |
| launcher 전환 | launcher image digest를 직전 main revision 값으로 되돌리고 ArgoCD sync. Phase 1 동작으로 복귀한다(3.5). |
| 어드미션 계약 | Terraform revert 후 apply. `branch-bootstrap` 계약이 보존돼 있으므로 되돌린 launcher가 그대로 통과한다. |
| NetworkPolicy | executor 전용 정책 삭제. 기존 정책은 손대지 않았으므로 Phase 1 경로가 그대로 남는다. |
| executor namespace Secret 2종 | Phase 1은 이들을 참조하지 않으므로 제거 가능. 단 롤백 순서상 launcher를 먼저 되돌린 뒤 제거한다 — 반대로 하면 진행 중인 Phase 2 Job이 `FailedMount`로 매달린다. |
| API namespace token 사본 | Phase 2 API Deployment를 token 비필수 직전 digest로 되돌려 Ready를 확인한 뒤 env 참조와 Secret을 제거한다. 진행 중인 Phase 2 Job이 있으면 먼저 종료 결과를 확정한다. |

계약 변경이 잘못되면 `failurePolicy: Fail` + `Deny`로 **실험 Job 전체가 거부**된다.
apply 직후 기존 branch-bootstrap manifest로 dry-run 회귀 확인을 수행한다(8절 2층).

## 11. 비용·보안 영향

**비용**: 기존 `batch-od` node pool과 namespace quota를 그대로 쓴다. 새 상시 노드도
새 디스크도 없다(신설 리소스는 executor namespace Secret 2개와 API namespace의
token Secret 사본 1개다).

다만 **Job 1건의 노드 점유 시간이 300초에서 3600초로 12배 늘어난다**(9절). 이
node pool은 min 0 / max 2의 온디맨드 `e2-standard-2`이므로, 동시 2건이 상한까지
도는 경우 노드 가동 시간이 그만큼 증가한다. quota의 `count/jobs.batch = 2`와
`ORCH_MAX_CONCURRENT_EXPERIMENTS`가 동시 실행을 2로 묶고 있어 상한은 유지되지만,
Phase 1 기준으로 잡았던 비용 감각은 갱신이 필요하다. dev 실사용량을 smoke 이후
측정해 runbook에 기록한다.

**보안**: 순증이 아니라 순감이다. 3.2·3.3의 allowlist 규칙은 현행보다 강하고,
`codex-worker`가 자격 증명을 갖지 못한다는 것이 서버 측에서 강제된다. 확대되는
면은 executor Pod의 in-cluster API egress 1건이며, 대상은 `autoresearch`
namespace의 API Service로 한정한다. #575의 API namespace 사본은 인증 검증 주체인
API Pod만 단일 key `secretKeyRef`로 읽으며, UI·runner·launcher에는 전달하지 않는다.

**참고 — 상류 GitHub 보호막**: `SKYAHO/Autoresearch`의 `main-protection` ruleset은
`required_approving_review_count: 1`, `require_last_push_approval: true`,
`bypass_actors: []`다. executor 토큰에는 `pull_requests` 권한이 없어 PR을 만들
수조차 없다. 즉 executor 경로에서 `main`이 오염되는 경로는 없다. 다만
`dev-protection`은 `pull_request` 규칙이 없어 **직접 push가 가능**하고, `exp/*`는
보호가 없으며, 저장소는 public이다. 이 저장소의 경계는 그 잔여 범위를 대상으로
한다.

## 12. 검토 근거

- **개정(#611, 2026-08-09)**: 관찰 대상 SHA `SKYAHO/Autoresearch@8750bce`(v0.12.0).
  `candidate-finalizer`가 Codex #2로 `report.md`를 쓰면서 `codex-home`을 추가로
  마운트한다. 3.1·3.3·4절을 갱신하고 근거와 잔여 위험을 3.3.1에 기록했다.
- 관찰 대상 SHA: `SKYAHO/Autoresearch@e5ce030979f573dfcd9117a1bfaf456e4a6aff75`
  (`launcher/jobs.py`, `launcher/config.py`, `launcher/main.py`,
  `executor/token_minter.py`, `.env.example`, `README.md`,
  `docs/specs/2026-08-06-experiment-executor-phase2.md`)
- 직전 관찰 SHA `29d29af`(PR #564) 대비 차이는 PR #568 두 건이다:
  `ORCH_ACTIVE_DEADLINE_SEC` 신설(9절), `codex-home`의 PVC→Secret 전환(4절).
- 현행 계약: `terraform/admin/autoresearch-k8s/experiment_jobs.tf`
- 선행 설계: `docs/superpowers/specs/2026-08-01-agent-experiment-job-design.md`
- 선행 계획: `docs/superpowers/plans/2026-08-06-experiment-branch-launcher-infra.md`
