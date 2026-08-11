locals {
  app_gcp_service_account_email = var.app_gcp_service_account_email != "" ? var.app_gcp_service_account_email : "${var.resource_prefix}-app@${var.project_id}.iam.gserviceaccount.com"

  # dev root의 짧은 GSA account_id(orch-api/orch-runner)와 같은 값을 기본으로
  # 파생한다. GSA local part와 KSA 이름은 서로 다르므로 혼동하지 않는다.
  agent_orchestration_api_gcp_service_account_email    = var.agent_orchestration_api_gcp_service_account_email != "" ? var.agent_orchestration_api_gcp_service_account_email : "${var.resource_prefix}-orch-api@${var.project_id}.iam.gserviceaccount.com"
  agent_orchestration_runner_gcp_service_account_email = var.agent_orchestration_runner_gcp_service_account_email != "" ? var.agent_orchestration_runner_gcp_service_account_email : "${var.resource_prefix}-orch-runner@${var.project_id}.iam.gserviceaccount.com"

  # #539 launcher GSA. dev root local의 `-orch-launch`와 같은 규칙으로 파생한다 —
  # account_id 30자 제한 때문에 `-orch-launcher`가 아니라 `-orch-launch`(28자)다.
  agent_orchestration_launcher_gcp_service_account_email = var.agent_orchestration_launcher_gcp_service_account_email != "" ? var.agent_orchestration_launcher_gcp_service_account_email : "${var.resource_prefix}-orch-launch@${var.project_id}.iam.gserviceaccount.com"

  # #616 실험 로그 수집기 GSA. dev root local의 `-orch-logcol`과 같은 규칙으로
  # 파생한다 — account_id 30자 제한 때문에 `-orch-log-collector`가 아니다.
  agent_orchestration_log_collector_gcp_service_account_email = var.agent_orchestration_log_collector_gcp_service_account_email != "" ? var.agent_orchestration_log_collector_gcp_service_account_email : "${var.resource_prefix}-orch-logcol@${var.project_id}.iam.gserviceaccount.com"

  # #630 실험 PR 생성기 GSA. dev root local의 `-orch-pr`과 같은 규칙으로 파생한다.
  agent_orchestration_pull_request_gcp_service_account_email = var.agent_orchestration_pull_request_gcp_service_account_email != "" ? var.agent_orchestration_pull_request_gcp_service_account_email : "${var.resource_prefix}-orch-pr@${var.project_id}.iam.gserviceaccount.com"

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

  # (#562) Phase 2 executor의 같은 label 값. `launcher/jobs.py`의
  # `EXPERIMENT_EXECUTOR_LABEL_SELECTOR`와 같아야 한다 — launcher가 동시 실행
  # 계수에도 이 selector를 쓰므로, 불일치하면 Job이 자기 계수에서 빠진다.
  experiment_executor_component_label = "experiment-executor"

  # candidate-finalizer가 candidate SHA를 보고할 in-cluster Experiment API 좌표.
  # `deploy/agent-orchestration/api-service.yaml`의 Service selector·port와 같아야
  # 한다 — 불일치하면 finalizer가 보고하지 못해 Job이 deadline까지 매달린다.
  experiment_executor_api_service_selector = "agent-orchestration-api"
  experiment_executor_api_port             = "8000"

  # 학습이 MLflow run을 기록할 in-cluster tracking server 좌표. `mlflow-k8s` root가
  # 소유한 Service이고, `deploy/serving/deployment.yaml`의 `MLFLOW_TRACKING_URI`가
  # 가리키는 것과 같은 좌표다. namespace와 Pod가 같은 label 값을 쓴다.
  # 이 좌표가 열려 있지 않으면 학습은 Pod 로컬 file store로 떨어지고, run이 Pod과
  # 함께 사라져 paired 비교가 artifact를 내려받을 대상을 잃는다.
  experiment_executor_mlflow_namespace = "mlflow"
  experiment_executor_mlflow_selector  = "mlflow"
  experiment_executor_mlflow_port      = "5000"

  # (#562) Job 종류별 어드미션 계약. key는 Pod template의
  # `app.kubernetes.io/component` label 값이다. 이 map에 없는 종류는 정책이
  # 거부하므로, 새 Job 종류를 도입하는 변경은 여기 항목을 먼저 추가한다.
  #
  # 계약을 map에서 생성하는 이유는 이 namespace가 Phase 1 `branch-bootstrap`
  # 한 종류만 통과시키도록 이름을 하드코딩하고 있었고, Phase 2 executor처럼
  # 형태가 다른 Job이 필요해질 때마다 정책 전체를 다시 쓰게 되기 때문이다.
  #
  # `credential_mounts`는 "이 volume을 mount할 수 있는 컨테이너"를 `readers`(읽기
  # 전용)와 `writers`(쓰기 허용)로 나눠 선언한다. 목록에 없는 컨테이너는 init/app
  # 구분 없이 mount가 거부되고, `readers`는 `readOnly: true`가 아니면 거부된다.
  #
  # 이 방향이 중요하다 — "모든 initContainer가 키를 mount해야 한다"는 형태로 쓰면
  # initContainer가 늘어나는 순간 그 새 컨테이너에도 키를 넣으라는 요구가 된다.
  # 그 문장은 initContainer가 minter 하나로 고정돼 있을 때만 의도대로 동작했다.
  #
  # `writers`를 따로 두는 이유는 token volume 때문이다. token을 발급하는
  # 컨테이너는 그 volume에 써야 하고, 소비하는 컨테이너는 읽기만 해야 한다.
  # 소비자가 쓰기로 mount하면 자기 token 파일을 덮어써 발급 경로를 우회할 수 있고
  # 사후 조사에서 어떤 token이 쓰였는지도 확정할 수 없다.
  experiment_job_contracts = {
    (local.experiment_branch_bootstrap_component_label) = {
      init_containers = [local.experiment_branch_bootstrap_init_container]
      app_containers  = [local.experiment_branch_bootstrap_app_container]
      volumes = [
        local.experiment_branch_writer_key_volume,
        local.experiment_branch_token_volume,
      ]
      credential_mounts = {
        (local.experiment_branch_writer_key_volume) = {
          readers = [local.experiment_branch_bootstrap_init_container]
          writers = []
        }
        (local.experiment_branch_token_volume) = {
          readers = [local.experiment_branch_bootstrap_app_container]
          writers = [local.experiment_branch_bootstrap_init_container]
        }
      }
    }

    # (#562) Phase 2 executor. 값의 정본은 애플리케이션 저장소
    # `agent_orchestration/launcher/jobs.py`의 `build_executor_job()`이며
    # source SHA 8750bce(v0.12.0) 기준이다. 불일치하면 launcher가 만드는 모든 Job이
    # admission에서 거부된다.
    (local.experiment_executor_component_label) = {
      # 순서까지 계약이다. token을 발급하는 컨테이너가 그 token을 쓰는 컨테이너
      # 바로 앞에 와야 만료 창이 최소가 되고, 순서가 바뀌면 빈 token 파일을 읽는다.
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
      # 이 표의 결과로 `codex-worker`는 Codex 인증 외 어떤 자격 증명도 갖지 못하고
      # `candidate-verifier`는 아무것도 갖지 못한다. 8개 컨테이너가 한 Pod에 있어
      # NetworkPolicy로는 컨테이너별 목적지를 나눌 수 없으므로(Pod 단위 적용,
      # Calico라 FQDN 지정 불가) codex-worker도 GitHub에 네트워크로는 닿는다.
      # 실질 경계는 이 자격 증명 분리 하나뿐이다 — "네트워크로 막혀 있다"는
      # 전제로 이 표를 완화하지 않는다.
      #
      # 토큰을 용도별로 셋으로 나눈 것도 계약이다. 하나로 합치면 clone용 read
      # 권한 토큰과 push용 write 권한 토큰이 같은 파일을 공유하게 된다.
      #
      # (#611) v0.12.0에서 `candidate-finalizer`가 `codex-home`을 추가로 읽는다.
      # 리포트를 쓰는 Codex #2가 그 컨테이너에서 돌기 때문이다 — 채점 결과가
      # 나오는 시점이 거기이고, `report.md`는 git 커밋 대상이 아니라 GCS 게시
      # 산출물이라 push 뒤에 와도 된다.
      #
      # 이것은 원래 설계의 역방향 경계를 하나 무르는 변경이다. 이전 계약은
      # "Codex 인증은 GitHub을 만지는 컨테이너에 닿지 않는다"였는데, 이제
      # push token·내부 API token과 Codex 인증이 같은 컨테이너에 함께 있다.
      # Codex sandbox가 `danger-full-access`라 그 안에서 토큰 파일을 읽는 것을
      # 코드로 막지 않으며, 금지는 애플리케이션 측 하네스 지침이 담당한다.
      # 감수하는 위험은 "리포트 생성 실패 시 Codex #2가 push token을 볼 수
      # 있다"이고, 이를 없애는 방법은 계약 완화가 아니라 컨테이너 분리다
      # (애플리케이션 Stage 2의 8 → 4/5 재구성). 그 전까지는 이 표가 그
      # 예외를 명시적으로 기록한다 — codex-worker 쪽 경계는 그대로 유지한다.
      credential_mounts = {
        (local.experiment_branch_writer_key_volume) = {
          readers = ["branch-token-minter", "clone-token-minter", "push-token-minter"]
          writers = []
        }
        "branch-token" = {
          readers = ["branch-creator"]
          writers = ["branch-token-minter"]
        }
        "clone-token" = {
          readers = ["workspace-preparer"]
          writers = ["clone-token-minter"]
        }
        "push-token" = {
          readers = ["candidate-finalizer"]
          writers = ["push-token-minter"]
        }
        "executor-api-token" = {
          readers = ["candidate-finalizer"]
          writers = []
        }
        "codex-home" = {
          readers = ["codex-worker", "candidate-finalizer"]
          writers = []
        }
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
