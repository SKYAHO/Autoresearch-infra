# 셀프 호스티드 러너(ARC)의 Kubernetes 경계는 GKE API 직접 접근이 필요해
# terraform/envs/dev와 분리한다(별도 state). #533 설계.
# ARC 컨트롤러/러너 chart 자체는 ArgoCD(deploy/actions-runner-controller,
# deploy/actions-runner-scale-set)가 배포하고, 이 root는 namespace/KSA/
# NetworkPolicy/quota(플랫폼 경계)만 소유한다.
#
# 이 namespace는 ARC가 관리하는 임시 러너 Pod 템플릿을 이 root가 직접
# 통제하지 못하므로, 검증 전에는 restricted가 아닌 baseline PSA를 쓴다
# (experiment_jobs.tf의 restricted와 의도적으로 다름 — feast apply 이관 등
# 후속 단계에서 실제 Pod spec을 관찰한 뒤 강화 여부를 재검토한다).
resource "kubernetes_namespace_v1" "actions_runner" {
  metadata {
    name = var.actions_runner_namespace
    labels = {
      "app.kubernetes.io/name"             = "actions-runner-controller"
      "app.kubernetes.io/part-of"          = "auto-research"
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
    }
  }
}

# ARC 컨트롤러 매니저는 자신의 CRD(AutoscalingRunnerSet 등, cluster-scoped)를
# watch하고 러너 Pod/Secret/RoleBinding을 생성해야 하므로 Kubernetes API
# token 마운트가 실제로 필요하다 — 이 root의 "automount=false 기본" 원칙에
# 대한 의도적 예외(Kubernetes 기본값 유지).
resource "kubernetes_service_account_v1" "actions_runner_controller" {
  metadata {
    name      = var.actions_runner_controller_ksa
    namespace = kubernetes_namespace_v1.actions_runner.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = local.actions_runner_controller_gcp_service_account_email
    }
  }
}

# ephemeral runner Pod 전용 신원(scale-set chart의 template.spec에만 연결,
# variables.tf 주석 참고). AutoscalingListener Pod는 chart가 자체 생성하는
# 별도 SA를 쓰므로 이 automount=false는 listener Pod의 K8s API 접근에는
# 영향을 주지 않는다 — 표준 관례대로 automount만 끈다.
resource "kubernetes_service_account_v1" "actions_runner_runner" {
  metadata {
    name      = var.actions_runner_runner_ksa
    namespace = kubernetes_namespace_v1.actions_runner.metadata[0].name
  }

  automount_service_account_token = false
}

# 러너 Pod는 checkout·build tooling으로 experiment Job보다 무거우므로 여유를
# 둔다. scale-set chart의 maxRunners와 짝(pair)을 이루되, 컨트롤러/리스너
# 상주 Pod 2개 몫(locals.actions_runner_control_plane_pods)을 더한다(#533
# 리뷰) — 값 변경 시 maxRunners와 actions_runner_max_pods를 함께 바꾼다.
# cpu/memory hard 값은 LimitRange의 컨테이너 기본 request/limit(500m/1Gi,
# 1cpu/2Gi)에 quota_pods를 곱한 값이다 — quota_pods개째 Pod까지는 기본값으로
# 스케줄되고, 그 이상은 초과 Pod가 Pending("exceeded quota" 이벤트)에 머물러
# workflow가 job 대기(queued)로 관측된다(즉시 실패가 아님).
resource "kubernetes_resource_quota_v1" "actions_runner" {
  metadata {
    name      = "actions-runner-quota"
    namespace = kubernetes_namespace_v1.actions_runner.metadata[0].name
  }

  spec {
    hard = {
      "pods"            = tostring(local.actions_runner_quota_pods)
      "requests.cpu"    = "${local.actions_runner_quota_pods * 0.5}"
      "requests.memory" = "${local.actions_runner_quota_pods}Gi"
      "limits.cpu"      = tostring(local.actions_runner_quota_pods)
      "limits.memory"   = "${local.actions_runner_quota_pods * 2}Gi"
    }
  }

  depends_on = [kubernetes_namespace_v1.actions_runner]
}

resource "kubernetes_limit_range_v1" "actions_runner" {
  metadata {
    name      = "actions-runner-limits"
    namespace = kubernetes_namespace_v1.actions_runner.metadata[0].name
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "1"
        memory = "2Gi"
      }
      default_request = {
        cpu    = "500m"
        memory = "1Gi"
      }
      max = {
        cpu    = "2"
        memory = "4Gi"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.actions_runner]
}

