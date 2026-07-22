# ArgoCD Kubernetes boundary is separated from terraform/envs/dev because
# Kubernetes API access and future Helm lifecycle are operator-controlled actions.

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = var.argocd_namespace

    labels = {
      "app.kubernetes.io/name"           = "argocd"
      "app.kubernetes.io/part-of"        = "gitops"
      "pod-security.kubernetes.io/audit" = "baseline"
      "pod-security.kubernetes.io/warn"  = "baseline"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# #116 ArgoCD namespace 네트워크 경계. ClusterIP는 클러스터 내부 접근을 막지
# 않으므로(코드 리뷰 finding), deny-by-default NetworkPolicy로 다른 namespace
# 워크로드에서 ArgoCD 제어면(server/repo-server/redis) 접근을 차단한다.
# enforcement는 dev root gke.tf의 Calico 활성화(#116)가 전제다.

resource "kubernetes_network_policy_v1" "argocd_ingress" {
  metadata {
    name      = "argocd-ingress"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Ingress"]

    # ArgoCD 컴포넌트 간 통신 (server ↔ repo-server ↔ redis ↔ controller)
    ingress {
      from {
        pod_selector {}
      }
    }

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
      }
    }

    # kubectl port-forward 경로: 트래픽이 pod가 아니라 노드(kubelet, dev subnet
    # IP)에서 출발하므로, 노드 대역에서 argocd-server 컨테이너 포트(8080)로의
    # ingress를 허용해야 UI 접근이 유지된다. airflow-k8s의 #48 규칙과 동일 패턴.
    ingress {
      from {
        ip_block {
          cidr = var.ui_ingress_source_cidr
        }
      }

      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "argocd_egress" {
  metadata {
    name      = "argocd-egress"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Egress"]

    # 같은 namespace 내 컴포넌트 간 통신 (redis 6379, repo-server 8081 등)
    egress {
      to {
        pod_selector {}
      }
    }

    # #122 service VIP 경유 트래픽. 이 클러스터의 Calico는 egress를 DNAT
    # 이전(service VIP 기준)에 평가하므로 selector가 VIP에 매칭되지 않는다.
    # kube-dns(53), redis(6379), repo-server(8081) VIP를 services CIDR
    # ipBlock으로 허용한다. kubernetes API VIP(443)는 아래 443 규칙이 커버.
    # 위 selector 규칙들은 post-DNAT 평가 dataplane 대비로 유지한다.
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

      ports {
        protocol = "TCP"
        port     = "6379"
      }

      ports {
        protocol = "TCP"
        port     = "8081"
      }
    }

    # DNS (kube-dns)
    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
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

    # Git/Helm repository와 Kubernetes API server 접근(HTTPS).
    # git ssh(22)는 현재 미사용이라 열지 않는다. 필요 시 별도 변경으로 추가.
    # #138 검토: GitHub 등 외부 repo IP는 고정 CIDR로 관리할 수 없어
    # 0.0.0.0/0을 유지한다(vault처럼 private.googleapis VIP로 축소 불가).
    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# #84 ArgoCD 최소 설치. UI는 ClusterIP + kubectl port-forward 내부 접근만 허용한다.
# 초기 admin 비밀번호는 chart가 생성하는 argocd-initial-admin-secret으로 회수하고,
# 변경 후 삭제한다(절차는 README). secret payload는 Terraform/Git에 저장하지 않는다.
resource "helm_release" "argo_cd" {
  name       = var.argo_cd_release_name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argo_cd_chart_version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name

  atomic           = true
  cleanup_on_fail  = true
  create_namespace = false
  timeout          = 600

  # #289 templatefile로 RBAC policy에 허용 이메일을 주입한다. client id/secret은
  # 여기 담지 않고 argocd-google-oidc Secret을 oidc.config에서 $ 참조한다(README).
  values = [
    templatefile("${path.module}/${var.argocd_values_file_path}", {
      argocd_server_url = var.argocd_server_url
      admin_emails      = var.argocd_admin_user_emails
      readonly_emails   = var.argocd_readonly_user_emails
    })
  ]
}

# #183 #85 샘플(sample-guestbook/argocd-sample)은 sync/diff/rollback 흐름
# 검증을 마쳤고, 실제 repo(monitoring umbrella chart) 연결 시점에 제거했다.
# 이유: AppProject clusterResourceWhitelist(CRD/ClusterRole/ClusterRoleBinding/
# webhook)는 프로젝트 단위 정책이라 같은 프로젝트의 모든 Application에 적용된다.
# 샘플을 남겨두면 cluster-wide 권한(특히 ClusterRoleBinding 권한 상승 표면)이
# monitoring 외 Application까지 확대되므로, 최소 권한 원칙에 따라 프로젝트를
# monitoring 전용으로 좁힌다(코드 리뷰 반영).

# 주의(부트스트랩 순서): kubernetes_manifest는 plan 단계에서 대상 CRD의
# 스키마를 클러스터에서 조회하므로, ArgoCD CRD가 없는 빈 클러스터에서는
# depends_on과 무관하게 초기 plan이 실패한다. 완전 재구성 시에는
#   terraform apply -target=helm_release.argo_cd
# 로 chart(CRD 포함)를 먼저 설치한 뒤 전체 plan/apply를 실행한다(README 참조).

# AppProject: Application이 접근할 수 있는 repo/destination을 제한하는 경계.
# monitoring 전용으로 좁힌다(샘플 제거, 코드 리뷰 반영).
# - sourceRepos: infra repo(#183 monitoring umbrella chart)만.
# - destinations: monitoring namespace(#183)만.
# - clusterResourceWhitelist: kube-prometheus-stack이 CRD/ClusterRole/webhook
#   같은 cluster-wide 리소스를 설치하므로 필요한 kind만 허용한다(#183, 최소).
#   프로젝트에 monitoring Application만 있으므로 이 권한은 monitoring에 국한된다.
resource "kubernetes_manifest" "appproject_autoresearch_dev" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "autoresearch-dev"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }
    spec = {
      description = "AutoResearch dev GitOps boundary (#183 monitoring). 샘플(#85)은 검증 후 제거."
      sourceRepos = [
        var.infra_repo_url,
      ]
      destinations = [
        {
          # #183 monitoring namespace는 terraform/admin/monitoring-k8s가 소유.
          server    = "https://kubernetes.default.svc"
          namespace = var.monitoring_namespace
        },
        {
          server    = "https://kubernetes.default.svc"
          namespace = var.rollouts_namespace
        },
        {
          # #183 kube-prometheus-stack은 control-plane exporter Service
          # (coredns/kube-controller-manager/kube-etcd/kube-proxy/kube-scheduler)를
          # kube-system에 둔다. 실행 중 스택을 그대로 adopt하려면 이 destination이
          # 필요하다. 이 프로젝트에는 monitoring Application만 있고 source는 infra
          # repo로 고정, manual sync·prune off라 권한 범위는 제한적이다.
          # (GKE에서 스크랩 불가한 control-plane exporter 비활성화는 별도 튜닝 과제)
          server    = "https://kubernetes.default.svc"
          namespace = "kube-system"
        },
        {
          # #94 MLflow namespace는 terraform/admin/mlflow-k8s가 소유(ns/KSA/NP).
          # ArgoCD는 deploy/mlflow(Deployment/Service)만 이 namespace에 배포한다.
          server    = "https://kubernetes.default.svc"
          namespace = var.mlflow_namespace
        },
        {
          # #302 앱 namespace는 terraform/admin/autoresearch-k8s가 소유(ns/KSA/NP).
          # ArgoCD는 deploy/serving(Deployment/Service/ServiceMonitor)만 배포한다.
          server    = "https://kubernetes.default.svc"
          namespace = var.app_namespace
        },
      ]
      # #183 kube-prometheus-stack이 요구하는 cluster-wide kind만 허용.
      clusterResourceWhitelist = [
        { group = "apiextensions.k8s.io", kind = "CustomResourceDefinition" },
        { group = "rbac.authorization.k8s.io", kind = "ClusterRole" },
        { group = "rbac.authorization.k8s.io", kind = "ClusterRoleBinding" },
        { group = "admissionregistration.k8s.io", kind = "ValidatingWebhookConfiguration" },
        { group = "admissionregistration.k8s.io", kind = "MutatingWebhookConfiguration" },
      ]
    }
  }

  depends_on = [helm_release.argo_cd]
}

