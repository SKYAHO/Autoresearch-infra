# #100 Filebeat 로그 수집. #96 설계:
# - Filebeat 채택(Elastic Agent 대비 단일 용도·설정 단순 — 수집만 필요)
# - 수집 범위는 namespace allowlist(airflow, autoresearch)로 한정
# - 시스템/타 namespace 로그는 Cloud Logging이 담당(중복 수집 방지 —
#   ELK에는 분석 대상 앱 로그만)

# Filebeat autodiscover가 pod 메타데이터를 조회하기 위한 최소 RBAC.
# ECK operator는 Beat용 RBAC를 만들어주지 않으므로 직접 관리한다.
resource "kubernetes_service_account_v1" "filebeat" {
  metadata {
    name      = "filebeat"
    namespace = kubernetes_namespace_v1.elastic.metadata[0].name
  }
}

resource "kubernetes_cluster_role_v1" "filebeat_autodiscover" {
  metadata {
    name = "filebeat-autodiscover"
  }

  # autodiscover가 필요한 읽기 권한만 부여한다(쓰기 없음).
  rule {
    api_groups = [""]
    resources  = ["pods", "namespaces", "nodes"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["replicasets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "filebeat_autodiscover" {
  metadata {
    name = "filebeat-autodiscover"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.filebeat_autodiscover.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.filebeat.metadata[0].name
    namespace = kubernetes_namespace_v1.elastic.metadata[0].name
  }
}

# Filebeat DaemonSet. hostPath(/var/log) read는 PSS baseline 위반이지만
# 이 namespace 라벨은 audit/warn(비강제)이라 기동은 되며, 로그 수집기의
# 본질적 요구로 수용한다(#96 spec에서 확인 예약된 항목 — 결론 기록).
resource "kubernetes_manifest" "filebeat" {
  manifest = {
    apiVersion = "beat.k8s.elastic.co/v1beta1"
    kind       = "Beat"
    metadata = {
      name      = "autoresearch"
      namespace = kubernetes_namespace_v1.elastic.metadata[0].name
    }
    spec = {
      type    = "filebeat"
      version = var.elasticsearch_version

      elasticsearchRef = {
        name = "autoresearch"
      }

      config = {
        filebeat = {
          autodiscover = {
            providers = [
              {
                type = "kubernetes"
                node = "$${NODE_NAME}"
                # namespace allowlist(#96): airflow·autoresearch만 수집.
                # 시스템/플랫폼 namespace는 Cloud Logging 담당(중복 방지).
                templates = [
                  {
                    condition = {
                      or = [
                        { equals = { "kubernetes.namespace" = "airflow" } },
                        { equals = { "kubernetes.namespace" = "autoresearch" } },
                      ]
                    }
                    config = [
                      {
                        type = "container"
                        paths = [
                          "/var/log/containers/*$${data.kubernetes.container.id}.log",
                        ]
                      },
                    ]
                  },
                ]
              },
            ]
          }
        }
        processors = [
          { add_host_metadata = {} },
        ]
      }

      daemonSet = {
        podTemplate = {
          # 서버 정규화 왕복 안정화 — kibana.tf와 동일 조합(#99 실측)
          metadata = {}
          spec = {
            serviceAccountName           = kubernetes_service_account_v1.filebeat.metadata[0].name
            automountServiceAccountToken = true
            dnsPolicy                    = "ClusterFirstWithHostNet"
            securityContext = {
              runAsUser = 0
            }
            containers = [
              {
                name = "filebeat"
                # autodiscover의 ${NODE_NAME} 참조용 — operator가 자동
                # 주입하지 않으므로 직접 선언(리뷰 반영, ECK 공식 레시피 동일)
                env = [
                  {
                    name = "NODE_NAME"
                    valueFrom = {
                      fieldRef = {
                        fieldPath = "spec.nodeName"
                      }
                    }
                  },
                ]
                resources = {
                  requests = {
                    cpu    = "100m"
                    memory = "150Mi"
                  }
                  limits = {
                    memory = "300Mi"
                  }
                }
                volumeMounts = [
                  {
                    name      = "varlogcontainers"
                    mountPath = "/var/log/containers"
                    readOnly  = true
                  },
                  {
                    name      = "varlogpods"
                    mountPath = "/var/log/pods"
                    readOnly  = true
                  },
                ]
              },
            ]
            volumes = [
              {
                name = "varlogcontainers"
                hostPath = {
                  path = "/var/log/containers"
                }
              },
              {
                name = "varlogpods"
                hostPath = {
                  path = "/var/log/pods"
                }
              },
            ]
          }
        }
      }
    }
  }

  field_manager {
    force_conflicts = true
  }

  computed_fields = [
    "metadata.labels",
    "metadata.annotations",
    "spec.daemonSet.podTemplate.metadata",
  ]

  depends_on = [helm_release.eck_operator]
}
