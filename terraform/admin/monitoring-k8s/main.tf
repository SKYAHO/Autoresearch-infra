# Monitoring Kubernetes boundary is separated from terraform/envs/dev because
# Kubernetes API access and Helm lifecycle are operator-controlled actions.

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = var.monitoring_namespace

    labels = {
      "app.kubernetes.io/name"           = "monitoring"
      "app.kubernetes.io/part-of"        = "observability"
      "pod-security.kubernetes.io/audit" = "baseline"
      "pod-security.kubernetes.io/warn"  = "baseline"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# #183 kube-prometheus-stack helm_release는 ArgoCD Application으로 이관했다
# (GitOps 파일럿). chart/values는 이제 infra repo `deploy/monitoring/`
# umbrella chart + argocd-k8s의 Application이 관리한다. 이 root는
# GITOPS_STRATEGY 책임 분리에 따라 namespace와 port-forward RBAC(플랫폼
# 경계)만 유지한다.

# #183 [리스크 수정] helm_release를 코드에서 그냥 지우면, state에 남은 채
# apply될 때 Terraform이 release를 destroy(=helm uninstall, 전체 스택+PVC 삭제)
# 한다. removed 블록 + destroy=false로 "state에서만 제거, 실제 release는 유지"를
# 강제해 무중단을 보장한다(수동 state rm 순서 의존 제거). 이관이 끝나 state에서
# 사라지면 이 블록·helm provider는 별도 정리 PR에서 제거한다.
removed {
  from = helm_release.kube_prometheus_stack
  lifecycle {
    destroy = false
  }
}

locals {
  monitoring_port_forward_users = {
    for email in var.monitoring_port_forward_user_emails :
    lower(trimspace(email)) => lower(trimspace(email))
  }
}

resource "kubernetes_role_v1" "monitoring_port_forward" {
  metadata {
    name      = "monitoring-port-forward"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "endpoints"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/portforward"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding_v1" "monitoring_port_forward" {
  for_each = local.monitoring_port_forward_users

  metadata {
    name      = "monitoring-port-forward-${substr(sha1(each.key), 0, 10)}"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.monitoring_port_forward.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = each.value
  }
}
