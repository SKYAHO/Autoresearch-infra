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

  values = [
    file("${path.module}/${var.argocd_values_file_path}")
  ]
}

# #85 AppProject/Application 샘플. 실제 Airflow/앱 연결 전에 ArgoCD의
# sync/diff/rollback 흐름을 무해한 공개 샘플(guestbook)로 검증한다.
# 검증이 끝나고 실제 repo를 연결하는 이슈에서 샘플 리소스는 제거한다.

# 샘플 워크로드 전용 namespace. 검증용이라 prevent_destroy를 두지 않는다.
resource "kubernetes_namespace_v1" "argocd_sample" {
  metadata {
    name = "argocd-sample"

    labels = {
      "app.kubernetes.io/name"    = "argocd-sample"
      "app.kubernetes.io/part-of" = "gitops"
    }
  }
}

# AppProject: Application이 접근할 수 있는 repo/destination을 제한하는 경계.
# - sourceRepos: 공개 샘플 repo만 허용. Airflow 저장소는 실제 Application을
#   만드는 이슈에서 추가한다(미리 열어두지 않음 — 최소 허용).
# - destinations: argocd-sample namespace만.
# - cluster-wide 리소스: AppProject 기본값이 거부(clusterResourceWhitelist
#   미지정 = 빈 목록)라 별도 필드를 넣지 않는다. 빈 목록을 명시하면
#   kubernetes_manifest가 서버 정규화와 충돌해 영구 diff가 생길 수 있다.
resource "kubernetes_manifest" "appproject_autoresearch_dev" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "autoresearch-dev"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }
    spec = {
      description = "AutoResearch dev GitOps boundary (#85 sample scope)"
      sourceRepos = [
        "https://github.com/argoproj/argocd-example-apps.git",
      ]
      destinations = [
        {
          server    = "https://kubernetes.default.svc"
          namespace = kubernetes_namespace_v1.argocd_sample.metadata[0].name
        },
      ]
    }
  }

  depends_on = [helm_release.argo_cd]
}

# 샘플 Application. syncPolicy를 지정하지 않아 manual sync로만 동작한다
# (auto-sync/prune/self-heal 없음 — GITOPS_STRATEGY 초기 원칙).
resource "kubernetes_manifest" "application_sample_guestbook" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "sample-guestbook"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }
    spec = {
      project = kubernetes_manifest.appproject_autoresearch_dev.manifest.metadata.name
      source = {
        repoURL        = "https://github.com/argoproj/argocd-example-apps.git"
        path           = "guestbook"
        targetRevision = "HEAD"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace_v1.argocd_sample.metadata[0].name
      }
    }
  }
}
