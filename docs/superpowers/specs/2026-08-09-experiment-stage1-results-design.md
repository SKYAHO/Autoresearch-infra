# Stage 1 실험 결과 게시·실행 시간 설계

> 관련 이슈: #604
>
> 애플리케이션 선행 구현: `SKYAHO/Autoresearch` PR #629 (`aa12259`)
>
> 대상 환경: dev

## 목적

Stage 1의 측정 → 게시 → 보고 경로가 executor Pod 종료 뒤에도 `metrics.json` 등
결과를 남기고, 8-container 실행 및 seed별 채점이 완료될 만큼의 시간을 확보하도록
GitOps 정본과 admission 계약을 함께 갱신한다.

## 결정

### 결과 게시 root

`agent-orchestration-launcher` CronJob의 launcher container에 아래 literal env를
추가한다.

```text
ORCH_EXPERIMENT_RESULTS_ROOT=gs://autoresearch-503903-autoresearch-dev-experiment-results
```

executor는 이 root 아래 `experiments/{issue_number}/{experiment_id}/`에만 결과를
쓴다. `experiment-job` GSA의 기존 bucket-level `roles/storage.objectCreator`는
create만 허용하므로, 기존 객체 교체 없이 write-once 성질을 유지한다. 새 IAM,
GCP 리소스, project-level binding은 추가하지 않는다.

### 실행 시간

launcher가 executor Job에 전달할 값은 다음으로 고정한다.

```text
ORCH_ACTIVE_DEADLINE_SEC=60000
ORCH_CODEX_TIMEOUT_SEC=6000
```

두 값은 `ORCH_CODEX_TIMEOUT_SEC < ORCH_ACTIVE_DEADLINE_SEC`를 만족한다. 기존
ValidatingAdmissionPolicy가 `activeDeadlineSeconds <= 3600`을 강제하므로, manifest만
바꾸면 실제 Job이 `FailedCreate`로 거부된다. 같은 PR에서 admin root의 상한을
`60000`초로 올린다. `ttlSecondsAfterFinished` 상한은 회수·quota 경계를 위해
기존 `3600`초로 유지한다.

이 결정은 executor Job 두 개가 각각 최대 16시간 40분 동안 batch-od 용량과
`count/jobs.batch` quota를 점유할 수 있음을 뜻한다. 이 비용·처리량 영향은 Stage 1
seed 채점의 결정값이며, 별도 apply 없이 PR에서는 코드·문서·정적 검증만 수행한다.

### 이미 충족된 MLflow 항목

`main`의 #602가 `ORCH_MLFLOW_TRACKING_URI`와 executor-to-MLflow egress를 이미
관리한다. Stage 1 결과 게시에는 필요한 기존 경로지만, 이 작업에서 값·NetworkPolicy·IAM을
변경하지 않는다.

## 적용 순서와 실패 모드

`terraform/admin/autoresearch-k8s`의 ValidatingAdmissionPolicy는 ArgoCD Application의
소유가 아닌 별도 state다. 반면 `agent-orchestration` Application은 infra `main` 변경을
자동 sync한다. 따라서 merge 전에 live launcher CronJob을 `spec.suspend=true`로
일시 정지하고, admin root apply로 active deadline 상한을 60000초로 올린 뒤 live VAP를
확인해야 한다. 그 다음에야 ArgoCD sync 결과에서 세 env를 확인하고 suspend를 해제한다.

CronJob manifest에는 suspend를 넣지 않는다. suspend는 GitOps desired state가 아니라
이 배포 순서를 보호하는 일시적인 운영 게이트이며, sync 뒤 `false`로 되돌린다. VAP가
아직 3600초인 상태에서 ArgoCD가 새 env를 먼저 반영하면 launcher가 만든 60000초
executor Job이 `FailedCreate`로 거부된다.

## 파일과 책임

| 파일 | 책임 |
| --- | --- |
| `deploy/agent-orchestration/launcher-cronjob.yaml` | launcher가 executor Job으로 전달할 결과 root와 두 timeout의 GitOps 정본 |
| `scripts/check-experiment-launcher-manifest-contract.rb` | 결과 root·timeout의 exact 값 및 timeout 순서 정적 검증 |
| `scripts/test-check-experiment-launcher-manifest-contract.rb` | 결과 root와 각 timeout 누락·변조를 거부하는 mutation self-test |
| `terraform/admin/autoresearch-k8s/experiment_jobs.tf` | executor Job `activeDeadlineSeconds`의 server-side 60000초 상한 |
| `terraform/admin/autoresearch-k8s/tests/experiment_jobs_contract.tftest.hcl` | admission upper bound regression 검증 |
| `docs/runbooks/2026-08-01-auto-research-experiment-job.md` | live manifest 확인, 60000초 운영 상한, 결과 객체 확인 절차 |
| `docs/CHANGE_HISTORY.md` | write-once 결과 게시와 timeout/admission 동시 변경의 장기 결정 기록 |

## 검증과 롤백

PR에서는 Ruby manifest contract와 self-test, admin Terraform test, `kubectl` client
dry-run, `git diff --check`를 실행한다. 실제 apply, ArgoCD sync, launcher suspend/resume
및 실험 발행은 이 작업 범위 밖이다. 적용 순서는 runbook의 admin admission → ArgoCD
manifest → live env 확인 절차를 따른다.

배포 후에는 실험 한 건에서 `metrics.json`이 결과 root의 experiment prefix에 남고,
API가 보고한 `metric_summary`가 null이 아닌지를 확인한다. 두 번째 동일
`base_dev_sha` 실험에서 baseline seed별 값이 일치하는지도 애플리케이션 운영 검증으로
확인한다.

문제가 생기면 launcher CronJob을 suspend해 새 Job 제출을 멈춘 뒤, manifest의 세 env와
admission 60000초 상한을 이 PR 직전 Git commit으로 함께 revert한다. 이미 생성된
Job은 기존 `activeDeadlineSeconds`를 유지하고, GCS 결과 객체와 objectCreator IAM은
삭제하지 않는다.
