# v0.9.0 학습 executor 활성화 설계

> 관련 이슈: #591
>
> 애플리케이션 계약: `SKYAHO/Autoresearch#605`, PR #606, release v0.9.0
>
> 대상 환경: dev

## 목적

현재 배포된 launcher/executor는 Phase 2 학습 배선이 들어오기 전 이미지와 환경 변수로
실행되어, executor가 코드 수정·lint/test만 수행하고 학습 및 ROC-AUC 측정을 건너뛴다.
이 설계는 v0.9.0 launcher/executor 이미지와 학습 환경 변수를 함께 배포 manifest에
반영해 학습 경로를 활성화한다.

## 결정

### 1. 변경 범위

다음 두 이미지와 launcher CronJob만 변경한다.

| 항목 | 현재 | 신규 |
|---|---|---|
| launcher | `autoresearch-agent-orchestration-launcher@sha256:2818f29a658b36c14199bd7e2d195e56921cf876217b6504af3fbc5634627837` | `autoresearch-agent-orchestration-launcher@sha256:24bf725cab23ff2b1e54086a5366538f23aea408aae7f6e12073e19454e6b04e` |
| executor | `autoresearch-agent-orchestration-executor@sha256:7999677d238f29202fa5720700e86943937bb3d0536cdb3269231c01a14c2475` | `autoresearch-agent-orchestration-executor@sha256:a3ee4aff0266ee2781608b2172c78f9def70ff7aa73c657df97c361566075808` |

두 이미지는 다음 Artifact Registry repository의 immutable digest를 사용한다.

`asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/`

API, UI, runner image는 현재 digest를 유지한다. 학습 활성화에 필요하지 않은 구성까지
같은 변경에 포함하지 않아 release 간 원인 추적과 rollback 범위를 좁힌다.

### 2. 학습 환경 변수

`agent-orchestration-launcher` CronJob의 launcher container에 아래 literal env를 추가한다.

```text
ORCH_TRAINING_DATASET_URI=gs://autoresearch-503903-autoresearch-dev-experiment-results/training-snapshots/by-hash/d3d273e66324042cd8e547068c194231cf1812d53cb68236edba56b067055293/
ORCH_TRAINING_TIMEOUT_SEC=1800
ORCH_TRAINING_DOWNLOAD_TIMEOUT_SEC=600
ORCH_UV_SYNC_TIMEOUT_SEC=900
```

`ORCH_TRAINING_DATASET_URI`는 학습 경로를 켜는 opt-in 스위치이며, URI 마지막
directory segment는 CSV bytes SHA-256과 일치해야 한다. executor는 다운로드한 CSV를
그 digest와 대조한다. 세 timeout은 v0.9.0 launcher가 필수로 읽으므로 URI와 함께
항상 공급한다.

구식 `ORCH_TRAINING_DATASET_PATH`는 manifest에 존재할 경우 제거한다. 현재 checkout에는
없지만 contract 검사에서 재유입을 허용하지 않는다.

### 3. 운영 경계

CronJob의 `suspend` 상태는 이 변경에서 바꾸지 않는다. merge 후 ArgoCD/GitOps sync가
manifest를 배포하고, 애플리케이션 담당자가 학습 활성화 시점에 `suspend=false`로
복귀한 뒤 실험 발행·candidate SHA·ROC-AUC를 검증한다.

실험 snapshot은 이전 작업에서 이미 게시되었고, executor Job GSA에는 대상 결과 버킷의
`roles/storage.objectViewer`가 적용되어 있다. 이 변경은 IAM·GCP resource·자원
request/limit을 변경하지 않는다.

## 파일과 책임

| 파일 | 책임 |
|---|---|
| `deploy/agent-orchestration/launcher-cronjob.yaml` | launcher image, executor image, 학습 env의 GitOps 정본 |
| `scripts/check-experiment-launcher-manifest-contract.rb` | digest·필수 env·기존 launcher 실행 계약의 정적 검증 |
| `scripts/test-check-experiment-launcher-manifest-contract.rb` | contract checker의 정상·회귀 self-test |
| `docs/CHANGE_HISTORY.md` | v0.9.0 학습 활성화 결정과 적용 경계 기록 |
| `docs/runbooks/2026-08-01-auto-research-experiment-job.md` | release digest와 학습 env 운영 계약 기록 |

계약 checker의 expected digest와 expected literal env를 manifest와 함께 갱신해, 이후
launcher만 새 이미지로 승격되거나 필수 학습 env가 누락되는 부분 배포를 거부한다.

## 대안과 선택 이유

1. **권장 — launcher/executor와 학습 env만 직접 갱신**: 학습 활성화에 필요한 최소
   변경만 포함하고, 기존 정적 contract checker가 배포 계약을 계속 검증한다.
2. **API/UI/runner까지 v0.9.0으로 동시 승격**: release 일관성은 높아지지만 학습에
   필요하지 않은 변경과 rollback 범위를 늘린다.
3. **학습 env를 ConfigMap/별도 values로 외부화**: 환경별 override에는 유리하지만
   ArgoCD 입력 경로와 Secret/ConfigMap 관리 경계를 추가하며, 이번 고정 dev snapshot
   계약에는 과하다.

따라서 1번을 선택한다.

## 검증과 성공 기준

구현 후 다음을 확인한다.

- manifest contract self-test가 신규 launcher/executor digest와 네 학습 env를 모두
  확인한다.
- 모든 Agent Orchestration manifest의 동일 image repository 참조 digest가 서로
  일치한다.
- YAML/정적 검사와 `git diff --check`가 통과한다.
- ArgoCD sync 후 launcher Pod가 신규 digest로 실행되고, executor Job template이
  신규 executor digest와 네 학습 env를 전달한다.
- 담당자가 launcher를 재개한 뒤 발행한 실험에서 `candidate_sha`와 ROC-AUC가 생성된다.

## 롤백

학습 배선 또는 이미지 문제가 발생하면 launcher를 먼저 suspend 상태로 되돌리고
manifest의 launcher/executor digest와 학습 env를 직전 커밋으로 revert한다. 이미 적용된
snapshot bucket viewer IAM과 기존 결과 객체는 삭제하지 않는다.
