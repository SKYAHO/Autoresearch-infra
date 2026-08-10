# 실험 5건 동시 실행 용량 상향 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** dev에서 requests `1 CPU/2Gi`, limits `4 CPU/8Gi`인 executor 실험 5건을 비용 절충형 단일 노드에 동시에 실행하고 Streamlit 워크벤치에 상태·로그·이벤트가 갱신되도록 한다.

**Architecture:** #669의 requests를 `1 CPU/2Gi`로 먼저 맞추고, 첫 번째 infra PR에서 `e2-standard-8`·100GB와 Kubernetes 용량을 준비한 뒤 dev root 다음 admin root 순서로 적용한다. 수정된 #669를 동시 2건으로 canary한 뒤 두 번째 infra PR에서 launcher 상한만 5로 올리고 최종 5건 smoke를 수행한다.

**Tech Stack:** Terraform 1.13.5, GKE, Kubernetes ResourceQuota/LimitRange, GitHub Actions, ArgoCD, Ruby manifest contract tests

## 변경 계약

| 대상 | 현재 | 목표 |
| --- | --- | --- |
| `batch-od` machine type | `e2-standard-2` | `e2-standard-8` |
| `batch-od` boot disk | `pd-standard` 30GB | `pd-standard` 100GB |
| LimitRange Container/Pod max | `1 CPU/2Gi` | `4 CPU/8Gi` |
| Jobs/Pods quota | `2/2` | `5/5` |
| requests quota | `2 CPU/4Gi` | `5 CPU/10Gi` |
| limits quota | `2 CPU/4Gi` | `20 CPU/40Gi` |
| launcher concurrency | `2` | canary 후 `5` |

다음 불변식은 유지한다.

- 대상은 `autoresearch-503903`, `asia-northeast3-a`, dev 환경이다.
- `batch-od`는 on-demand, autoscaling min 0/max 2이며 이름·taint·disk type·node SA·Workload Metadata를 바꾸지 않는다. disk size만 100GB로 올린다.
- LimitRange `default`와 `default_request`의 `500m/1Gi`는 바꾸지 않는다.
- 첫 번째 PR에서 launcher 상한을 변경하지 않는다.
- apply는 `scope: dev` 성공 후 `scope: admin`으로 분리하며 `scope: all`은 사용하지 않는다.
- IAM, Secret, NetworkPolicy, public endpoint, Terraform state는 변경하지 않는다.
- 두 PR 모두 `Refs #624`를 사용하고 최종 smoke 전에는 이슈를 닫지 않는다.

---

### Task 1: 용량 PR 구현 및 검증

**Files:**

- Modify: `terraform/envs/dev/variables.tf`
- Modify: `terraform/envs/dev/gke.tf`
- Modify: `terraform/admin/autoresearch-k8s/experiment_jobs.tf`
- Modify: `terraform/admin/autoresearch-k8s/tests/experiment_jobs_contract.tftest.hcl`
- Modify: `terraform/admin/autoresearch-k8s/README.md`
- Modify: `docs/TERRAFORM_DEV.md`
- Modify: `docs/INFRASTRUCTURE_SUMMARY.md`
- Modify: `docs/runbooks/2026-08-01-auto-research-experiment-job.md`

**Produces:** node pool과 namespace가 실험 5건을 수용하되 launcher는 2건을 유지하는 첫 번째 PR.

- [ ] **Step 1: 실행 전 Gate 0 확인**

  #672가 terminal 상태이고 active experiment Job/Pod와 `batch-od`의 다른 사용자가 없는지 확인한다. launcher 최신 Job도 `Complete`여야 한다.

  ```bash
  kubectl -n autoresearch-experiments get jobs,pods -o wide
  kubectl -n autoresearch get jobs --sort-by=.metadata.creationTimestamp
  kubectl get pods -A -o wide
  ```

  active workload가 있거나 launcher가 비정상이면 node pool 교체를 시작하지 않는다.

- [ ] **Step 2: 계약 테스트를 목표값으로 먼저 변경**

  `experiment_jobs_contract.tftest.hcl`에서 quota 6개 항목이 Jobs/Pods 5,
  requests `5 CPU/10Gi`, limits `20 CPU/40Gi`이고 Container/Pod max가
  `4 CPU/8Gi`인지 assert한다. 변경 전 테스트가 requests `10 CPU/20Gi` 때문에
  실패하는지 확인한다.

  ```hcl
  assert {
    condition     = kubernetes_resource_quota_v1.experiment_jobs.spec[0].hard["requests.cpu"] == "5"
    error_message = "requests.cpu quota는 5 × 1 CPU = 5여야 한다."
  }

  assert {
    condition     = kubernetes_resource_quota_v1.experiment_jobs.spec[0].hard["requests.memory"] == "10Gi"
    error_message = "requests.memory quota는 5 × 2Gi = 10Gi여야 한다."
  }
  ```

  ```bash
  terraform -chdir=terraform/admin/autoresearch-k8s test \
    -filter=tests/experiment_jobs_contract.tftest.hcl
  ```

