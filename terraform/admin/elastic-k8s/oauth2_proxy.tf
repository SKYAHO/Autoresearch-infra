# #293 Kibana UI 앞단 인증 게이트(oauth2-proxy). Google 로그인 + 허용 이메일
# 목록으로 접근 제한. 사용자는 Kibana(5601)가 아니라 이 proxy(4180)로
# port-forward 하고, proxy가 인증 후 Kibana로 프록시한다. Kibana는 anonymous
# access(kibana.tf/elasticsearch.tf)로 재로그인 없이 자동 로그인된다.
#
# client id/secret·cookie-secret·허용 이메일은 공개 저장소에 두지 않고 operator
# 주입 Secret `kibana-oauth`에서 받는다(README 절차). MLflow(#232)와 동일 패턴.

resource "kubernetes_deployment_v1" "kibana_oauth_proxy" {
  metadata {
    name      = "kibana-oauth-proxy"
    namespace = kubernetes_namespace_v1.elastic.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "kibana-oauth-proxy"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        "app.kubernetes.io/name" = "kibana-oauth-proxy"
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "kibana-oauth-proxy"
        }
      }

      spec {
        # ES/Kibana와 동일 pool 고정(#98/#99).
        node_selector = {
          "cloud.google.com/gke-nodepool" = "dev-default"
        }

        container {
          name  = "oauth2-proxy"
          image = var.oauth2_proxy_image

          args = [
            "--provider=google",
            "--http-address=0.0.0.0:4180",
            # 인증 후 프록시 대상 = 내부 Kibana Service(https, ECK self-signed).
            "--upstream=https://autoresearch-kb-http.${kubernetes_namespace_v1.elastic.metadata[0].name}.svc:5601",
            "--ssl-upstream-insecure-skip-verify=true",
            # port-forward 시 브라우저는 localhost:4180. Google OAuth callback.
            "--redirect-url=${var.kibana_public_base_url}/oauth2/callback",
            # 실제 제한은 authenticated-emails-file(허용 목록)로 한다.
            "--email-domain=*",
            "--authenticated-emails-file=/etc/oauth2-proxy/authenticated-emails",
            # sign-in 페이지 유지(바로 리다이렉트 안 함).
            "--skip-provider-button=false",
            # port-forward는 http localhost라 secure 쿠키 불가.
            "--cookie-secure=false",
          ]

          env {
            name = "OAUTH2_PROXY_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = "kibana-oauth"
                key  = "client-id"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "kibana-oauth"
                key  = "client-secret"
              }
            }
          }
          env {
            name = "OAUTH2_PROXY_COOKIE_SECRET"
            value_from {
              secret_key_ref {
                name = "kibana-oauth"
                key  = "cookie-secret"
              }
            }
          }

          port {
            name           = "http"
            container_port = 4180
          }

          volume_mount {
            name       = "emails"
            mount_path = "/etc/oauth2-proxy"
            read_only  = true
          }

          readiness_probe {
            http_get {
              path = "/ping"
              port = "http"
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
          }

          liveness_probe {
            http_get {
              path = "/ping"
              port = "http"
            }
            initial_delay_seconds = 15
            period_seconds        = 20
            timeout_seconds       = 5
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "emails"
          secret {
            secret_name = "kibana-oauth"
            items {
              key  = "authenticated-emails"
              path = "authenticated-emails"
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.kibana]
}

# 접근: kubectl port-forward svc/kibana-oauth-proxy 4180:4180 → localhost:4180.
# ClusterIP(외부 노출 없음, Kibana와 동일 접근 모델). Kibana와 달리 사용자는 이
# proxy로 붙는다.
resource "kubernetes_service_v1" "kibana_oauth_proxy" {
  metadata {
    name      = "kibana-oauth-proxy"
    namespace = kubernetes_namespace_v1.elastic.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "kibana-oauth-proxy"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      "app.kubernetes.io/name" = "kibana-oauth-proxy"
    }

    port {
      name        = "http"
      port        = 4180
      target_port = "http"
      protocol    = "TCP"
    }
  }
}