# 이 namespace에는 inbound traffic이 필요 없다(GitHub이 러너로 접속하지 않고,
# 러너가 GitHub의 Actions 서비스로 outbound polling한다).
resource "kubernetes_network_policy_v1" "actions_runner_ingress" {
  metadata {
    name      = "actions-runner-ingress"
    namespace = kubernetes_namespace_v1.actions_runner.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

# 기본 egress를 차단하고 experiment_jobs.tf 4규칙(DNS, GKE metadata, WI
# metadata, PGA)을 재사용한 뒤, 이 namespace 전용 규칙을 더한다:
# - cluster_services_cidr:443 + cluster_master_cidr:443 — PoC 워크플로우의
#   K8s API 서버(kubernetes.default.svc) 접근 검증용. kube-proxy/Dataplane V2가
#   서비스 VIP를 control plane(master) 주소로 post-DNAT하므로 두 CIDR 모두
#   필요하다(#138 패턴, argo-rollouts-k8s/elastic-k8s와 동일). GitHub-hosted
#   러너에서는 도달 불가능해 VPC 내부망 접근의 증명이 된다.
# - 0.0.0.0/0:443(RFC1918 3종 except) — GitHub Actions 서비스(러너 등록·job
#   polling)는 IP 대역이 넓고 자주 바뀌어 고정 CIDR allowlist 관례를 적용할
#   수 없다. except로 사내 사설 대역을 빼지 않으면 이 규칙이 위 K8s API
#   규칙까지 무의미하게 덮어써, Task 7의 "K8s API egress 규칙만 제거 → timeout"
#   음성 대조군이 성립하지 않는다(#533 리뷰). GitHub IP allowlist로 더 좁히는
#   강화는 범위 밖(#533 설계 문서 참고).
resource "kubernetes_network_policy_v1" "actions_runner_egress" {
  metadata {
    name      = "actions-runner-egress"
    namespace = kubernetes_namespace_v1.actions_runner.metadata[0].name
  }

  spec {
    # namespace 전체(컨트롤러 매니저 + 3개 스케일셋의 리스너·러너 Pod 전부)에
    # 적용되는 공용 최소 baseline이다. NetworkPolicy는 겹치는 selector끼리
    # union으로 합쳐지므로, 이 baseline이 DNS/PGA/GitHub만 허용해 두면
    # 리스너 전용 K8s API 규칙(아래 actions_runner_listener_k8s_api_egress)과
    # feast-apply-prod 전용 Redis 규칙(feast_apply_prod_runner_egress)을 각각
    # 스케일셋 라벨로 스코프한 별도 정책으로 "추가"할 수 있다 — pod_selector를
    # 좁혀 컨트롤러/리스너 Pod를 어떤 정책에서도 빠뜨리면 그 Pod는 egress
    # 무제한이 된다(#541 리뷰 — 이전에 좁혔다가 되돌림).
    pod_selector {}
    policy_types = ["Egress"]

    # 같은 namespace 내 통신(컨트롤러 ↔ 러너).
    egress {
      to {
        pod_selector {}
      }
    }

    egress {
      to {
        ip_block {
          cidr = var.cluster_services_cidr
        }
      }

      ports {
        protocol = "UDP"
        port     = "53"
      }

      ports {
        protocol = "TCP"
        port     = "53"
      }
    }

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }

        pod_selector {
          match_labels = {
            "k8s-app" = "kube-dns"
          }
        }
      }

      ports {
        protocol = "UDP"
        port     = "53"
      }

      ports {
        protocol = "TCP"
        port     = "53"
      }
    }

    egress {
      to {
        ip_block {
          cidr = "169.254.169.254/32"
        }
      }

      ports {
        protocol = "TCP"
        port     = "80"
      }
    }

    egress {
      to {
        ip_block {
          cidr = "169.254.169.252/32"
        }
      }

      ports {
        protocol = "TCP"
        port     = "987"
      }

      ports {
        protocol = "TCP"
        port     = "988"
      }
    }

    egress {
      to {
        ip_block {
          cidr = var.private_googleapis_cidr
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }

    # GitHub Actions 서비스 연결(러너 등록/job polling). 사설 대역(RFC1918)은
    # except로 빼서 아래 PoC 전용 K8s API 규칙과 겹치지 않게 한다 — 겹치면 그
    # 규칙을 제거해도 이 규칙이 대신 통과시켜 Task 7 음성 대조군이 무효화된다.
    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
          except = [
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
          ]
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.actions_runner]
}

# 리스너(AutoscalingListener) Pod 전용 supplemental 규칙: K8s API 서버
# (in-cluster, 서비스 VIP 경유) 접근. baseline(actions_runner_egress)에서
# 분리해 K8s API egress를 리스너에만 준다.
#
# #557에서 pod_selector를 scale-set-name=actions-runner-poc에서
# app.kubernetes.io/component=runner-scale-set-listener로 바꿨다 — 원래
# selector는 "feast-apply 러너는 kubectl/K8s API를 호출하지 않는다"는
# 근거로 PoC 스케일셋에만 K8s API egress를 줬는데, 이는 ephemeral runner
# Pod(= `feast apply`가 실제로 실행되는 곳)에는 맞지만 리스너 Pod에는
# 틀렸다 — 리스너는 스케일셋 종류와 무관하게 ARC 아키텍처상 매 폴링
# 사이클마다 `EphemeralRunnerSet`을 patch하기 위해 apiserver 접근이
# 필수다. 리스너 Pod와 ephemeral runner Pod는 둘 다 동일한
# `actions.github.com/scale-set-name` 라벨을 공유하므로(#541 리뷰 근거,
# upstream ADR `docs/adrs/2023-03-14-adding-labels-k8s-resources.md`)
# scale-set-name 기준 scoping은 feast-apply-dev/prod 리스너를 의도치
# 않게 배제해 K8s API patch가 타임아웃되고 리스너가 crash-loop했다
# (라이브 확인, 2026-08-06). `app.kubernetes.io/component=
# runner-scale-set-listener`는 리스너 Pod 전부에 동일하게 붙고 ephemeral
# runner Pod에는 없어(ARC가 Pod 종류별로 다른 component 값을 부여),
# "리스너만 apiserver 접근, ephemeral runner는 차단"이라는 최소 권한
# 의도를 스케일셋 3종 전부에 균일하게 유지한다.
resource "kubernetes_network_policy_v1" "actions_runner_listener_k8s_api_egress" {
  metadata {
    name      = "actions-runner-listener-k8s-api-egress"
    namespace = kubernetes_namespace_v1.actions_runner.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/component" = "runner-scale-set-listener"
      }
    }
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = var.cluster_services_cidr
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }

    # K8s API post-DNAT 목적지(master) 대비 (#138 패턴).
    egress {
      to {
        ip_block {
          cidr = var.cluster_master_cidr
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.actions_runner]
}

# #541 5단계: feast apply 전용 러너 KSA 2개. 새 GSA는 만들지 않고 #424의
# feast_apply_{dev,prod} GSA를 그대로 재사용한다(locals.tf 참고).
resource "kubernetes_service_account_v1" "feast_apply_runner" {
  for_each = local.feast_apply_runner_identities

  metadata {
    name      = each.value.ksa_name
    namespace = kubernetes_namespace_v1.actions_runner.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = each.value.gcp_service_account_email
    }
  }

  automount_service_account_token = false
}

