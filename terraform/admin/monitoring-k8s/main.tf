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

resource "helm_release" "kube_prometheus_stack" {
  name       = var.kube_prometheus_stack_release_name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_chart_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  atomic           = true
  cleanup_on_fail  = true
  create_namespace = false
  timeout          = 600

  values = [
    file("${path.module}/helm-values/kube-prometheus-stack.values.yaml")
  ]

  set {
    name  = "grafana.admin.existingSecret"
    value = var.grafana_admin_existing_secret_name
  }

  set {
    name  = "grafana.admin.userKey"
    value = var.grafana_admin_user_key
  }

  set {
    name  = "grafana.admin.passwordKey"
    value = var.grafana_admin_password_key
  }

  depends_on = [kubernetes_namespace_v1.monitoring]
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
