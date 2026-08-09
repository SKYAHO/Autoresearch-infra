# 실험 Job 어드미션 계약(#562)의 회귀 테스트.
#
# 이 계약은 `validationActions = ["Deny"]` + `failurePolicy = "Fail"`이라 잘못
# 건드리면 namespace의 실험 Job이 **전부** 거부된다. 특히 Phase 1
# `branch-bootstrap` 계약은 launcher image digest를 되돌리는 롤백 경로가 그대로
# 통과해야 하므로 동등하게 보존되어야 한다(#562 설계 3.5).
#
# 좌표 변수는 카탈로그(config/environments/dev/environment.yaml)가 공급하며 각
# root의 variables.tf에는 default가 없다(#491). `terraform test`는 .auto.tfvars를
# 자동 로드하지 않으므로, 여기서 명시하지 않으면 전 run이 "No value for required
# variable"로 실패한다. 값은 카탈로그와 동일하게 유지한다.
variables {
  project_id            = "autoresearch-503903"
  region                = "asia-northeast3"
  zone                  = "asia-northeast3-a"
  gke_cluster_name      = "autoresearch-dev-gke"
  resource_prefix       = "autoresearch-dev"
  private_services_cidr = "192.168.0.0/20"
  cluster_services_cidr = "172.16.128.0/24"
}

mock_provider "google" {}
mock_provider "kubernetes" {}

override_data {
  target = data.kubernetes_service_v1.kube_dns
  values = {
    spec = [{
      cluster_ip = "172.16.128.10"
      type       = "ClusterIP"
    }]
  }
}

override_data {
  target = data.kubernetes_service_v1.autoresearch_serving
  values = {
    spec = [{
      cluster_ip = "172.16.128.20"
      type       = "ClusterIP"
    }]
  }
}

run "branch_bootstrap_contract_is_preserved" {
  command = plan

  assert {
    condition     = contains(keys(local.experiment_job_contracts), "branch-bootstrap")
    error_message = "branch-bootstrap 계약은 launcher digest 롤백 경로이므로 제거할 수 없다."
  }

  assert {
    condition     = local.experiment_job_contracts["branch-bootstrap"].init_containers == ["github-token-minter"]
    error_message = "branch-bootstrap의 initContainer 계약이 바뀌면 롤백된 launcher의 Job이 거부된다."
  }

  assert {
    condition     = local.experiment_job_contracts["branch-bootstrap"].app_containers == ["branch-bootstrap"]
    error_message = "branch-bootstrap의 app container 계약이 바뀌면 롤백된 launcher의 Job이 거부된다."
  }

  assert {
    condition = toset(local.experiment_job_contracts["branch-bootstrap"].volumes) == toset([
      "github-app-private-key",
      "github-token",
    ])
    error_message = "branch-bootstrap의 volume 집합은 Phase 1 launcher가 만드는 두 개 그대로여야 한다."
  }
}

run "private_key_rule_is_an_allowlist_not_a_requirement" {
  command = plan

  # "모든 initContainer가 private key를 mount해야 한다"는 형태는 initContainer가
  # minter 하나로 고정된 조건에서만 의도대로 동작한다. initContainer가 늘어나면
  # 같은 문장이 "그 새 컨테이너에도 개인키를 넣어야 한다"는 요구가 된다.
  # 규칙은 반드시 "지정된 컨테이너만 mount할 수 있다" 방향이어야 한다.
  assert {
    condition = alltrue([
      for validation in kubernetes_manifest.experiment_job_admission_policy.manifest.spec.validations :
      !strcontains(
        validation.expression,
        "initContainers.all(c, has(c.volumeMounts) && c.volumeMounts.exists_one(m, m.name == 'github-app-private-key'"
      )
    ])
    error_message = "private key 규칙이 '모든 initContainer가 mount' 형태로 남으면 컨테이너가 늘 때 개인키를 넣으라는 요구가 된다."
  }

  # 선언된 모든 자격 증명 volume에 대해 마운트 주체를 제한하는 규칙이 생성되어야
  # 한다. 하나라도 빠지면 그 volume은 아무 컨테이너나 mount할 수 있다.
  assert {
    condition = alltrue(flatten([
      for component, contract in local.experiment_job_contracts : [
        for volume in keys(contract.credential_mounts) :
        anytrue([
          for validation in kubernetes_manifest.experiment_job_admission_policy.manifest.spec.validations :
          strcontains(validation.expression, "m.name != '${volume}'") &&
          strcontains(validation.expression, "'${component}'")
        ])
      ]
    ]))
    error_message = "선언된 모든 자격 증명 volume에 마운트 주체 제한 규칙이 생성되어야 한다."
  }

  # private key는 허용된 컨테이너라도 readOnly로만 mount할 수 있어야 한다.
  assert {
    condition = anytrue([
      for validation in kubernetes_manifest.experiment_job_admission_policy.manifest.spec.validations :
      strcontains(validation.expression, "m.name != 'github-app-private-key' || (has(m.readOnly) && m.readOnly == true)")
    ])
    error_message = "private key는 readOnly mount만 허용해야 한다."
  }
}

