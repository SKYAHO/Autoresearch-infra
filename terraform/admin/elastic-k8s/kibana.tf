# #99 Kibana 내부 접근 구성. UI는 ClusterIP + kubectl port-forward만 허용
# (외부 공개 금지 — LB/Ingress 없음). ES와 동일 스택 버전을 쓴다.
# 접속 절차는 README, 전체 운영 절차는 #103 runbook.

resource "kubernetes_manifest" "kibana" {
  manifest = {
    apiVersion = "kibana.k8s.elastic.co/v1"
    kind       = "Kibana"
    metadata = {
      name      = "autoresearch"
      namespace = kubernetes_namespace_v1.elastic.metadata[0].name
    }
    spec = {
      version = var.elasticsearch_version
      count   = 1

      # 같은 namespace의 ES를 operator가 연결(계정/CA 자동 구성)
      elasticsearchRef = {
        name = "autoresearch"
      }

      # #293 앞단 oauth2-proxy(Google 로그인)를 통과한 요청을 재로그인 없이
      # 익명 사용자로 자동 로그인. anonymous(order 0)를 기본으로, basic(order 1)은
      # elastic 슈퍼유저 break-glass용(`/login`)으로 유지한다. credentials
      # 키워드가 ES의 anonymous 사용자(elasticsearch.tf)를 그대로 쓴다.
      # publicBaseUrl은 proxy 뒤 접근 URL(port-forward라 localhost:4181).
      config = {
        "xpack.security.authc.providers" = {
          "anonymous.anonymous1" = {
            order       = 0
            credentials = "elasticsearch_anonymous_user"
          }
          "basic.basic1" = {
            order = 1
          }
        }
        "server.publicBaseUrl" = var.kibana_public_base_url
        # ECK가 Kibana 내부 TLS를 활성화하지만, 사용자는 로컬 HTTP
        # port-forward(4181)로 접속하므로 세션 쿠키를 Secure로 만들지 않는다.
        "xpack.security.secureCookies" = false
      }

      podTemplate = {
        # 서버(ECK)가 빈 metadata를 정규화 결과로 유지하므로 동일하게
        # 선언해 desired와 server 상태를 일치시킨다(왕복 안정화, #99).
        metadata = {}
        spec = {
          # ES와 같은 이유(#98)로 dev-default pool 고정
          nodeSelector = {
            "cloud.google.com/gke-nodepool" = "dev-default"
          }

          containers = [
            {
              name = "kibana"
              resources = {
                requests = {
                  cpu    = "200m"
                  memory = "1Gi"
                }
                limits = {
                  memory = "1Gi"
                }
              }
            },
          ]
        }
      }
    }
  }

  # ES CR과 동일(#98): operator defaulting 필드와의 SSA 경계 충돌 방지
  field_manager {
    force_conflicts = true
  }

  # 왕복 안정화(#99 실측): 위 podTemplate.metadata = {} 선언과 이
  # computed_fields의 '조합'에서만 연속 plan이 No changes로 수렴한다.
  # 각각 단독으로는 정규화 drift 또는 'inconsistent result' 오류가 재발
  # (실험 기록은 #99 코멘트). 두 블록을 함께 유지할 것.
  computed_fields = [
    "metadata.labels",
    "metadata.annotations",
    "spec.podTemplate.metadata",
  ]

  depends_on = [helm_release.eck_operator]
}
