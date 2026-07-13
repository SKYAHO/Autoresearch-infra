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

      podTemplate = {
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

  # 서버가 podTemplate.metadata를 빈 객체로 정규화해 provider 왕복이
  # 불안정해진다(#99 검증에서 'inconsistent result after apply' 재현).
  # 해당 경로를 computed로 지정해 diff 대상에서 제외한다. 앞의 두 항목은
  # provider 기본값 유지분이다.
  computed_fields = [
    "metadata.labels",
    "metadata.annotations",
    "spec.podTemplate.metadata",
  ]

  depends_on = [helm_release.eck_operator]
}