run "executor_contract_separates_credentials_by_container" {
  command = plan

  # 8개 컨테이너가 한 Pod에 있어 NetworkPolicy로는 컨테이너별 목적지를 나눌 수
  # 없다(Pod 단위 적용, Calico라 FQDN 지정 불가). 따라서 codex-worker도 GitHub에
  # 네트워크로는 닿는다. 실질 경계는 자격 증명 분리 하나뿐이므로, 그 분리가
  # 계약에 남아 있는지를 여기서 잡는다.
  assert {
    condition = alltrue([
      for volume, holders in local.experiment_job_contracts["experiment-executor"].credential_mounts :
      !contains(concat(holders.readers, holders.writers), "codex-worker")
      if volume != "codex-home"
    ])
    error_message = "codex-worker는 Codex 인증(codex-home) 외 어떤 자격 증명도 mount할 수 없다."
  }

  assert {
    condition = alltrue([
      for volume, holders in local.experiment_job_contracts["experiment-executor"].credential_mounts :
      !contains(concat(holders.readers, holders.writers), "candidate-verifier")
    ])
    error_message = "candidate-verifier는 어떤 자격 증명도 mount할 수 없다."
  }

  # 역방향. Codex 인증이 GitHub을 만지는 컨테이너로 새는 경로도 닫아야 한다.
  assert {
    condition = local.experiment_job_contracts["experiment-executor"].credential_mounts["codex-home"] == {
      readers = ["codex-worker"]
      writers = []
    }
    error_message = "Codex 인증 Secret은 codex-worker만 읽기 전용으로 mount할 수 있어야 한다."
  }

  # private key는 token을 발급하는 세 컨테이너만 본다. 쓰기 주체는 없다.
  assert {
    condition = local.experiment_job_contracts["experiment-executor"].credential_mounts["github-app-private-key"] == {
      readers = ["branch-token-minter", "clone-token-minter", "push-token-minter"]
      writers = []
    }
    error_message = "private key는 token minter 3개만 읽기 전용으로 mount할 수 있어야 한다."
  }

  # 순서 고정. token 발급 컨테이너가 그 token을 쓰는 컨테이너 바로 앞에 와야 한다.
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
    error_message = "executor initContainer 구성·순서가 launcher/jobs.py의 build_executor_job과 달라지면 모든 Job이 거부된다."
  }

  assert {
    condition     = local.experiment_job_contracts["experiment-executor"].app_containers == ["candidate-finalizer"]
    error_message = "executor의 app container는 candidate-finalizer 하나여야 한다."
  }

  # 토큰은 용도별로 분리돼야 한다. 하나로 합치면 clone용 read 권한 토큰과
  # push용 write 권한 토큰이 같은 파일을 공유하게 된다.
  assert {
    condition = alltrue([
      for volume in ["branch-token", "clone-token", "push-token"] :
      contains(local.experiment_job_contracts["experiment-executor"].volumes, volume)
    ])
    error_message = "executor는 branch/clone/push token volume을 분리해 유지해야 한다."
  }
}