- [ ] **Step 3: Terraform 최소 변경**

  `batch_od_gke_machine_type`을 `e2-standard-8`, `batch-od`의 `disk_size_gb`를
  `100`으로 바꾸고 ResourceQuota와 LimitRange를 목표값으로 갱신한다. 다른 node
  pool 속성과 Kubernetes 경계는 건드리지 않는다.

- [ ] **Step 4: 관련 문서 정합화**

  README, dev 문서, 인프라 요약, runbook에 목표 용량과 단계적 배포·rollback을 반영한다. 이 단계의 runbook에는 launcher 현재값을 `2`로 유지한다.

- [ ] **Step 5: 로컬 검증 및 셀프 리뷰**

  ```bash
  terraform -chdir=terraform/envs/dev fmt -check -recursive
  scripts/terraform-env --environment dev --root terraform/envs/dev init -backend=false
  scripts/terraform-env --environment dev --root terraform/envs/dev validate
  scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s init -backend=false
  scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s validate
  terraform -chdir=terraform/admin/autoresearch-k8s test \
    -filter=tests/experiment_jobs_contract.tftest.hcl
  git diff --check
  ```

  diff에서 예상 밖의 교체·삭제, IAM 확대, secret/state/tfvars, public endpoint 변경이 없어야 한다.

- [ ] **Step 6: 용량 PR 생성 및 병합**

  저장소 템플릿과 `CONTRIBUTING.md`를 따라 기존 PR #625를 갱신하고 Terraform
  plan을 검토한다. dev는 `batch-od` machine type·disk size 변경만 보여야 하고,
  admin은 계약 테스트와 validate로 quota·LimitRange 목표값을 증명한다. CI와 필수
  승인을 받은 뒤 squash merge한다.

---

### Task 2: dev → admin 적용 및 live 검증

**Files:**

- Execute: `.github/workflows/apply.yml`
- Record evidence: `SKYAHO/Autoresearch-infra#624`

**Consumes:** 병합된 용량 PR과 Gate 0 무부하 상태.

**Produces:** GKE와 Kubernetes의 live 용량이 목표 계약과 일치한다는 증거.

- [ ] **Step 1: dev root 적용**

  `apply.yml`을 `scope: dev`로 dispatch하고 Environment 승인을 거쳐 적용한다. plan/apply 대상이 `google_container_node_pool.batch_od` 범위를 벗어나면 중단한다.

- [ ] **Step 2: node pool live 확인**

  ```bash
  gcloud container node-pools describe batch-od \
    --cluster autoresearch-dev-gke \
    --zone asia-northeast3-a \
    --project autoresearch-503903
  ```

  machine type `e2-standard-8`, `pd-standard` 100GB, autoscaling min 0/max 2,
  기존 taint가 확인돼야 한다.

- [ ] **Step 3: admin root 적용**

  dev 적용 성공 후에만 `apply.yml`을 `scope: admin`으로 dispatch한다.

- [ ] **Step 4: Kubernetes live 확인**

  ```bash
  kubectl -n autoresearch-experiments get limitrange experiment-jobs-limits -o yaml
  kubectl -n autoresearch-experiments get resourcequota experiment-jobs-quota -o yaml
  ```

  LimitRange는 Container/Pod `4 CPU/8Gi`, quota는 Jobs/Pods 5, requests
  `5 CPU/10Gi`, limits `20 CPU/40Gi`여야 한다. canary node가 생기면 allocatable
  ephemeral storage가 40Gi보다 크고 `DiskPressure=False`인지 함께 확인한다.
  결과를 #624에 기록한다.

---

### Task 3: 애플리케이션 #669 및 동시 2건 canary

**Files:**

- External review/deploy: `SKYAHO/Autoresearch#669`
- Observe: live executor Jobs/Pods, Streamlit workbench

**Consumes:** Task 2의 live 용량과 launcher 상한 `2`.

**Produces:** 새 executor 자원 계약이 admission·scheduling·관측 경로에서 안전하다는 증거.

- [ ] **Step 1: #669 계약 확인**

  #669가 #665 이후 `main`을 반영했고 모든 executor container에서 `envFrom`과
  `env[].valueFrom`을 사용하지 않는지 확인한다. 먼저
  `tests/test_launcher_job_resources.py`의 requests 기대값을 `1 CPU/2Gi`로 바꾸고
  기존 구현에서 실패하는지 확인한다. 그 뒤 `agent_orchestration/launcher/jobs.py`의
  `_container_resources()` requests만 `1 CPU/2Gi`로 낮추고 limits `4 CPU/8Gi`는
  유지한다. 관련 테스트를 통과시킨 뒤 승인·병합한다.

  ```python
  for container in _all_containers(job):
      assert container.resources.requests["memory"] == "2Gi", container.name
      assert container.resources.requests["cpu"] == "1", container.name
  ```

  ```python
  return V1ResourceRequirements(
      requests={"cpu": "1", "memory": "2Gi"},
      limits={"cpu": "4", "memory": "8Gi"},
  )
  ```

  ```bash
  uv run pytest tests/test_launcher_job_resources.py \
    tests/test_harness_resource_budget.py -q
  ```