# #183 monitoring 스택 Application — infra repo의 deploy/monitoring umbrella
# chart를 배포한다. Terraform helm_release에서 이관(GitOps 파일럿).
# syncPolicy 미지정 = manual sync(GITOPS_STRATEGY 초기 원칙). 실행 중 스택을
# 인수(adopt)하므로 최초 sync 전 diff 검토 필수(README 이관 절차).
resource "kubernetes_manifest" "application_monitoring" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "monitoring"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }
    spec = {
      project = kubernetes_manifest.appproject_autoresearch_dev.manifest.metadata.name
      source = {
        repoURL = var.infra_repo_url
        path    = "deploy/monitoring"
        # 최초 adopt는 병합 커밋 SHA로 pin해 렌더가 live와 일치하도록 한다
        # (var를 apply 시 -var로 주입; 코드 리뷰 반영). 기본 main은 파일럿
        # 이후 manual sync 추적용.
        targetRevision = var.monitoring_target_revision
        helm = {
          # #183 [치명 리스크 수정] release name을 기존 helm_release와 동일하게
          # 고정한다. 미지정 시 ArgoCD가 Application 이름("monitoring")을 release
          # name으로 써 subchart 리소스가 monitoring-* 로 개명 → 기존
          # kube-prometheus-stack-* 를 인수(adopt)하지 못하고 빈 PVC로 새 스택을
          # 나란히 생성(데이터 손실). 실측으로 이름 일치 확인.
          releaseName = "kube-prometheus-stack"
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.monitoring_namespace
      }
      syncPolicy = {
        # 실행 중 리소스의 helm managed-by 라벨 차이를 흡수 + namespace는
        # TF 소유라 생성 안 함. auto-sync/prune 없음(수동).
        syncOptions = [
          "ServerSideApply=true",
          "CreateNamespace=false",
        ]
      }
    }
  }

  depends_on = [helm_release.argo_cd]
}