run "executor_egress_preserves_phase1_path" {
  command = plan

  # Phase 1 egress는 launcher digest 롤백 경로다. executor 정책을 추가하면서
  # 이 정책의 대상이 바뀌면 롤백된 Job이 GitHub에 닿지 못한다.
  assert {
    condition     = kubernetes_network_policy_v1.experiment_jobs_branch_bootstrap_egress.spec[0].pod_selector[0].match_labels["app.kubernetes.io/component"] == "branch-bootstrap"
    error_message = "Phase 1 egress 정책의 대상 label은 branch-bootstrap으로 유지해야 한다."
  }

  assert {
    condition     = kubernetes_network_policy_v1.experiment_executor_egress.spec[0].pod_selector[0].match_labels["app.kubernetes.io/component"] == "experiment-executor"
    error_message = "executor egress는 executor label에만 적용되어야 한다."
  }

  # in-cluster API 규칙은 namespace와 Pod를 한 to 블록에 함께 둬야 교집합이 된다.
  # 블록을 나누면 합집합이 되어 그 namespace의 모든 Pod로 열린다.
  assert {
    condition = alltrue([
      for rule in kubernetes_network_policy_v1.experiment_executor_egress.spec[0].egress :
      length(rule.to) == 1
    ])
    error_message = "egress 규칙마다 to 블록은 하나여야 한다 — 나누면 selector가 합집합으로 넓어진다."
  }

  # Cloud SQL 직접 연결은 열지 않는다. 보고 경로는 API 경유다.
  # (#599) MLflow tracking 포트를 세 번째 목적지로 추가했다. 학습 run을 남기는
  # 유일한 경로이며, 이 포트가 닫히면 학습이 timeout까지 매달린다.
  assert {
    condition = alltrue([
      for rule in kubernetes_network_policy_v1.experiment_executor_egress.spec[0].egress :
      alltrue([for port in rule.ports : contains([
        "443",
        local.experiment_executor_api_port,
        local.experiment_executor_mlflow_port,
      ], port.port)])
    ])
    error_message = "executor egress는 공개 443·in-cluster API·MLflow 포트 외의 목적지를 열지 않아야 한다."
  }

  # (#599) 반대 방향도 고정한다. 규칙이 사라지면 학습은 exit 0으로 성공한 채
  # run을 Pod 로컬 file store에 남기므로, 없어진 것이 조용히 드러나지 않는다.
  assert {
    condition = anytrue([
      for rule in kubernetes_network_policy_v1.experiment_executor_egress.spec[0].egress :
      alltrue([
        length(rule.to) == 1,
        try(rule.to[0].namespace_selector[0].match_labels["app.kubernetes.io/name"], "") == local.experiment_executor_mlflow_namespace,
        try(rule.to[0].pod_selector[0].match_labels["app.kubernetes.io/name"], "") == local.experiment_executor_mlflow_selector,
        alltrue([for port in rule.ports : port.port == local.experiment_executor_mlflow_port]),
      ])
    ])
    error_message = "executor egress는 mlflow namespace·Pod를 한 to 블록에 둔 MLflow 규칙을 유지해야 한다."
  }
}

run "active_deadline_allows_stage1_budget" {
  command = plan

  # (#604) launcher가 60000초를 Job에 복사하므로 admission이 3600초를 유지하면
  # Pod가 하나도 생성되지 않은 채 FailedCreate로 끝난다. rendered CEL에서 server-side
  # 상한이 실제 결정값과 같은지 확인한다. 완료 뒤 회수 상한(TTL 3600)은 별도다.
  assert {
    condition = anytrue([
      for validation in kubernetes_manifest.experiment_job_admission_policy.manifest.spec.validations :
      strcontains(validation.expression, "object.spec.activeDeadlineSeconds <= 60000")
    ])
    error_message = "Stage 1 executor는 activeDeadlineSeconds 60000초를 admission에서 허용해야 한다."
  }
}

run "policy_covers_every_declared_contract" {
  command = plan

  # 계약 map에 항목을 추가하고 정책 생성에 반영하지 않으면, 그 종류의 Job은
  # label 검사만 통과한 뒤 컨테이너·volume 제약 없이 들어온다. map과 렌더링된
  # 정책이 같은 종류 집합을 다루는지 확인한다.
  assert {
    condition = alltrue([
      for component in keys(local.experiment_job_contracts) :
      anytrue([
        for validation in kubernetes_manifest.experiment_job_admission_policy.manifest.spec.validations :
        strcontains(validation.expression, "'${component}'")
      ])
    ])
    error_message = "계약 map의 모든 종류가 렌더링된 정책 표현식에 나타나야 한다."
  }
}
