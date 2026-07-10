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

# 주의(부트스트랩 순서): kubernetes_manifest는 plan 단계에서 대상 CRD의
# 스키마를 클러스터에서 조회하므로, ArgoCD CRD가 없는 빈 클러스터에서는
# depends_on과 무관하게 초기 plan이 실패한다. 완전 재구성 시에는
#   terraform apply -target=helm_release.argo_cd
# 로 chart(CRD 포함)를 먼저 설치한 뒤 전체 plan/apply를 실행한다(README 참조).

# AppProject: Application이 접근할 수 있는 repo/destination을 제한하는 경계.
# - sourceRepos: 공개 샘플 repo(#85)와 Airflow 저장소(#124). Airflow
#   Application 자체는 umbrella chart(Autoresearch-airflow#17) 준비 후
#   후속 이슈에서 생성한다.
# - destinations: argocd-sample(#85)과 airflow(#124) namespace만.
# - cluster-wide 리소스: AppProject 기본값이 거부(clusterResourceWhitelist
#   미지정 = 빈 목록)라 별도 필드를 넣지 않는다. 빈 목록을 명시하면
#   kubernetes_manifest가 서버 정규화와 충돌해 영구 diff가 생길 수 있다.
# - namespaced kind whitelist 하드닝은 Airflow Application 이슈에서 chart
#   렌더링 결과 기준으로 결정한다.
resource "kubernetes_manifest" "appproject_autoresearch_dev" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "AppProject"
    metadata = {
      name      = "autoresearch-dev"
      namespace = kubernetes_namespace_v1.argocd.metadata[0].name
    }
    spec = {
      description = "AutoResearch dev GitOps boundary"
      sourceRepos = [
        "https://github.com/argoproj/argocd-example-apps.git",
        "https://github.com/SKYAHO/Autoresearch-airflow.git",
      ]
      destinations = [
        {
          server    = "https://kubernetes.default.svc"
          namespace = kubernetes_namespace_v1.argocd_sample.metadata[0].name
        },
        {
          # airflow namespace는 terraform/admin/airflow-k8s가 소유한다.
          server    = "https://kubernetes.default.svc"
          namespace = "airflow"
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
        repoURL = "https://github.com/argoproj/argocd-example-apps.git"
        path    = "guestbook"
        # 외부 repo HEAD 추적 대신 커밋 SHA pin — 검증 재현성 확보 (리뷰 반영).
        targetRevision = "8088f4c0d970abb09e250248cc97e35623447cb5"
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = kubernetes_namespace_v1.argocd_sample.metadata[0].name
      }
    }
  }
}