resource "kubernetes_manifest" "application_argo_rollouts" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "argo-rollouts"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }
    spec = {
      project = kubernetes_manifest.appproject_autoresearch_dev.manifest.metadata.name
      source = {
        repoURL        = var.infra_repo_url
        path           = "deploy/argo-rollouts"
        targetRevision = var.rollouts_target_revision
        helm = {
          # 기존 helm_release의 CRD/ClusterRole/ClusterRoleBinding을 adopt하려면
          # release name이 기존 release와 정확히 일치해야 한다.
          releaseName = "argo-rollouts"
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.rollouts_namespace
      }
      syncPolicy = {
        syncOptions = [
          "ServerSideApply=true",
          "CreateNamespace=false",
        ]
      }
    }
  }

  depends_on = [helm_release.argo_cd]
}

# #94 MLflow tracking server Application — infra repo의 deploy/mlflow(plain
# 매니페스트: Deployment/Service)를 배포한다. helm adopt가 아니라 신규 배포이며
# namespace는 mlflow-k8s가 소유하므로 CreateNamespace=false. manual sync(초기 원칙).
resource "kubernetes_manifest" "application_mlflow" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "mlflow"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }
    spec = {
      project = kubernetes_manifest.appproject_autoresearch_dev.manifest.metadata.name
      source = {
        repoURL        = var.infra_repo_url
        path           = "deploy/mlflow"
        targetRevision = var.mlflow_target_revision
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.mlflow_namespace
      }
      syncPolicy = {
        syncOptions = [
          "CreateNamespace=false",
        ]
      }
    }
  }

  depends_on = [helm_release.argo_cd]
}

# #302 Inference Server Application — infra repo의 deploy/serving(plain 매니페스트:
# Deployment/Service/ServiceMonitor)을 배포한다. namespace는 autoresearch-k8s가
# 소유하므로 CreateNamespace=false. manual sync(초기 원칙).
# 이미지는 manifest에 immutable digest로 고정되며, 롤백은 이전 digest 커밋 후 sync다.
resource "kubernetes_manifest" "application_serving" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "serving"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }
    spec = {
      project = kubernetes_manifest.appproject_autoresearch_dev.manifest.metadata.name
      source = {
        repoURL        = var.infra_repo_url
        path           = "deploy/serving"
        targetRevision = var.serving_target_revision
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.app_namespace
      }
      syncPolicy = {
        syncOptions = [
          "CreateNamespace=false",
        ]
      }
    }
  }

  depends_on = [helm_release.argo_cd]
}
