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

    # kubectl port-forward 경로(#116 교훈): 노드 대역 → #293 oauth2-proxy 4180만.
    # Kibana 5601 직접 ingress는 의도적으로 열지 않는다 — anonymous access(#293)가
    # 켜지면 5601 직접 접속이 무인증 viewer가 되어 Google 로그인 게이트를 우회하게
    # 되므로, 사람 접근은 인증 proxy(4180)로만 강제한다. proxy→Kibana(5601)는
    # same-ns pod_selector ingress로 커버되어 영향 없다. operator break-glass로
    # 5601 직접 접근이 필요하면 이 규칙을 임시로 되살린다(README/runbook).
    ingress {
      from {
        ip_block {
          cidr = var.kibana_ingress_source_cidr
        }
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

# #293 oauth2-proxy(google provider)의 서버사이드 Google 호출(token redeem
# oauth2.googleapis.com, JWKS/userinfo www.googleapis.com)은 모두 *.googleapis.com
# 이고, #138 private DNS zone이 이를 private.googleapis.com VIP(199.36.153.8/30)로
# 유도한다. 이 VIP:443은 elastic-egress가 이미 전체 pod에 열어두므로(ES snapshot용)
# proxy 전용 egress 정책은 불필요하다. 로그인 authorize 리다이렉트(accounts.google.com)는
# 사용자 브라우저가 수행하는 client-side라 proxy egress 대상이 아니다.

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
