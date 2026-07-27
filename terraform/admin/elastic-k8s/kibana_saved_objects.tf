# #365 Kibana saved object 자동 import — 저장소의 ndjson(유일 복구 원본,
# .kibana*는 SLM 스냅샷 범위 밖)을 ConfigMap으로 배포하고, 내용 해시가
# 바뀔 때마다 이름이 바뀌는 Job이 `_import?overwrite=true`(멱등)를 호출한다.
# 재해복구·재구축 시 terraform apply만으로 data view·저장 검색·대시보드가
# 복원된다(수동 import 단계 제거 — README DR 절 참조).
#
# 네트워크: Job → Kibana Service VIP(5601)는 elastic-egress의 services CIDR
# 5601 규칙(#293)으로 이미 허용된다. Kibana 기동 전 실행되면 backoff 재시도
# (OnFailure × 6)로 흡수한다.

locals {
  kibana_saved_objects_ndjson = file("${path.module}/kibana-saved-objects/logs-overview.ndjson")
  kibana_saved_objects_hash   = substr(sha256(local.kibana_saved_objects_ndjson), 0, 8)
}

resource "kubernetes_config_map_v1" "kibana_saved_objects" {
  metadata {
    name      = "kibana-saved-objects"
    namespace = kubernetes_namespace_v1.elastic.metadata[0].name
  }

  data = {
    "logs-overview.ndjson" = local.kibana_saved_objects_ndjson
  }
}

resource "kubernetes_job_v1" "kibana_saved_objects_import" {
  metadata {
    # 해시가 이름에 들어가 ndjson 변경 시 Job이 교체(재실행)된다.
    # TTL을 걸지 않아 완료된 Job이 남고 plan은 안정된다(왕복 No changes).
    name      = "kibana-so-import-${local.kibana_saved_objects_hash}"
    namespace = kubernetes_namespace_v1.elastic.metadata[0].name
    labels = {
      "app.kubernetes.io/name" = "kibana-so-import"
    }
  }

  spec {
    backoff_limit = 6

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name" = "kibana-so-import"
        }
      }

      spec {
        restart_policy = "OnFailure"

        container {
          name  = "import"
          image = "curlimages/curl:8.17.0"

          command = [
            "/bin/sh", "-ec",
            <<-EOT
              curl --fail-with-body -sk -u "elastic:$ES_PASSWORD" \
                -X POST 'https://autoresearch-kb-http:5601/api/saved_objects/_import?overwrite=true' \
                -H 'kbn-xsrf: kibana-so-import' \
                --form file=@/import/logs-overview.ndjson
            EOT
          ]

          env {
            name = "ES_PASSWORD"
            value_from {
              secret_key_ref {
                name = "autoresearch-es-elastic-user"
                key  = "elastic"
              }
            }
          }

          volume_mount {
            name       = "objects"
            mount_path = "/import"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }
        }

        volume {
          name = "objects"

          config_map {
            name = kubernetes_config_map_v1.kibana_saved_objects.metadata[0].name
          }
        }
      }
    }
  }

  wait_for_completion = false

  depends_on = [kubernetes_manifest.kibana]
}
