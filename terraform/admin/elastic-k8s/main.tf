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

    # kubectl port-forward 경로(#116 교훈): 노드 대역 → Kibana 5601 및
    # #293 oauth2-proxy 4180(사용자는 이 proxy로 붙는다).
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

      ports {
        port     = "4180"
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

    # #122 pre-DNAT(VIP) 평가: kube-dns(53), kubernetes.default(443),
    # Filebeat → ES http service VIP(9200, #100 — same-ns 규칙은 VIP에
    # 매칭되지 않으므로 필수)
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

      ports {
        protocol = "TCP"
        port     = "9200"
      }

      # #293 oauth2-proxy → Kibana Service VIP(5601). #122대로 Calico가 egress를
      # pre-DNAT(VIP) 평가하므로 same-ns pod_selector로는 안 잡혀 services CIDR
      # ipBlock으로 열어야 proxy→Kibana upstream이 성립한다.
      ports {
        protocol = "TCP"
        port     = "5601"
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

    # GKE metadata 경로(#102) — repository-gcs의 WI 토큰 교환이 의존.
    # Dataplane V2용 .254:80과 Calico link-local proxy 987/988 모두 허용
    # (#126/#127 교훈, vault-k8s와 동일).
    egress {
      to {
        ip_block {
          cidr = "169.254.169.254/32"
        }
      }

      ports {
        protocol = "TCP"
        port     = "80"
      }
    }

    egress {
      to {
        ip_block {
          cidr = "169.254.169.252/32"
        }
      }

      ports {
        protocol = "TCP"
        port     = "987"
      }

      ports {
        protocol = "TCP"
        port     = "988"
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

# #293 oauth2-proxy 전용 egress. Google OAuth(accounts.google.com,
# *.googleapis.com)는 고정 CIDR로 관리할 수 없어 443을 0.0.0.0/0으로 연다
# (argocd-egress git 규칙과 동일 판단). elastic-egress(전체 pod)에 넣지 않고
# proxy pod만 selector로 잡아 ES/Kibana에는 인터넷 egress를 주지 않는다(최소권한).
# DNS·same-ns 등 나머지 egress는 elastic-egress가 이 pod에도 additive로 적용된다.
resource "kubernetes_network_policy_v1" "kibana_oauth_proxy_egress" {
  metadata {
    name      = "kibana-oauth-proxy-egress"
    namespace = kubernetes_namespace_v1.elastic.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "kibana-oauth-proxy"
      }
    }

    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
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
