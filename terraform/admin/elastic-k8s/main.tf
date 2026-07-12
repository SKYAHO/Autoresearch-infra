# #97 ECK operator 설치 기반. ELK 아키텍처는 #96 설계를 따른다:
# docs/superpowers/specs/2026-07-13-elk-architecture-design.md
# Elasticsearch/Kibana CR 생성은 후속 이슈(#98/#99)에서 이 root에 추가한다.
# 이슈 본문의 elastic-system 대신 #96 설계대로 단일 namespace `elastic`을
# 사용한다(operator + ES + Kibana + Beat 최소 구성).

resource "kubernetes_namespace_v1" "elastic" {
  metadata {
    name = var.elastic_namespace

    labels = {
      "app.kubernetes.io/name"           = "elastic"
      "app.kubernetes.io/part-of"        = "observability"
      "pod-security.kubernetes.io/audit" = "baseline"
      "pod-security.kubernetes.io/warn"  = "baseline"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_network_policy_v1" "elastic_ingress" {
  metadata {
    name      = "elastic-ingress"
    namespace = kubernetes_namespace_v1.elastic.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Ingress"]

    # 같은 namespace (Kibana→ES 9200, ES transport 9300, Filebeat→ES 등)
    ingress {
      from {
        pod_selector {}
      }
    }

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
      }
    }

    # ECK validating webhook: control plane → operator. webhook 포트를
    # 10250으로 옮겨(GKE 기본 master→node 허용 포트) 별도 firewall 없이
    # 동작시키는 monitoring-k8s(prometheusOperator.internalPort) 선례를
    # 따르고, NetworkPolicy에서도 master 대역을 허용한다.
    ingress {
      from {
        ip_block {
          cidr = var.cluster_master_cidr
        }
      }

      ports {
        port     = "10250"
        protocol = "TCP"
      }
    }

    # kubectl port-forward 경로(#116 교훈): 노드 대역 → Kibana 5601.
    # Kibana CR은 #99에서 추가되지만 경계는 미리 선언해 둔다.
    ingress {
      from {
        ip_block {
          cidr = var.kibana_ingress_source_cidr
        }
      }

      ports {
        port     = "5601"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "elastic_egress" {
  metadata {
    name      = "elastic-egress"
    namespace = kubernetes_namespace_v1.elastic.metadata[0].name
  }

  spec {
    pod_selector {}

    policy_types = ["Egress"]

    egress {
      to {
        pod_selector {}
      }
    }

    # #122 pre-DNAT(VIP) 평가: kube-dns(53), kubernetes.default(443)
    egress {
      to {
        ip_block {
          cidr = var.cluster_services_cidr
        }
      }

      ports {
        protocol = "UDP"
        port     = "53"
      }

      ports {
        protocol = "TCP"
        port     = "53"
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }

    # DNS post-DNAT dataplane 대비 유지 (#122)
    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
      }

      ports {
        protocol = "UDP"
        port     = "53"
      }

      ports {
        protocol = "TCP"
        port     = "53"
      }
    }

    # K8s API post-DNAT 목적지(master) 대비 (#138 패턴)
    egress {
      to {
        ip_block {
          cidr = var.cluster_master_cidr
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }

    # Google API — ES snapshot(GCS, #102)용. private googleapis DNS
    # zone(#138)이 googleapis.com을 이 고정 VIP로 유도한다.
    egress {
      to {
        ip_block {
          cidr = "199.36.153.8/30"
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }
}

# #97 ECK operator 최소 설치. CRD는 chart의 crds/ 경로로 설치되며 helm
# uninstall이 CRD를 삭제하지 않는다(rollouts와 동일 주의 — CRD를 지우면
# Elasticsearch/Kibana CR 연쇄 삭제로 데이터 유실).
resource "helm_release" "eck_operator" {
  name       = var.eck_release_name
  repository = "https://helm.elastic.co"
  chart      = "eck-operator"
  version    = var.eck_chart_version
  namespace  = kubernetes_namespace_v1.elastic.metadata[0].name

  atomic           = true
  cleanup_on_fail  = true
  create_namespace = false
  timeout          = 600

  values = [
    file("${path.module}/${var.eck_values_file_path}")
  ]
}
