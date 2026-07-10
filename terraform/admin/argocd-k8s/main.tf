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
