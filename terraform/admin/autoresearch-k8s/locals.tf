locals {
  app_gcp_service_account_email = var.app_gcp_service_account_email != "" ? var.app_gcp_service_account_email : "${var.resource_prefix}-app@${var.project_id}.iam.gserviceaccount.com"

  # dev root의 짧은 GSA account_id(orch-api/orch-runner)와 같은 값을 기본으로
  # 파생한다. GSA local part와 KSA 이름은 서로 다르므로 혼동하지 않는다.
  agent_orchestration_api_gcp_service_account_email    = var.agent_orchestration_api_gcp_service_account_email != "" ? var.agent_orchestration_api_gcp_service_account_email : "${var.resource_prefix}-orch-api@${var.project_id}.iam.gserviceaccount.com"
  agent_orchestration_runner_gcp_service_account_email = var.agent_orchestration_runner_gcp_service_account_email != "" ? var.agent_orchestration_runner_gcp_service_account_email : "${var.resource_prefix}-orch-runner@${var.project_id}.iam.gserviceaccount.com"

  # #539 launcher GSA. dev root local의 `-orch-launch`와 같은 규칙으로 파생한다 —
  # account_id 30자 제한 때문에 `-orch-launcher`가 아니라 `-orch-launch`(28자)다.
  agent_orchestration_launcher_gcp_service_account_email = var.agent_orchestration_launcher_gcp_service_account_email != "" ? var.agent_orchestration_launcher_gcp_service_account_email : "${var.resource_prefix}-orch-launch@${var.project_id}.iam.gserviceaccount.com"

  # dev root의 experiment_runtime_contract와 같은 기본값을 사용한다. override는
  # 두 root output을 대조할 때만 사용한다.
  experiment_runtime_gcp_service_account_email = var.experiment_runtime_gcp_service_account_email != "" ? var.experiment_runtime_gcp_service_account_email : "${var.resource_prefix}-exp-runtime@${var.project_id}.iam.gserviceaccount.com"

  # #424 Task 2의 Workload Identity subject와 정확히 같은 namespace/KSA 기본값을
  # 사용한다. annotation과 RoleBinding은 반드시 같은 환경의 GSA만 참조한다.
  # GSA local part는 dev root의 feast_apply_{dev,prod}_sa_name과 같아야 한다.
  # 30자 account_id 제한 때문에 namespace(`feast-apply-dev`)와 달리 GSA는
  # `-feast-dev`/`-feast-prod`로 줄어 있으므로 두 이름을 혼동하면 안 된다.
  feast_apply_default_identities = {
    dev = {
      namespace                 = "feast-apply-dev"
      service_account           = "feast-apply"
      gcp_service_account_email = "${var.resource_prefix}-feast-dev@${var.project_id}.iam.gserviceaccount.com"
    }
    prod = {
      namespace                 = "feast-apply-prod"
      service_account           = "feast-apply"
      gcp_service_account_email = "${var.resource_prefix}-feast-prod@${var.project_id}.iam.gserviceaccount.com"
    }
  }

  feast_apply_identities = var.feast_apply_identities == null ? local.feast_apply_default_identities : var.feast_apply_identities

  # admin root는 dev root Terraform state를 직접 읽지 않는다. GSA의 account id는
  # dev root local과 같은 짧은 `-exp-job` 규칙으로 파생하며, 예외만 변수로 override한다.
  experiment_job_gcp_service_account_email = var.experiment_job_gcp_service_account_email != "" ? var.experiment_job_gcp_service_account_email : "${var.resource_prefix}-exp-job@${var.project_id}.iam.gserviceaccount.com"

  # #539 branch-bootstrap Job의 고정 컨테이너·volume 이름. 이 값들은 애플리케이션
  # 저장소 `agent_orchestration/launcher/jobs.py`의 상수와 정확히 같아야 한다 —
  # 불일치하면 launcher가 만드는 모든 Job이 admission에서 거부된다. 이름을 서버 측에
  # 고정하는 이유는 private key를 마운트하는 컨테이너를 "순서"가 아니라 "정체"로
  # 식별하기 위해서다.
  experiment_branch_bootstrap_init_container = "github-token-minter"
  experiment_branch_bootstrap_app_container  = "branch-bootstrap"
  experiment_branch_writer_key_volume        = "github-app-private-key"
  experiment_branch_token_volume             = "github-token"

  # 같은 파일의 `app.kubernetes.io/component` label 값이다. NetworkPolicy가 이
  # label로 GitHub egress 대상 Pod를 고른다. 컨테이너 이름과 문자열이 같지만 의미가
  # 다르므로 별도 local로 둔다.
  experiment_branch_bootstrap_component_label = "branch-bootstrap"

  # (#562) Job 종류별 어드미션 계약. key는 Pod template의
  # `app.kubernetes.io/component` label 값이다. 이 map에 없는 종류는 정책이
  # 거부하므로, 새 Job 종류를 도입하는 변경은 여기 항목을 먼저 추가한다.
  #
  # 계약을 map에서 생성하는 이유는 이 namespace가 Phase 1 `branch-bootstrap`
  # 한 종류만 통과시키도록 이름을 하드코딩하고 있었고, Phase 2 executor처럼
  # 형태가 다른 Job이 필요해질 때마다 정책 전체를 다시 쓰게 되기 때문이다.
  #
  # `credential_mounts`는 "이 volume을 mount할 수 있는 컨테이너 이름"이다.
  # 목록에 없는 컨테이너는 init/app 구분 없이 mount가 거부된다. 이 방향이
  # 중요하다 — "모든 initContainer가 키를 mount해야 한다"는 형태로 쓰면
  # initContainer가 늘어나는 순간 그 새 컨테이너에도 키를 넣으라는 요구가 된다.
  experiment_job_contracts = {
    (local.experiment_branch_bootstrap_component_label) = {
      init_containers = [local.experiment_branch_bootstrap_init_container]
      app_containers  = [local.experiment_branch_bootstrap_app_container]
      volumes = [
        local.experiment_branch_writer_key_volume,
        local.experiment_branch_token_volume,
      ]
      credential_mounts = {
        (local.experiment_branch_writer_key_volume) = [
          local.experiment_branch_bootstrap_init_container,
        ]
        (local.experiment_branch_token_volume) = [
          local.experiment_branch_bootstrap_init_container,
          local.experiment_branch_bootstrap_app_container,
        ]
      }
    }
  }

  # 공개 인터넷 443을 열되 사설·링크로컬·loopback 대역을 제외한다. RFC1918(10/8,
  # 172.16/12, 192.168/16), RFC6598 CGNAT(100.64/10), link-local(169.254/16),
  # loopback(127/8) 기준이라 dev CIDR 변수가 바뀌어도 함께 고칠 필요가 없다.
  # `deploy/agent-orchestration/network-policy.yaml`의 API egress(#525)와 같은 목록이다.
  public_egress_private_cidr_exceptions = [
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "100.64.0.0/10",
    "169.254.0.0/16",
    "127.0.0.0/8",
  ]

  # 기본 허용 prefix는 이 프로젝트의 Artifact Registry Docker 저장소다
  # (예: asia-northeast3-docker.pkg.dev/<project>/autoresearch-dev-docker/).
  experiment_job_allowed_image_prefixes = coalesce(
    var.experiment_job_allowed_image_prefixes,
    ["${var.region}-docker.pkg.dev/${var.project_id}/${var.resource_prefix}-docker/"],
  )
}
