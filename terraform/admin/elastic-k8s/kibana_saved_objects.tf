# #365 Kibana saved object 자동 import — 저장소의 ndjson(유일 복구 원본,
# .kibana*는 SLM 스냅샷 범위 밖)을 ConfigMap으로 배포하고, 내용 해시가
# 바뀔 때마다 이름이 바뀌는 Job이 `_import?overwrite=true`(멱등)를 호출한다.
# 재해복구·재구축 시 terraform apply만으로 data view·저장 검색·대시보드가
# 복원된다(수동 import 단계 제거 — README DR 절 참조).
#
# 네트워크: Job → Kibana Service VIP(5601)는 elastic-egress의 services CIDR
# 5601 규칙(#293)으로 이미 허용된다. Kibana 기동 전 실행되면 스크립트의
# 기동 선폴링(최대 10분) + backoff 재시도(OnFailure × 6)로 흡수한다.
#
# 재실행 트리거(리뷰 반영 — 문서와 일치해야 함): ① ndjson 내용 변경(해시
# 이름 교체) ② 완전 재구성(Job 리소스 자체가 새로 생성). **파일이 그대로인
# 채 UI에서 객체만 삭제된 경우 apply는 No changes**이므로 복원을 강제하려면
#   terraform apply -replace=kubernetes_job_v1.kibana_saved_objects_import
# (KIBANA runbook 참조).
#
# wait_for_completion=false 근거: DR에서 admin-apply CI를 Kibana 기동
# 시간(수 분)만큼 붙잡지 않기 위함. 실패는 apply가 아니라 Job 상태로
# 드러난다 — 본문 success:true 검증으로 부분 실패도 Job Failed가 되므로
# `kubectl -n elastic get jobs -l app.kubernetes.io/name=kibana-so-import`로
# 확인한다(검증 절차는 runbook).

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

          # 자격 증명은 netrc 파일로 전달(argv 평문 노출 회피 — 리뷰 반영),
          # TLS는 ECK 발급 CA로 검증(superuser 자격이라 -k 미사용 — 세션
          # 쿠키뿐인 oauth2-proxy의 skip-verify 선례와 기준을 달리함).
          # 전용 최소권한 Kibana user 발급은 dev 범위에서 보류(후속 여지) —
          # 이 Job은 K8s Secret 접근 권한과 동일 신뢰 경계 안에서만 돈다.
          command = [
            "/bin/sh", "-ec",
            <<-EOT
              umask 077
              printf 'machine autoresearch-kb-http login elastic password %s\n' "$ES_PASSWORD" > /tmp/netrc
              # DR(완전 재구성)에서 ES green→Kibana 마이그레이션 완료까지
              # backoff 예산(약 10분)보다 길 수 있어 기동을 선폴링한다(리뷰 반영).
              for i in $(seq 1 60); do
                # -f 필수: 마이그레이션 중 /api/status는 503을 반환하는데
                # -s만으로는 exit 0이라 조기 탈출한다.
                curl -sf --cacert /certs/ca.crt --netrc-file /tmp/netrc \
                  https://autoresearch-kb-http:5601/api/status > /dev/null && break
                echo "waiting kibana ($i/60)"; sleep 10
              done
              RESP=$(curl --fail-with-body -s --cacert /certs/ca.crt --netrc-file /tmp/netrc \
                -X POST 'https://autoresearch-kb-http:5601/api/saved_objects/_import?overwrite=true' \
                -H 'kbn-xsrf: kibana-so-import' \
                --form file=@/import/logs-overview.ndjson) || { echo "$RESP"; exit 1; }
              echo "$RESP"
              # _import는 개별 객체 실패도 HTTP 200으로 반환하므로 본문을 검증한다
              # (부분 실패 무음 방지 — 리뷰 반영).
              echo "$RESP" | grep -q '"success":true'
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

          volume_mount {
            name       = "kb-certs"
            mount_path = "/certs"
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

        volume {
          name = "kb-certs"

          secret {
            secret_name = "autoresearch-kb-http-certs-public"
          }
        }
      }
    }
  }

  wait_for_completion = false

  depends_on = [kubernetes_manifest.kibana]
}
