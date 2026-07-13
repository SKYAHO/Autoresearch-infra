# #100 Filebeat 로그 수집. #96 설계:
# - Filebeat 채택(Elastic Agent 대비 단일 용도·설정 단순 — 수집만 필요)
# - 수집 범위는 namespace allowlist(airflow, autoresearch)로 한정
# - 시스템/타 namespace 로그는 Cloud Logging이 담당(중복 수집 방지 —
#   ELK에는 분석 대상 앱 로그만)

# #101 ILM policy를 선언으로 관리한다. filebeat이 기동 시마다
# setup.ilm.overwrite로 이 policy를 재적용하므로, ES가 재구축되어도
# 수동 개입 없이 delete 7d가 복원된다(리뷰 반영 — 수동 curl 제거).
resource "kubernetes_config_map_v1" "filebeat_ilm_policy" {
  metadata {
    name      = "filebeat-ilm-policy"
    namespace = kubernetes_namespace_v1.elastic.metadata[0].name
  }

  data = {
    "ilm-policy.json" = jsonencode({
      policy = {
        phases = {
          hot = {
            actions = {
              rollover = {
                max_age                = "1d"
                max_primary_shard_size = "5gb"
              }
            }
          }
          delete = {
            min_age = "7d"
            actions = {
              delete = {}
            }
          }
        }
      }
    })
  }
}

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
        # #101 single-node에서 green 유지: filebeat 기본 템플릿의
        # replicas 1은 배치 불가(영구 yellow — #96/#98 예고 지점 실측 확인).
        # overwrite로 기존 템플릿을 replicas 0으로 교체한다. 기존 backing
        # index의 replicas는 운영자 절차로 0 적용(README ILM 절).
        setup = {
          template = {
            overwrite = true
            settings = {
              index = {
                number_of_replicas = 0
              }
            }
          }
          # policy는 ConfigMap(선언)에서 로드해 기동 시마다 재적용 — ES
          # 재구축 시에도 delete 7d 자동 복원(#101)
          ilm = {
            enabled     = true
            overwrite   = true
            policy_name = "filebeat"
            policy_file = "/usr/share/filebeat/ilm-policy.json"
          }
        }
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
                    # Filebeat 9.x는 container/log input이 제거되어
                    # filestream + container parser를 쓴다(#100 검증에서
                    # 'Auto discover config check failed'로 실측 확인).
                    # id는 autodiscover가 만드는 input마다 유일해야 한다.
                    config = [
                      {
                        type = "filestream"
                        id   = "container-$${data.kubernetes.container.id}"
                        prospector = {
                          scanner = {
                            # /var/log/containers/*.log는 symlink
                            symlinks = true
                          }
                        }
                        paths = [
                          "/var/log/containers/*$${data.kubernetes.container.id}.log",
                        ]
                        parsers = [
                          { container = {} },
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
                    name      = "ilm-policy"
                    mountPath = "/usr/share/filebeat/ilm-policy.json"
                    subPath   = "ilm-policy.json"
                    readOnly  = true
                  },
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
                name = "ilm-policy"
                configMap = {
                  name = "filebeat-ilm-policy"
                }
              },
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
