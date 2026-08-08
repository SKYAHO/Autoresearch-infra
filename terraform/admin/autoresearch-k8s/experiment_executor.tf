# (#562) Phase 2 experiment-executor Pod 전용 egress 경계.
#
# 이 파일은 Phase 2에서만 쓰는 경계를 담는다. Phase 1 `branch-bootstrap` 경로는
# `experiment_jobs.tf`가 그대로 소유하며 이 파일은 손대지 않는다 — launcher image
# digest를 되돌리는 롤백이 그 경로로 돌아가야 하기 때문이다.
#
# 이 namespace가 쓰는 Kubernetes Secret은 Terraform이 만들지 않는다. 값이 state에
# 남기 때문이며, 기존 `github-app-private-key` Secret과 같은 판단이다. 등록 절차는
# `docs/runbooks/2026-08-01-auto-research-experiment-job.md`에 있고, 이 root는
# 이름만(`var.experiment_codex_home_secret_name`,
# `var.experiment_executor_api_token_secret_name`) 계약으로 고정한다.

# executor Pod는 기본 경계(DNS, Workload Identity metadata, Private Google Access)
# 위에 세 목적지를 더 필요로 한다. NetworkPolicy는 선택된 Pod에 대해 각 정책의
# 허용 규칙을 합집합으로 적용하므로, 이 정책은 `experiment_jobs_egress`가 세운
# 기본 경계를 되돌리지 않고 추가만 한다.
#
# 규칙 1 — 공개 443. GitHub(token 발급·clone·push)과 OpenAI(Codex)가 모두 여기에
# 해당한다. 이 클러스터의 dataplane은 Calico라 GKE Dataplane V2의
# `FQDNNetworkPolicy`를 쓸 수 없어 `api.github.com`만 지정하는 방법이 없고,
# GitHub이 게시하는 API 대역은 수시로 교체돼 고정하면 예고 없이 깨진다. 같은
# 판단이 이미 branch-bootstrap egress(#539)와 API Pod(#525)에 적용돼 있다.
#
# **컨테이너별 분리는 불가능하다.** NetworkPolicy는 Pod 단위인데 executor는 8개
# 컨테이너가 한 Pod에 있다. 따라서 `codex-worker`도 GitHub에, token minter도
# OpenAI에 네트워크로는 도달한다. 이를 막을 수단은 없다. 실질 경계는
# `locals.tf`의 `credential_mounts`가 만드는 자격 증명 분리 하나뿐이며,
# `codex-worker`는 GitHub에 닿아도 쓸 토큰이 없다. 이 정책이 넓다는 이유로 그
# 자격 증명 규칙을 완화하지 않는다.
#
# 규칙 2 — in-cluster Experiment API. `candidate-finalizer`가 candidate SHA를
# 보고할 목적지다. 기본 경계가 사설 대역을 `except`로 막고 있어 별도로 열어야
# 한다. namespace와 Pod를 한 `to` 블록에 함께 두어 교집합으로 좁힌다(블록을
# 나누면 합집합이 되어 "그 namespace의 모든 Pod"까지 열린다). Cloud SQL은 계속
# 닫아 둔다 — 보고 경로가 API 경유이므로 DB 직접 연결이 필요 없다.
#
# 규칙 3 — in-cluster MLflow tracking server. `workspace-preparer`(baseline)와
# `candidate-finalizer`(candidate)가 도는 `src.cli train-model`이 run을 기록할
# 목적지다. 규칙 2와 같은 이유로 사설 대역 `except`에 걸려 별도로 열어야 하고,
# 같은 이유로 두 selector를 한 `to` 블록에 둔다.
#
# **이 규칙만으로는 부족하다.** executor Pod에 `MLFLOW_TRACKING_URI`가 실제로
# 주입되어야 하며 그 전달은 애플리케이션 저장소 `launcher/jobs.py`가 한다
# (`_training_environment()`). 그 변경 없이 이 규칙만 넣으면 경로만 열리고
# 학습은 계속 Pod 로컬 file store에 기록된다.
resource "kubernetes_network_policy_v1" "experiment_executor_egress" {
  metadata {
    name      = "experiment-jobs-executor-egress"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  spec {
    # 이 label은 애플리케이션 저장소 `launcher/jobs.py`가 Job과 Pod template 양쪽에
    # 붙인다. label이 없는 Pod는 이 정책의 대상이 아니라 GitHub에 도달하지 못하고
    # 실패한다(fail-closed). 어드미션 계약이 같은 label을 검사하므로, 불일치는
    # timeout이 아니라 제출 시점의 명확한 거부로 드러난다.
    pod_selector {
      match_labels = {
        "app.kubernetes.io/component" = local.experiment_executor_component_label
      }
    }

    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr   = "0.0.0.0/0"
          except = local.public_egress_private_cidr_exceptions
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }

    egress {
      to {
        namespace_selector {
          match_labels = {
            "app.kubernetes.io/name" = kubernetes_namespace_v1.autoresearch.metadata[0].labels["app.kubernetes.io/name"]
          }
        }

        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = local.experiment_executor_api_service_selector
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = local.experiment_executor_api_port
      }
    }

    egress {
      to {
        namespace_selector {
          match_labels = {
            "app.kubernetes.io/name" = local.experiment_executor_mlflow_namespace
          }
        }

        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = local.experiment_executor_mlflow_selector
          }
        }
      }

      ports {
        protocol = "TCP"
        port     = local.experiment_executor_mlflow_port
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.experiment_jobs]
}
