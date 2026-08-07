# 실험 Job 어드미션 계약 일반화·Phase 2 executor 경계 구현 계획 (#562)

> **설계 정본:** `docs/superpowers/specs/2026-08-07-experiment-executor-phase2-admission-design.md`
> 이 문서는 그 설계를 작업 단위로 분해한다. 두 문서가 어긋나면 설계 문서를 따른다.
>
> **에이전트 작업자용:** 각 Task는 독립적으로 검증 가능한 산출물로 끝난다.
> 체크박스(`- [ ]`)로 진행을 추적한다.

**Goal:** `autoresearch-experiments` namespace의 어드미션 계약을 Job 종류별
계약으로 일반화하고, Phase 2 executor Job(8-container)의 어드미션·자격 증명·
네트워크·자원 경계를 추가한다. 기존 `branch-bootstrap` 계약은 동등하게 보존한다.

**Architecture:** Kubernetes 경계(계약·Secret·NetworkPolicy·quota)는
`terraform/admin/autoresearch-k8s`가 소유한다. 배포 manifest와 launcher 설정은
`deploy/agent-orchestration/`(ArgoCD plain manifests)가 소유한다. Job 조립 로직과
`activeDeadlineSeconds` 결정은 애플리케이션 저장소 `SKYAHO/Autoresearch` 범위이며
이 계획에 포함하지 않는다.

**Tech Stack:** Terraform (`kubernetes` provider, `kubernetes_manifest`),
Kubernetes ValidatingAdmissionPolicy (CEL), `terraform test` (`.tftest.hcl`),
Ruby 계약 검사 스크립트, ArgoCD.

**관련 이슈:** 이 저장소 `#562`, 인접 `#561`(골격 승계),
애플리케이션 `SKYAHO/Autoresearch#557` / PR #564 / **PR #568**.

## Global Constraints