- [ ] **Step 2: 이미지 승격과 ArgoCD 동기화 확인**

  #669 이미지 release, infra digest 승격, ArgoCD `Synced/Healthy`가 모두 끝날 때까지 launcher 상한을 변경하지 않는다.

- [ ] **Step 3: 동시 2건 canary**

  같은 조건의 실험 2건을 동시에 제출한다. 두 Pod가 requests `1 CPU/2Gi`, limits
  `4 CPU/8Gi`로 `Running`에 도달하고 quota 403, LimitRange `FailedCreate`, 장기
  `Pending`이 없어야 한다.

  ```bash
  kubectl -n autoresearch-experiments get jobs,pods -o wide
  kubectl -n autoresearch-experiments get events --sort-by=.lastTimestamp
  ```

- [ ] **Step 4: 사용자 경로 확인**

  두 실험의 상태·로그·이벤트·결과가 Streamlit 워크벤치에 갱신되는지 확인하고 #624에 증거를 남긴다. 실패하면 Task 4로 진행하지 않는다.

---

### Task 4: launcher 5 전환 및 최종 smoke

**Files:**

- Modify: `scripts/check-experiment-launcher-manifest-contract.rb`
- Modify: `deploy/agent-orchestration/launcher-cronjob.yaml`
- Modify: `docs/runbooks/2026-08-01-auto-research-experiment-job.md`
- Modify: `docs/CHANGE_HISTORY.md`

**Consumes:** Task 3의 2건 canary 성공.

**Produces:** launcher 상한 5와 실험 5건 end-to-end 검증이 완료된 두 번째 PR 및 live 상태.

- [ ] **Step 1: 두 번째 이슈 연결 브랜치 생성**

  최신 `main`에서 #624의 `Create a branch`로 별도 브랜치를 만든다. 첫 번째 용량 브랜치를 재사용하지 않는다.

- [ ] **Step 2: failing contract test와 최소 구현**

  Ruby contract의 기대값을 `5`로 바꾸고 실패를 확인한 뒤 CronJob의 `ORCH_MAX_CONCURRENT_EXPERIMENTS`만 `"5"`로 변경한다. 이미지 digest와 다른 환경 변수는 그대로 둔다.

  ```bash
  ruby scripts/check-experiment-launcher-manifest-contract.rb
  ```

- [ ] **Step 3: 최종 운영 문서와 검증**

  runbook의 live 상한을 5로 갱신하고 두 PR 배포 순서와 rollback 결정을 `CHANGE_HISTORY.md`에 요약한다.

  ```bash
  ruby scripts/check-experiment-launcher-manifest-contract.rb
  git diff --check
  ```

- [ ] **Step 4: 동시성 PR 병합 및 ArgoCD 확인**

  템플릿에 따라 `Refs #624` Draft PR을 만들고 CI·승인 후 squash merge한다. ArgoCD가 `Synced/Healthy`이고 live CronJob의 환경 변수가 `"5"`인지 확인한다.

  ```bash
  kubectl -n autoresearch get cronjob agent-orchestration-launcher \
    -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="ORCH_MAX_CONCURRENT_EXPERIMENTS")].value}{"\n"}'
  ```

- [ ] **Step 5: 실험 5건 최종 smoke**

  실험 5건을 동시에 제출해 executor Pod 5개가 모두 `Running`에 도달하는지 확인한다. quota/admission/scheduling 오류가 없고 워크벤치에 5건의 상태·로그·이벤트가 갱신돼야 한다.

- [ ] **Step 6: 완료 기록 또는 rollback**

  성공 증거를 #624에 기록하고 이슈를 닫는다. 실패하면 launcher를 먼저 `2`로 되돌리는 GitOps PR로 새 선점을 막고, active Job 종료 후에만 필요 시 quota·LimitRange와 node pool을 이전 값으로 되돌린다. namespace, KSA, 결과 버킷 삭제나 Terraform state 조작은 금지한다.

## 완료 조건

- `batch-od`: `e2-standard-8`, `pd-standard` 100GB, min 0/max 2
- LimitRange Container/Pod max: `4 CPU/8Gi`
- ResourceQuota: Jobs/Pods 5, requests `5 CPU/10Gi`, limits `20 CPU/40Gi`
- #669 자원값으로 동시 2건 canary 통과
- launcher concurrency 5와 실험 5건 smoke 통과
- Streamlit에 5건의 상태·로그·이벤트 갱신
- 관련 Terraform 문서, runbook, `CHANGE_HISTORY.md`가 live 상태와 일치
