# 실험 브랜치 launcher·executor 인프라 구현 계획 (#539)

> **정본은 이 문서가 아니다.** 이 변경의 설계·구현 정본은 애플리케이션 저장소
> `SKYAHO/Autoresearch`의
> `docs/plans/2026-08-05-experiment-branch-bootstrap-k8s-job-phase1.md` **Task 5**다.
> 이 문서는 그 Task 5를 이 저장소의 작업 단위로 분해한 포인터이며, 설계 결정을
> 새로 만들지 않는다. 두 문서가 어긋나면 애플리케이션 저장소 계획을 따른다.

**Goal:** 애플리케이션이 구현한 launcher(CronJob)와 executor(Job)가 dev GKE에서
돌 수 있도록 Kubernetes identity/RBAC, GitHub App Secret 경계, admission·network
정책, launcher CronJob, 운영 문서를 이 저장소에 반영한다.

**Architecture:** GCP identity(GSA·IAM)는 `terraform/envs/dev`, Kubernetes
경계(KSA·RBAC·admission·NetworkPolicy)는 `terraform/admin/autoresearch-k8s`,
배포 manifest는 `deploy/agent-orchestration/`(ArgoCD)가 소유한다. 애플리케이션
로직(선점, Job 조립, GitHub ref 생성)은 이 저장소 범위가 아니다.

**관련 이슈:** 이 저장소 `SKYAHO/Autoresearch-infra#539`,
애플리케이션 `SKYAHO/Autoresearch#546`

## Global Constraints

- 리전은 기존 `asia-northeast3`, 실행 위치는 기존 `batch-od` node pool을 유지하며
  새 node pool을 만들지 않는다.
- launcher/executor image는 release가 게시한 `@sha256:` digest만 쓴다. digest를
  추정하거나 mutable tag로 대체하지 않는다.
- GitHub App private key와 installation token은 코드·Terraform state·manifest·Pod
  환경 변수·로그에 넣지 않는다. 값 주입은 runbook의 수동 절차로만 한다.
- baseline-reader App은 `Contents: Read-only`, branch-writer App은 `Contents:
  Read and write`만 가지며 `SKYAHO/Autoresearch` 한 저장소에만 설치한다.
- executor KSA에는 Kubernetes RBAC를 부여하지 않고 ServiceAccount token도
  mount하지 않는다. Job 생성 권한은 launcher KSA만 가진다.
- 배포 순서: 애플리케이션 merge/release → infra plan/review/merge → 사용자 승인
  apply → smoke test.
- Terraform apply, GitHub App 생성·설치, Secret 주입, ArgoCD sync는 각각 별도
  승인 뒤에만 수행한다.

## Task 분해와 진행 상태

| Task | 범위 | 커밋 |
|---|---|---|
| T1 | dev root: launcher GSA + `cloudsql.client` + Workload Identity + DB password Secret accessor | `b3c3841` |
| T2 | admin root: launcher KSA, Job 생성 RBAC를 API KSA → launcher KSA로 이전 | `d6e3c3f` |
| T3 | admin root: admission에 branch-bootstrap Pod 형태 계약 추가 | `51d0fbd` |
| T4 | admin root: branch-bootstrap Pod 전용 공개 443 egress | `c1548d8` |
| T5 | `deploy/`: API에 baseline-reader Secret mount·env 배선 | `5855638` |
| T6 | `deploy/`: launcher CronJob + 전용 NetworkPolicy + 세 release digest 반영 | #551 |
| T7 | runbook 2종·CHANGE_HISTORY·이 문서 | `7419c8b`, #551 |

## 계획과 다르게 결정한 것

정본 계획을 벗어나지 않되, 구현 중 근거를 가지고 좁히거나 넓힌 지점을 남긴다.

- **launcher RBAC 동사를 3개로 좁혔다.** 정본은 `Pods`·`Events` read도 제안하지만
  launcher 코드에 해당 호출이 없다. `Jobs create/get/list`만 부여하고, 필요해지면
  그 시점에 추가한다.
- **`enable_experiment_job_creation` 변수 이름을 유지했다.** 이름에 주체가 들어
  있지 않아 그대로 두면 로컬 `tfvars`·runbook·CHANGE_HISTORY 참조가 깨지지 않는다.
  주체는 output 필드 `launcher_job_creation_enabled`와 설명이 드러낸다.
- **admission에 `env` 주입 금지와 label 요구 규칙을 더했다.** 정본이 명시한
  volume 계약만으로는 `secretKeyRef`로 키를 환경 변수에 주입해 우회할 수 있고,
  label이 없는 Job은 egress 정책 대상에서 빠져 timeout으로만 실패한다.
- **App ID·installation ID를 Secret에서 읽는다.** App 생성 전에는 값을 알 수 없어
  manifest에 리터럴로 박을 수 없다. #533이 확립한 패턴을 따른다.
- **API의 공개 443 egress는 이번 변경에 없다.** #525가 이미 같은 규칙(공개 443 +
  사설 대역 `except`)을 넣어 두었다.

## 검증

정적 검증은 Task마다 수행했다.

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
terraform -chdir=terraform/admin/autoresearch-k8s fmt -check -recursive
terraform -chdir=terraform/admin/autoresearch-k8s init -backend=false
terraform -chdir=terraform/admin/autoresearch-k8s validate
git diff --check
```

`scripts/terraform-env` wrapper는 Ruby가 필요하다. 로컬에 없으면 위처럼 `terraform`
을 직접 호출해도 실행되는 명령은 같지만, 환경 카탈로그 검증은 CI에서만 돈다.

apply 이후 검증(negative dry-run 12종, NetworkPolicy 음성 대조, smoke 실험 8개
항목)은 [실험 Job runbook](../../runbooks/2026-08-01-auto-research-experiment-job.md)이
소유한다. CEL 표현식과 NetworkPolicy는 `terraform validate`로 검증되지 않으므로 이
단계를 생략하지 않는다.
