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