- 관찰 정본 SHA는 `e5ce030979f573dfcd9117a1bfaf456e4a6aff75`(PR #568)다. Job
  형태에 관한 모든 값은 이 SHA의 `agent_orchestration/launcher/jobs.py`에서
  확인한 값만 쓴다. 추정값을 쓰지 않는다.
- `ORCH_ACTIVE_DEADLINE_SEC`는 **3600 이하**여야 한다. 넘기면 launcher는
  통과하지만 어드미션이 Job을 거부하고, 실패가 launcher 로그에만 남는다.
- Codex 인증 원본은 PVC가 아니라 **Kubernetes Secret**이다(`auth.json` key 1개).
  `defaultMode`는 launcher가 지정하므로 이 저장소는 Secret과 key 존재만 소유한다.
- 기존 `branch-bootstrap` 계약은 **동등하게 보존**한다. 이는 정리 누락이 아니라
  롤백 전제조건이다(설계 3.5).
- image는 release가 게시한 `@sha256:` digest만 쓴다. digest를 지어내지 않고,
  Artifact Registry에서 조회한 값만 반영한다.
- 리전 `asia-northeast3`, node pool `batch-od`를 유지한다. 새 node pool을 만들지
  않는다.
- Secret 값·Terraform state·실제 tfvars는 커밋·PR·로그에 남기지 않는다.
- 각 Task는 `terraform fmt -recursive`와 `validate`를 통과한 상태로 커밋한다.
- 커밋 메시지는 `CONTRIBUTING.md` 컨벤션(`type: 한국어 설명한다 (#562)`)을 따른다.

## File Structure

| 파일 | 책임 | 변경 |
| --- | --- | --- |
| `terraform/admin/autoresearch-k8s/locals.tf` | Job 종류별 계약 정의 map | 수정 |
| `terraform/admin/autoresearch-k8s/experiment_jobs.tf` | 계약 렌더링, quota, NetworkPolicy | 수정 |
| `terraform/admin/autoresearch-k8s/experiment_executor.tf` | Phase 2 전용 Secret 2종·egress | **신설** |
| `terraform/admin/autoresearch-k8s/variables.tf` | 신규 변수 | 수정 |
| `terraform/admin/autoresearch-k8s/tests/experiment_jobs_contract.tftest.hcl` | 계약 회귀 테스트 | **신설** |
| `deploy/agent-orchestration/launcher-cronjob.yaml` | launcher 설정·digest | 수정 |
| `scripts/check-experiment-launcher-manifest-contract.rb` | manifest↔계약 동기화 검사 | 수정 |
| `docs/runbooks/2026-08-01-auto-research-experiment-job.md` | 운영·롤백 절차 | 수정 |
| `docs/CHANGE_HISTORY.md`, `docs/INFRASTRUCTURE_SUMMARY.md` | 변경 이력·현황 | 수정 |

Phase 2 전용 리소스를 `experiment_executor.tf`로 분리하는 이유: 저장소 규칙이
리소스 종류별 파일 분리를 따르고, `experiment_jobs.tf`가 이미 618줄이라 Phase 2
리소스를 더하면 한 파일에서 다루기 어려워진다. 계약 자체는 Phase 1/2가 한
정책 객체를 공유하므로 `experiment_jobs.tf`에 남긴다.

---

### Task 1: 계약 골격 도입 (동작 무변경)

계약을 `component`별 map에서 생성하도록 구조만 바꾼다. 이 Task 이후에도 등록된
종류는 `branch-bootstrap` 하나이며 **렌더링 결과가 의미상 동일**해야 한다.

**Files:**
- Modify: `terraform/admin/autoresearch-k8s/locals.tf:46-54`
- Modify: `terraform/admin/autoresearch-k8s/experiment_jobs.tf:342-420`
- Create: `terraform/admin/autoresearch-k8s/tests/experiment_jobs_contract.tftest.hcl`

**Interfaces:**
- Produces: `local.experiment_job_contracts` — key는 `component` label 값,
  value는 `{ init_containers = list(string), app_containers = list(string),
  volumes = list(string), credential_mounts = map(list(string)) }`.
  Task 2·3이 이 구조를 확장한다.

- [ ] **Step 1: 계약 회귀 테스트를 먼저 쓴다**

`terraform/admin/autoresearch-k8s/tests/experiment_jobs_contract.tftest.hcl`을
만든다. 변수 블록과 mock provider는 같은 디렉터리의
`experiment_runtime_contract.tftest.hcl`에서 그대로 가져온다(좌표 값은 카탈로그와
동일하게 유지해야 한다).

```hcl
run "branch_bootstrap_contract_is_preserved" {
  command = plan

  assert {
    condition = contains(
      keys(local.experiment_job_contracts),
      "branch-bootstrap"
    )
    error_message = "branch-bootstrap 계약은 롤백 경로이므로 제거할 수 없다."
  }

  assert {
    condition = local.experiment_job_contracts["branch-bootstrap"].init_containers == ["github-token-minter"]
    error_message = "branch-bootstrap의 initContainer 계약이 바뀌면 롤백된 launcher가 거부된다."
  }

  assert {
    condition = local.experiment_job_contracts["branch-bootstrap"].app_containers == ["branch-bootstrap"]
    error_message = "branch-bootstrap의 app container 계약이 바뀌면 롤백된 launcher가 거부된다."
  }
}
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s init -backend=false
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s test
```

기대: `local.experiment_job_contracts`가 없어 실패한다.

> **확인 완료 (2026-08-07):** `mock_provider "kubernetes"` + `override_data`
> 두 개(`kube_dns`, `autoresearch_serving`)를 두면 `kubernetes_manifest`가
> plan 단계에서 정상 렌더링되고, `local.*`도 `run` 블록 assert에서 직접 참조
> 가능하다. output 우회는 필요 없어 채택하지 않았다.
>
> **로컬 실행 주의:** `scripts/terraform-env`는 Ruby를 요구한다(카탈로그 파서).
> Ruby가 없는 환경에서는 `terraform -chdir=terraform/admin/autoresearch-k8s test`를
> 직접 쓴다 — 테스트 파일이 `variables` 블록으로 좌표를 자체 공급하므로 카탈로그가
> 필요 없다. `init -backend=false`도 마찬가지다. CI는 래퍼를 그대로 쓴다.

- [ ] **Step 3: 계약 map을 `locals.tf`에 추가한다**

기존 `experiment_branch_*` local들은 지우지 않고 map이 참조하게 한다(다른 파일이
참조 중일 수 있다).

```hcl
  # Job 종류별 어드미션 계약. key는 Pod template의
  # `app.kubernetes.io/component` label 값이다. 이 map에 없는 종류는 정책이
  # 거부하므로, 새 Job 종류를 도입하는 변경은 여기 항목을 먼저 추가한다.
  #
  # `credential_mounts`는 "이 volume을 마운트할 수 있는 컨테이너 이름"을 뜻한다.
  # 목록에 없는 컨테이너는 init/app 구분 없이 마운트가 거부된다(Task 2).
  experiment_job_contracts = {
    (local.experiment_branch_bootstrap_component_label) = {
      init_containers = [local.experiment_branch_bootstrap_init_container]
      app_containers  = [local.experiment_branch_bootstrap_app_container]
      volumes = [
        local.experiment_branch_writer_key_volume,
        local.experiment_branch_token_volume,
      ]
      credential_mounts = {
        (local.experiment_branch_writer_key_volume) = [local.experiment_branch_bootstrap_init_container]
        (local.experiment_branch_token_volume) = [
          local.experiment_branch_bootstrap_init_container,
          local.experiment_branch_bootstrap_app_container,
        ]
      }
    }
  }
```

- [ ] **Step 4: 정책이 map에서 컨테이너·label 규칙을 생성하도록 바꾼다**

`experiment_jobs.tf`에 policy `variables`로 component를 한 번만 추출한다.
`admissionregistration.k8s.io/v1`은 GKE 1.30+ GA API이므로 `variables`를 쓸 수 있다.

```hcl
      variables = [{
        name = "component"
        expression = join("", [
          "has(object.spec.template.metadata) && ",
          "has(object.spec.template.metadata.labels) && ",
          "'app.kubernetes.io/component' in object.spec.template.metadata.labels ",
          "? object.spec.template.metadata.labels['app.kubernetes.io/component'] : ''",
        ])
      }]
```

`:407`의 단일 label 규칙을 "알려진 종류 중 하나"로 바꾼다.

```hcl
        {
          expression    = "variables.component in ${jsonencode(keys(local.experiment_job_contracts))}"
          message       = "실험 Job의 Pod template은 승인된 app.kubernetes.io/component label을 가져야 합니다."
        },
```

`:359`·`:363`의 개수·이름 고정을 map 기반 종류별 규칙으로 대체한다. 목록 비교를
쓰면 개수·이름·**순서**를 한 규칙으로 고정할 수 있다.

```hcl
        for component, contract in local.experiment_job_contracts : {
          expression = join("", [
            "variables.component != '${component}' || (",
            "has(object.spec.template.spec.initContainers) && ",
            "object.spec.template.spec.initContainers.map(c, c.name) == ${jsonencode(contract.init_containers)} && ",
            "object.spec.template.spec.containers.map(c, c.name) == ${jsonencode(contract.app_containers)})",
          ])
          message = "${component} Job의 컨테이너 구성이 승인된 계약과 다릅니다."
        }
```

volume 집합 고정(`:373`)도 같은 방식으로 종류별로 만든다.

```hcl
        for component, contract in local.experiment_job_contracts : {
          expression = join("", [
            "variables.component != '${component}' || (",
            "has(object.spec.template.spec.volumes) && ",
            "object.spec.template.spec.volumes.size() == ${length(contract.volumes)} && ",
            "${jsonencode(contract.volumes)}.all(n, object.spec.template.spec.volumes.exists_one(v, v.name == n)))",
          ])
          message = "${component} Job은 승인된 volume 집합만 사용해야 합니다."
        }
```

> volume의 **모양**(Secret 이름, emptyDir medium/sizeLimit) 규칙은 이 Task에서
> 기존 `:373` 표현식의 해당 부분을 그대로 남긴다. 종류별 모양 규칙은 Task 3에서
> 다룬다.

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

```bash
terraform -chdir=terraform/admin/autoresearch-k8s fmt -recursive
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s validate
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s test
```

기대: 3개 assert 모두 PASS.

- [ ] **Step 6: 커밋**

```bash
git add terraform/admin/autoresearch-k8s/locals.tf \
        terraform/admin/autoresearch-k8s/experiment_jobs.tf \
        terraform/admin/autoresearch-k8s/tests/experiment_jobs_contract.tftest.hcl
git commit -m "refactor: 실험 Job 어드미션 계약을 종류별 구조로 일반화한다 (#562)"
```

---

### Task 2: 자격 증명 마운트 규칙을 allowlist로 반전

설계 3.2·3.3. 이번 변경의 핵심이며, 여전히 등록된 종류는 `branch-bootstrap`
하나이므로 동작은 동등해야 한다.

**Files:**
- Modify: `terraform/admin/autoresearch-k8s/experiment_jobs.tf:378-390`
- Modify: `terraform/admin/autoresearch-k8s/tests/experiment_jobs_contract.tftest.hcl`

**Interfaces:**
- Consumes: Task 1의 `local.experiment_job_contracts[*].credential_mounts`

- [ ] **Step 1: 반전이 실제로 적용됐는지 검사하는 테스트를 먼저 쓴다**

렌더링된 정책 문자열에 "모든 initContainer가 키를 마운트해야 한다"는 형태가
남아 있지 않아야 한다.

```hcl
run "private_key_rule_is_an_allowlist_not_a_requirement" {
  command = plan

  assert {
    condition = alltrue([
      for validation in local.experiment_job_admission_validations :
      !strcontains(
        validation.expression,
        "initContainers.all(c, has(c.volumeMounts) && c.volumeMounts.exists_one(m, m.name == 'github-app-private-key'"
      )
    ])
    error_message = "모든 initContainer에 private key 마운트를 요구하면 Codex 컨테이너에 개인키를 넣으라는 요구가 된다(설계 3.2)."
  }
}
```

> 이 assert가 동작하려면 Step 3에서 validations 목록을
> `local.experiment_job_admission_validations`로 추출해 정책이 그것을 참조하게
> 해야 한다. Task 1 Step 2에서 output 방식을 택했다면 여기도 output으로 맞춘다.

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s test
```

기대: 현행 `:383` 표현식이 그대로 남아 있어 FAIL.

- [ ] **Step 3: 규칙을 allowlist로 다시 쓴다**

`:383`의 표현식을 제거하고, `credential_mounts` map에서 volume별 규칙을 생성한다.

```hcl
        for pair in flatten([
          for component, contract in local.experiment_job_contracts : [
            for volume, holders in contract.credential_mounts : {
              component = component
              volume    = volume
              holders   = holders
            }
          ]
        ]) : {
          expression = join("", [
            "variables.component != '${pair.component}' || ",
            "(object.spec.template.spec.initContainers + object.spec.template.spec.containers).all(c, ",
            "!has(c.volumeMounts) || c.volumeMounts.all(m, m.name != '${pair.volume}') || ",
            "c.name in ${jsonencode(pair.holders)})",
          ])
          message = "${pair.component} Job에서 ${pair.volume} volume은 승인된 컨테이너만 mount할 수 있습니다."
        }
```

private key는 추가로 "허용된 컨테이너는 readOnly로 마운트해야 한다"를 유지한다.

```hcl
        for component, contract in local.experiment_job_contracts : {
          expression = join("", [
            "variables.component != '${component}' || ",
            "(object.spec.template.spec.initContainers + object.spec.template.spec.containers).all(c, ",
            "!has(c.volumeMounts) || c.volumeMounts.all(m, ",
            "m.name != '${local.experiment_branch_writer_key_volume}' || m.readOnly == true))",
          ])
          message = "GitHub App private key volume은 readOnly로만 mount해야 합니다."
        }
```

기존 `:383` 후반부의 "app container는 키를 마운트할 수 없다"는 위 allowlist에
포함되므로(app container 이름이 `holders`에 없다) 별도 규칙을 남기지 않는다.
`:378-382`의 주석은 반전된 의미에 맞게 다시 쓴다 — 설계 3.2를 3줄 이내로 요약하고
설계 문서를 참조시킨다.

- [ ] **Step 4: 테스트 통과와 동등성을 확인한다**

```bash
terraform -chdir=terraform/admin/autoresearch-k8s fmt -recursive
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s test
```

기대: Task 1의 3개 + 이번 1개 모두 PASS.

- [ ] **Step 5: 커밋**

```bash
git add terraform/admin/autoresearch-k8s/
git commit -m "fix: private key 마운트 규칙을 컨테이너 allowlist로 반전한다 (#562)"
```

---

### Task 3: `experiment-executor` 계약 항목 추가

**Files:**
- Modify: `terraform/admin/autoresearch-k8s/locals.tf`
- Modify: `terraform/admin/autoresearch-k8s/variables.tf`
- Modify: `terraform/admin/autoresearch-k8s/experiment_jobs.tf`
- Modify: `terraform/admin/autoresearch-k8s/tests/experiment_jobs_contract.tftest.hcl`

**Interfaces:**
- Consumes: Task 1·2의 map 구조
- Produces: `var.experiment_executor_api_token_secret_name`,
  `var.experiment_codex_home_secret_name`, `var.experiment_workspace_size_limit` —
  Task 4·7이 같은 값을 참조한다.

- [ ] **Step 1: executor 계약 테스트를 먼저 쓴다**

`codex-worker`가 **GitHub 자격 증명과 내부 API 토큰을 갖지 못한다**는 것이 이
계약의 핵심이다. `codex-home`(Codex 인증)은 예외이며, 그것만 가질 수 있다.

```hcl
run "codex_worker_holds_no_github_credential" {
  command = plan

  assert {
    condition = alltrue([
      for volume, holders in local.experiment_job_contracts["experiment-executor"].credential_mounts :
      !contains(holders, "codex-worker")
      if volume != "codex-home"
    ])
    error_message = "codex-worker는 codex-home 외 어떤 자격 증명 volume도 mount할 수 없다(설계 3.3·3.4)."
  }

  assert {
    condition     = local.experiment_job_contracts["experiment-executor"].credential_mounts["codex-home"] == ["codex-worker"]
    error_message = "Codex 인증 Secret은 codex-worker 외 어떤 컨테이너도 mount할 수 없다."
  }

  assert {
    condition = alltrue([
      for volume, holders in local.experiment_job_contracts["experiment-executor"].credential_mounts :
      !contains(holders, "candidate-verifier")
    ])
    error_message = "candidate-verifier는 어떤 자격 증명 volume도 mount할 수 없다."
  }

  assert {
    condition = local.experiment_job_contracts["experiment-executor"].init_containers == [
      "branch-token-minter",
      "branch-creator",
      "clone-token-minter",
      "workspace-preparer",
      "codex-worker",
      "candidate-verifier",
      "push-token-minter",
    ]
    error_message = "executor initContainer 순서는 토큰 발급 직후 사용 순서를 고정한다."
  }

  assert {
    condition     = local.experiment_job_contracts["experiment-executor"].app_containers == ["candidate-finalizer"]
    error_message = "executor의 app container는 candidate-finalizer 하나여야 한다."
  }
}
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s test
```

기대: `experiment-executor` key가 없어 FAIL.

- [ ] **Step 3: 변수를 추가한다**

`variables.tf`:

```hcl
variable "experiment_executor_api_token_secret_name" {
  description = "candidate-finalizer가 in-cluster Experiment API 보고에 사용하는 Secret 이름."
  type        = string
}

variable "experiment_codex_home_secret_name" {
  description = "codex-worker만 readOnly subPath로 mount하는 Codex 인증 Secret 이름. auth.json key 하나를 제공한다."
  type        = string
}

variable "experiment_workspace_size_limit" {
  description = "executor workspace emptyDir sizeLimit. 노드 ephemeral storage를 소비하므로 quota와 함께 조정한다."
  type        = string
}
```

`terraform.tfvars.example`에 세 값의 예시를 추가한다(실제 tfvars는 커밋하지 않는다).

- [ ] **Step 4: 계약 항목을 추가한다**

`locals.tf`의 `experiment_job_contracts`에 항목을 더한다. 값은 정본 SHA
`e5ce030`의 `build_executor_job()`에서 확인한 것이다.

```hcl
    "experiment-executor" = {
      init_containers = [
        "branch-token-minter",
        "branch-creator",
        "clone-token-minter",
        "workspace-preparer",
        "codex-worker",
        "candidate-verifier",
        "push-token-minter",
      ]
      app_containers = ["candidate-finalizer"]
      volumes = [
        local.experiment_branch_writer_key_volume,
        "branch-token",
        "clone-token",
        "push-token",
        "workspace",
        "executor-state",
        "verification-result",
        "executor-tmp",
        "codex-home",
        "executor-api-token",
      ]
      # codex-worker가 codex-home 외 어느 목록에도 없고 candidate-verifier가
      # 어느 목록에도 없다는 것이 이 계약의 핵심이다. 두 컨테이너는 네트워크로는
      # GitHub·OpenAI에 닿지만(Pod 단위 NetworkPolicy의 한계, 설계 3.4) 쓸 GitHub
      # 자격 증명이 없다. 반대로 codex-home은 codex-worker만 mount할 수 있어
      # Codex 인증이 GitHub을 만지는 컨테이너로 새는 경로도 닫힌다.
      credential_mounts = {
        (local.experiment_branch_writer_key_volume) = [
          "branch-token-minter",
          "clone-token-minter",
          "push-token-minter",
        ]
        "branch-token"       = ["branch-token-minter", "branch-creator"]
        "clone-token"        = ["clone-token-minter", "workspace-preparer"]
        "push-token"         = ["push-token-minter", "candidate-finalizer"]
        "executor-api-token" = ["candidate-finalizer"]
        "codex-home"         = ["codex-worker"]
      }
    }
```

- [ ] **Step 5: volume 모양 규칙을 종류별로 만든다**

Task 1 Step 4에서 남겨둔 기존 `:373` 모양 규칙을 종류별 규칙으로 옮긴다.
executor에 대해 아래를 강제한다.

```hcl
        {
          expression = join("", [
            "variables.component != 'experiment-executor' || (",
            # 토큰·상태·결과 volume은 디스크에 남지 않아야 한다.
            "['branch-token','clone-token','push-token','executor-state','verification-result'].all(n, ",
            "object.spec.template.spec.volumes.exists_one(v, v.name == n && has(v.emptyDir) && ",
            "v.emptyDir.medium == 'Memory' && v.emptyDir.sizeLimit == '1Mi')) && ",
            # workspace는 디스크 기반이므로 sizeLimit이 승인값과 같아야 한다.
            "object.spec.template.spec.volumes.exists_one(v, v.name == 'workspace' && has(v.emptyDir) && ",
            "!has(v.emptyDir.medium) && v.emptyDir.sizeLimit == '${var.experiment_workspace_size_limit}') && ",
            # Codex 인증은 auth.json key 하나만 노출하는 Secret이어야 한다.
            # items를 고정하지 않으면 Secret에 다른 key가 추가될 때 그것까지
            # codex-worker에 노출된다.
            "object.spec.template.spec.volumes.exists_one(v, v.name == 'codex-home' && has(v.secret) && ",
            "v.secret.secretName == '${var.experiment_codex_home_secret_name}' && ",
            "has(v.secret.items) && v.secret.items.map(i, i.key) == ['auth.json']) && ",
            # 나머지 Secret volume의 이름을 고정한다.
            "object.spec.template.spec.volumes.exists_one(v, v.name == '${local.experiment_branch_writer_key_volume}' && ",
            "has(v.secret) && v.secret.secretName == '${var.experiment_branch_writer_secret_name}') && ",
            "object.spec.template.spec.volumes.exists_one(v, v.name == 'executor-api-token' && ",
            "has(v.secret) && v.secret.secretName == '${var.experiment_executor_api_token_secret_name}'))",
          ])
          message = "experiment-executor Job의 volume 모양이 승인된 계약과 다릅니다."
        },
```

- [ ] **Step 6: 테스트 통과를 확인한다**

```bash
terraform -chdir=terraform/admin/autoresearch-k8s fmt -recursive
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s validate
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s test
```

기대: Task 1·2·3의 assert 전부 PASS.

- [ ] **Step 7: 커밋**

```bash
git add terraform/admin/autoresearch-k8s/
git commit -m "feat: Phase 2 executor Job 어드미션 계약을 추가한다 (#562)"
```

---

### Task 4: Codex 인증 Secret과 `executor-api-token` Secret 신설

애플리케이션 PR #568에서 Codex 인증 원본이 PVC에서 **Kubernetes Secret**으로
바뀌었다(설계 4절). 두 신설 리소스가 모두 Secret이다.

**Files:**
- Create: `terraform/admin/autoresearch-k8s/experiment_executor.tf`
- Modify: `terraform/admin/autoresearch-k8s/tests/experiment_jobs_contract.tftest.hcl`

**Interfaces:**
- Consumes: Task 3의 `var.experiment_codex_home_secret_name`,
  `var.experiment_executor_api_token_secret_name`

- [ ] **Step 1: Secret 경계 테스트를 먼저 쓴다**

Secret **값**은 테스트하지 않는다. 이름·namespace·key 집합만 검증한다.

```hcl
run "codex_auth_secret_exposes_only_auth_json" {
  command = plan

  assert {
    condition     = kubernetes_secret_v1.codex_home.metadata[0].namespace == "autoresearch-experiments"
    error_message = "Codex 인증 Secret은 실험 namespace 안에 있어야 한다."
  }

  assert {
    condition     = kubernetes_secret_v1.codex_home.metadata[0].name == var.experiment_codex_home_secret_name
    error_message = "Secret 이름은 launcher의 ORCH_CODEX_HOME_SECRET_NAME과 같아야 한다."
  }

  assert {
    condition     = keys(kubernetes_secret_v1.codex_home.data) == ["auth.json"]
    error_message = "key가 늘면 계약이 고정한 items와 어긋나 codex-worker에 의도치 않은 값이 노출된다."
  }
}
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s test
```

기대: 리소스가 없어 FAIL.

- [ ] **Step 3: Secret 두 개를 만든다**

`experiment_executor.tf`를 만든다. Secret **값**은 이 저장소에 두지 않는다 —
기존 `github-app-private-key` Secret이 쓰는 배치 경로와 같은 방식을 따르고, 어떤
방식인지 파일 상단 주석에 남긴다.

Codex 인증 Secret은 `auth.json` key **하나만** 갖는다. `defaultMode` 0440은
launcher가 volume 쪽에서 지정하므로 이 저장소는 지정하지 않는다(설계 4절).

주석에 남길 것: `subPath` 마운트는 실행 중 Secret 갱신을 전파하지 않으므로 Secret
교체는 새 Experiment부터 적용된다.

- [ ] **Step 4: 롤아웃 순서를 주석과 runbook 항목으로 고정한다**

Secret을 **먼저** 만들고 그 다음 launcher 설정·이미지를 배포한다. 순서가 뒤집히면
kubelet이 mount를 완료하지 못해 Pod가 `Pending`에 머물고, Job은 3600초 뒤에야
`Failed`가 된다. 진단 근거는 Pod event의 `FailedMount`와 Job의 `DeadlineExceeded`다.

이 순서를 파일 상단 주석에 3줄 이내로 남기고, Task 10에서 runbook에 반영한다.

- [ ] **Step 5: 테스트 통과 확인 후 커밋**

```bash
terraform -chdir=terraform/admin/autoresearch-k8s fmt -recursive
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s test
git add terraform/admin/autoresearch-k8s/
git commit -m "feat: executor Codex 인증·API token Secret 경계를 추가한다 (#562)"
```

---

### Task 5: `ephemeral-storage` quota·LimitRange 추가

설계 6절. `workspace`가 디스크 기반 emptyDir인데 통제가 비어 있다.

**Files:**
- Modify: `terraform/admin/autoresearch-k8s/experiment_jobs.tf:46-130`
- Modify: `terraform/admin/autoresearch-k8s/tests/experiment_jobs_contract.tftest.hcl`

- [ ] **Step 1: quota 테스트를 먼저 쓴다**

```hcl
run "ephemeral_storage_is_bounded" {
  command = plan

  assert {
    condition     = can(kubernetes_resource_quota_v1.experiment_jobs.spec[0].hard["requests.ephemeral-storage"])
    error_message = "workspace emptyDir이 노드 디스크를 소비하므로 ephemeral-storage 상한이 필요하다."
  }

  assert {
    condition = tonumber(replace(kubernetes_limit_range_v1.experiment_jobs.spec[0].limit[1].max["ephemeral-storage"], "Gi", "")) >= tonumber(replace(var.experiment_workspace_size_limit, "Gi", ""))
    error_message = "Pod ephemeral-storage 상한이 workspace sizeLimit보다 작으면 Job이 항상 거부된다."
  }
}
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s test
```

- [ ] **Step 3: quota와 LimitRange에 `ephemeral-storage`를 더한다**

ResourceQuota `hard`에 `requests.ephemeral-storage`·`limits.ephemeral-storage`를,
LimitRange의 Container·Pod 타입에 `ephemeral-storage` 기본값과 상한을 추가한다.
값은 `var.experiment_workspace_size_limit`에 `executor-tmp` 1Gi와 이미지 레이어
여유를 더해 정한다.

- [ ] **Step 4: Phase 2 자원 계산 주석을 갱신한다**

`:98-115` 주석이 branch-bootstrap 형태만 설명한다. Phase 2 계산을 추가한다:
initContainer 7개는 순차 실행이므로 Pod 실효 요청은
`max(500m, 500m)` = 500m이고 상한 1 CPU 안에 든다. "native sidecar로 바꾸면
상한에 걸린다"는 제약이 Phase 2에서도 유효함을 명시한다.

- [ ] **Step 5: 테스트 통과 확인 후 커밋**

```bash
terraform -chdir=terraform/admin/autoresearch-k8s fmt -recursive
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s test
git add terraform/admin/autoresearch-k8s/
git commit -m "feat: 실험 Job ephemeral-storage 상한을 추가한다 (#562)"
```

---

### Task 6: executor egress NetworkPolicy 신설

설계 5절. 기존 `experiment-jobs-branch-bootstrap-egress`는 손대지 않는다.

**Files:**
- Modify: `terraform/admin/autoresearch-k8s/experiment_executor.tf`
- Modify: `terraform/admin/autoresearch-k8s/tests/experiment_jobs_contract.tftest.hcl`

- [ ] **Step 1: egress 테스트를 먼저 쓴다**

```hcl
run "executor_egress_preserves_phase1_policy" {
  command = plan

  assert {
    condition     = kubernetes_network_policy_v1.experiment_jobs_branch_bootstrap_egress.spec[0].pod_selector[0].match_labels["app.kubernetes.io/component"] == "branch-bootstrap"
    error_message = "Phase 1 egress 정책은 롤백 경로이므로 유지해야 한다."
  }

  assert {
    condition     = kubernetes_network_policy_v1.experiment_executor_egress.spec[0].pod_selector[0].match_labels["app.kubernetes.io/component"] == "experiment-executor"
    error_message = "executor egress는 executor label에만 적용되어야 한다."
  }
}
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s test
```

- [ ] **Step 3: 정책을 만든다**

`experiment-jobs-branch-bootstrap-egress`를 본으로 두 규칙을 넣는다.

1. 공개 443 (`0.0.0.0/0`에서 `local.public_egress_private_cidr_exceptions` 제외)
   — GitHub과 OpenAI가 여기에 해당한다. Calico라 FQDN 지정이 불가능하다는 기존
   판단을 주석으로 승계한다.
2. `autoresearch` namespace의 Experiment API Service로 가는 in-cluster egress.
   namespace selector와 pod selector로 대상을 좁히고 포트를 API 포트로 한정한다.
   Cloud SQL은 열지 않는다.

주석에 설계 3.4를 요약한다: 이 정책은 Pod 단위이므로 `codex-worker`도 공개 443에
도달한다. 이를 막는 수단은 없으며 실질 경계는 Task 2·3의 자격 증명 allowlist다.

- [ ] **Step 4: 테스트 통과 확인 후 커밋**

```bash
terraform -chdir=terraform/admin/autoresearch-k8s fmt -recursive
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s test
git add terraform/admin/autoresearch-k8s/
git commit -m "feat: Phase 2 executor egress 경계를 추가한다 (#562)"
```

---

### Task 7: launcher CronJob 설정과 digest 반영

**Files:**
- Modify: `deploy/agent-orchestration/launcher-cronjob.yaml`

- [ ] **Step 1: 게시된 digest를 조회한다**

digest를 지어내지 않는다. Artifact Registry에서 정본 SHA에 대응하는 값을 읽는다.

```bash
gcloud artifacts docker images list \
  asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher \
  --include-tags --limit 5 --sort-by=~CREATE_TIME
```

launcher·executor·api 세 이미지에 대해 반복하고, 정본 SHA
`e5ce030979f573dfcd9117a1bfaf456e4a6aff75`에서 게시된 것인지 태그로 대조한다.

- [ ] **Step 2: 누락된 환경 변수 6개를 추가한다**

`launcher/config.py`의 `from_environment()`가 모두 `_required_environment`로 읽으므로
하나라도 없으면 launcher가 기동 시 죽는다. 현재 manifest에 없는 것은 다음 6개이며,
값은 애플리케이션 `.env.example`과 spec이 고정한 MVP 운영값을 쓴다.

```yaml
                - name: ORCH_EXECUTOR_API_URL
                  value: <autoresearch namespace의 Experiment API Service URL>
                - name: ORCH_EXECUTOR_API_TOKEN_SECRET_NAME
                  value: <Task 3의 var.experiment_executor_api_token_secret_name과 동일한 값>
                - name: ORCH_CODEX_HOME_SECRET_NAME
                  value: <Task 3의 var.experiment_codex_home_secret_name과 동일한 값>
                - name: ORCH_EXECUTOR_WORKSPACE_SIZE_LIMIT
                  value: "8Gi"
                - name: ORCH_ACTIVE_DEADLINE_SEC
                  value: "3600"
                - name: ORCH_CODEX_TIMEOUT_SEC
                  value: "1800"
```

두 시간 값에는 제약이 두 겹 있다.

- `ORCH_CODEX_TIMEOUT_SEC` **<** `ORCH_ACTIVE_DEADLINE_SEC` — 어기면 launcher가
  기동 시 `LauncherConfigError`로 죽는다.
- `ORCH_ACTIVE_DEADLINE_SEC` **≤ 3600** — 어기면 launcher는 통과하지만 어드미션이
  Job을 거부하고, 실패가 launcher 로그에만 남는다. Task 8이 이 상한을 검사한다.

- [ ] **Step 3: digest를 갱신한다**

launcher·executor image를 Step 1에서 확인한 digest로 바꾼다.

- [ ] **Step 4: 커밋**

```bash
git add deploy/agent-orchestration/launcher-cronjob.yaml
git commit -m "feat: launcher Phase 2 설정과 executor digest를 반영한다 (#562)"
```

---

### Task 8: manifest↔계약 동기화 검사 갱신

**Files:**
- Modify: `scripts/check-experiment-launcher-manifest-contract.rb`
- Modify: `scripts/test-check-experiment-launcher-manifest-contract.rb`

- [ ] **Step 1: 실패 케이스 테스트를 먼저 추가한다**

`scripts/test-check-experiment-launcher-manifest-contract.rb`에 세 케이스를
추가한다. 각각이 잡는 실제 실패가 다르다.

1. Task 7의 필수 환경 변수 6개 중 하나가 빠진 manifest → `ContractError`.
   실제 실패는 "launcher가 기동 시 죽는다".
2. `ORCH_CODEX_TIMEOUT_SEC >= ORCH_ACTIVE_DEADLINE_SEC`인 manifest →
   `ContractError`. 실제 실패도 launcher 기동 실패다.
3. `ORCH_ACTIVE_DEADLINE_SEC > 3600`인 manifest → `ContractError`. 실제 실패는
   "launcher는 뜨지만 어드미션이 Job을 거부하고 로그에만 남는다"이므로, 이 검사가
   없으면 조용히 아무 Job도 안 만들어지는 상태가 된다.

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
ruby scripts/test-check-experiment-launcher-manifest-contract.rb
```

- [ ] **Step 3: 검사를 갱신한다**

`check_cron_job!`에 필수 환경 변수 6개 존재 검사와 위 두 시간 제약 검사를 더하고,
기대 digest 상수를 Task 7의 값으로 갱신한다.

- [ ] **Step 4: 테스트와 실제 검사를 모두 돌린다**

```bash
ruby scripts/test-check-experiment-launcher-manifest-contract.rb
ruby scripts/check-experiment-launcher-manifest-contract.rb
```

- [ ] **Step 5: 커밋**

```bash
git add scripts/
git commit -m "test: launcher Phase 2 설정 계약 검사를 추가한다 (#562)"
```

---

### Task 9: server dry-run 검증

설계 8절 2층. Job을 실제로 띄우지 않고 어드미션 판정만 받는다.

**Files:** 없음 (검증 전용). 결과는 Task 10에서 문서에 기록한다.

- [ ] **Step 1: Terraform plan을 확인한다**

```bash
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s plan
```

계약 정책·Secret·NetworkPolicy·quota 외의 리소스에 변경이 없는지 확인한다.
기존 리소스의 교체(`must be replaced`)가 보이면 멈추고 원인을 먼저 밝힌다.

- [ ] **Step 2: apply한다**

```bash
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s apply
```

- [ ] **Step 3: 회귀부터 확인한다 — 기존 branch-bootstrap Job**

정본 SHA에서 `build_branch_job()`이 만드는 Job YAML을 준비해 dry-run한다.

```bash
kubectl apply --dry-run=server -f /tmp/branch-bootstrap-job.yaml
```

기대: 통과. **거부되면 롤백 경로가 막힌 것이므로 즉시 Terraform revert 후 apply.**

- [ ] **Step 4: 신규 executor Job을 dry-run한다**

```bash
kubectl apply --dry-run=server -f /tmp/experiment-executor-job.yaml
```

기대: 통과. 거부되면 메시지의 규칙을 Task 3으로 돌아가 수정하고 이 Step을 반복한다.
이 반복은 Pod를 만들지 않으므로 몇 초 단위이고 비용이 없다.

- [ ] **Step 5: 음성 대조를 확인한다**

계약이 실제로 막는지 확인한다. `codex-worker`에 `github-app-private-key`
volumeMount를 추가한 executor Job을 dry-run한다.

```bash
kubectl apply --dry-run=server -f /tmp/experiment-executor-job-codex-key.yaml
```

기대: **거부.** 메시지가 "승인된 컨테이너만 mount할 수 있습니다"여야 한다.
통과하면 Task 2·3의 allowlist가 동작하지 않는 것이므로 진행을 멈춘다.

- [ ] **Step 6: ArgoCD sync를 확인한다**

launcher CronJob이 새 설정·digest로 sync되고 기동 시 죽지 않는지 로그로 확인한다.

- [ ] **Step 7: 관측값을 기록한다**

Step 3~6의 실제 출력을 Task 10의 runbook 갱신에 쓸 수 있도록 정리한다.
Secret 값과 토큰은 기록하지 않는다.

---

### Task 10: 문서 갱신

**Files:**
- Modify: `docs/runbooks/2026-08-01-auto-research-experiment-job.md`
- Modify: `docs/CHANGE_HISTORY.md`
- Modify: `docs/INFRASTRUCTURE_SUMMARY.md`
- Modify: `CLAUDE.md` (autoresearch-k8s 파일 목록에 `experiment_executor.tf` 추가)

- [ ] **Step 1: runbook에 Phase 2 절차를 추가한다**

담을 내용: Phase 1/2 전환이 launcher image digest 하나로 결정되며 스위치가 없다는
것(설계 3.5), Task 9의 dry-run 절차와 실제 관측값, Secret을 먼저 만들고 launcher를 배포하는 롤아웃 순서
(Task 4 Step 4의 결정), 롤백 절차(설계 10절 표).

- [ ] **Step 2: `CHANGE_HISTORY.md`에 결정을 요약한다**

장기 보존이 필요한 결정만 남긴다: 계약을 종류별로 일반화한 것, private key 규칙을
allowlist로 반전한 이유, `branch-bootstrap` 계약 보존이 롤백 전제조건이라는 것.

- [ ] **Step 3: `INFRASTRUCTURE_SUMMARY.md`에 신규 리소스를 반영한다**

Codex 인증 Secret, `executor-api-token` Secret, executor egress 정책,
`ephemeral-storage` quota.

- [ ] **Step 4: 문서 검증 후 커밋**

```bash
git diff --check
git add docs/ CLAUDE.md
git commit -m "docs: Phase 2 executor 운영·롤백 절차를 갱신한다 (#562)"
```

---

### Task 11: 운영 smoke

이슈 #562의 완료 조건 8항목을 실제 Experiment 1건으로 검증한다. 이전 판에서는
`activeDeadlineSeconds` 고정 때문에 이 Task를 계획 밖으로 뺐으나, 애플리케이션
PR #568로 해소돼 계획 안으로 들어왔다(설계 9절).

**Files:** 없음 (검증 전용). 결과는 Task 10 문서에 반영한다.

- [ ] **Step 1: Task 9까지 전부 완료됐는지 확인한다**

특히 Task 9 Step 5(음성 대조)가 **거부**로 확인됐어야 한다. 통과했다면 자격 증명
경계가 강제되지 않는 상태이므로 smoke를 시작하지 않는다.

- [ ] **Step 2: 새 Experiment 1건을 제출하고 완주를 확인한다**

3600초 안에 8개 컨테이너가 순서대로 끝나는지 본다. 중간 실패 시 원인 판별 기준:
Pod event `FailedMount`(Secret 누락), Job `DeadlineExceeded`(시간 초과),
어드미션 거부 메시지(계약 불일치).

- [ ] **Step 3: 완료 조건 8항목을 대조한다**

DB `base_dev_sha` = candidate commit parent / DB `issue_branch` = GitHub branch /
DB `candidate_sha` = GitHub remote tip / 상태 `EVALUATING` /
`base_dev_sha..candidate_sha` commit 수가 정확히 1 / `main`·`dev`·다른 `exp/*` ref
무변화 / Codex·verifier mount·환경·로그에 GitHub·API credential 없음 /
관측값과 롤백 절차가 기록됨.

- [ ] **Step 4: 노드 가동 시간과 비용을 측정해 기록한다**

Job 1건의 점유가 300초에서 3600초로 늘었다(설계 11절). 실제 `batch-od` 노드 가동
시간을 측정해 runbook에 남긴다.

---

## 이 계획에 포함하지 않는 것

- **`activeDeadlineSeconds` 환경 변수화.** 애플리케이션 저장소
  `SKYAHO/Autoresearch` PR #568에서 **이미 완료됐다.** 이 저장소 범위가 아니다.
- **#561 판정 Job 계약.** Task 1~3의 골격에 항목 하나를 더하는 형태로 합류한다.

## 자체 점검

- 설계 3.1(골격 소유) → Task 1. 3.2(규칙 반전) → Task 2. 3.3(자격 증명별
  allowlist) → Task 3. 3.4(네트워크 한계 기록) → Task 3 주석·Task 6 주석.
  3.5(롤백 경로) → Task 1 테스트·Task 6 테스트·Task 10.
- 설계 4(신규 Secret 2종·롤아웃 순서) → Task 4. 5(네트워크) → Task 6.
  6(자원) → Task 5. 8(검증 3층) → Task 1~8의 `terraform test`, Task 9의 dry-run,
  Task 11의 smoke. 9(실행 상한) → Task 7 Step 2, Task 8 Step 1.
  10(롤백) → Task 10 Step 1. 11(비용) → Task 11 Step 4.
- 이전 판의 미결 2건은 모두 해소됐다. "PVC를 채우는 주체"는 PR #568의 Secret
  전환으로 사라졌고, `ORCH_CODEX_TIMEOUT_SEC` 값은 앱 spec이 1800으로 고정했다.
- 남은 확인 항목: Task 1 Step 2의 `kubernetes_manifest` mock plan 가능 여부.
  실행 시점에 확인하고 택한 방식을 체크박스 옆에 기록한다.