# feast-apply-prod 스케일셋 전용 supplemental 규칙: Redis Cluster PSC만
# 추가한다. DNS/PGA/GitHub-443은 baseline(actions_runner_egress, pod_selector
# {}) 이 이미 namespace 전체(feast-apply-dev/prod 포함)에 적용하므로 여기서
# 다시 선언하지 않는다 — NetworkPolicy는 겹치는 selector끼리 union이라
# 중복 선언은 불필요하다. dev는 baseline만으로 충분해 별도 리소스가 없다
# (음성 대조군: dev 러너는 Redis PSC 규칙이 없으므로 접근 시도가 baseline의
# 어떤 allow 규칙에도 안 걸려 차단된다).
#
# pod_selector 근거(#541 리뷰 이해도 확인): actions.github.com/scale-set-name
# 라벨은 Helm values가 아니라 ARC 컨트롤러가 Pod 생성 시점에 주입하며,
# 리스너 Pod뿐 아니라 ephemeral runner Pod에도 동일하게 붙는다 — upstream
# actions/actions-runner-controller의
# docs/adrs/2023-03-14-adding-labels-k8s-resources.md가 Listener/Runner 두
# Pod spec 모두에 이 라벨을 "set by controller at creation"으로 명시한다.
# 값은 AutoscalingRunnerSet.metadata.name(= Helm의 runnerScaleSetName, 이
# 저장소에서는 deploy/actions-runner-scale-set-feast-{dev,prod}/values.yaml의
# runnerScaleSetName)에서 온다 — Helm release 이름이 아니다. 라이브 클러스터의
# PoC 리스너 Pod(actions-runner-poc-*-listener)가 이미
# actions.github.com/scale-set-name=actions-runner-poc 라벨을 달고 있어(값이
# PoC values.yaml의 runnerScaleSetName과 일치) 이 주입 메커니즘을 간접
# 확인했다. 이 selector가 실제로 0개를 고르는 경우(라벨이 전혀 안 붙는
# 회귀)라면 actions-runner-poc는 K8s API egress가 막혀 job이 API 호출에서
# 타임아웃하고, feast-apply-prod는 Redis PSC egress가 막혀(baseline도
# 없으므로) GCS는 되지만 Redis만 실패한다 — 둘 다 각 워크플로우 실행
# 시점에 바로 드러난다(무한 대기가 아니라 명시적 실패).
resource "kubernetes_network_policy_v1" "feast_apply_prod_runner_egress" {
  metadata {
    name      = "feast-apply-prod-runner-egress"
    namespace = kubernetes_namespace_v1.actions_runner.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "actions.github.com/scale-set-name" = local.feast_apply_runner_identities.prod.scale_set_name
      }
    }
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = var.redis_psc_subnet_cidr
        }
      }

      ports {
        protocol = "TCP"
        port     = tostring(var.redis_discovery_port)
      }

      ports {
        protocol = "TCP"
        port     = tostring(var.redis_node_port_start)
        end_port = var.redis_node_port_end
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.actions_runner]
}
