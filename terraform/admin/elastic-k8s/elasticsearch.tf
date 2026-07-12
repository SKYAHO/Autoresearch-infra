# #98 Elasticsearch 운영형 최소 클러스터. #96 설계:
# single-node(master+data 겸용), heap 1G, PVC 30Gi, TLS/auth는 ECK 기본 유지.
# 이슈 본문의 logging namespace 대신 #96 설계의 elastic namespace를 쓴다.
#
# 주의(부트스트랩 순서): kubernetes_manifest는 plan 시 CRD 스키마를 조회하므로
# 빈 클러스터에서는 operator를 먼저 targeted apply한다(README 재해 복구 절).

resource "kubernetes_manifest" "elasticsearch" {
  manifest = {
    apiVersion = "elasticsearch.k8s.elastic.co/v1"
    kind       = "Elasticsearch"
    metadata = {
      name      = "autoresearch"
      namespace = kubernetes_namespace_v1.elastic.metadata[0].name
    }
    spec = {
      version = var.elasticsearch_version

      # ECK 기본값(DeleteOnScaledownAndClusterDeletion)은 CR 삭제 시 PVC까지
      # 삭제한다 — standard-rwo(reclaimPolicy Delete)와 결합하면 데이터 영구
      # 소실(리뷰 반영). CR 제거 시 PVC를 보존하도록 명시하고, 데이터 정리는
      # README 롤백 절의 수동 단계로만 수행한다.
      volumeClaimDeletePolicy = "DeleteOnScaledownOnly"

      nodeSets = [
        {
          name  = "default"
          count = 1

          config = {
            # mmap 비활성: vm.max_map_count sysctl(privileged initContainer)
            # 요구를 피한다 — PSS baseline 라벨과 충돌하지 않는 dev 최소 구성.
            "node.store.allow_mmap" = false
          }

          podTemplate = {
            spec = {
              # 배치 노드 고정: 여유 메모리 실측(#96)이 dev-default 단일 노드
              # 기준이므로 airflow-dev pool(여유 ~2.5GB)로 흘러가 pressure를
              # 만들지 않게 한다. 전용 node pool은 불필요(#96 — 트리거는
              # headroom 3Gi 미만, #105에서 재검토).
              nodeSelector = {
                "cloud.google.com/gke-nodepool" = "dev-default"
              }

              containers = [
                {
                  name = "elasticsearch"
                  env = [
                    {
                      name  = "ES_JAVA_OPTS"
                      value = "-Xms1g -Xmx1g"
                    },
                  ]
                  resources = {
                    requests = {
                      cpu    = "500m"
                      memory = "2Gi"
                    }
                    limits = {
                      memory = "3Gi"
                    }
                  }
                },
              ]
            }
          }

          volumeClaimTemplates = [
            {
              metadata = {
                name = "elasticsearch-data"
              }
              spec = {
                accessModes = ["ReadWriteOnce"]
                resources = {
                  requests = {
                    storage = "30Gi"
                  }
                }
                # standard(pd-standard, HDD): standard-rwo(pd-balanced)는
                # SSD_TOTAL_GB quota(리전 250GB, 실측 223 사용)를 소비해
                # provisioning이 실패했다(#98 인시던트). dev 로그 워크로드에는
                # HDD IOPS로 충분하고 비용도 더 낮다. SSD 전환은 quota 증설과
                # 함께 별도 검토.
                storageClassName = "standard"
              }
            },
          ]
        },
      ]
    }
  }

  # ECK operator는 이 root가 선언하지 않은 spec 필드의 defaulting
  # (auth/http/tls/monitoring/updateStrategy 등 — managedFields 실측)을 자기
  # field manager(Update)로 소유한다. Terraform(Apply)과 소유 영역이 겹치는
  # 정규화 필드에서 SSA 충돌이 발생하므로(#98 검증) 강제 적용한다. 이
  # root가 선언한 필드(version/nodeSets 내용/volumeClaimDeletePolicy)는
  # operator가 되돌리지 않으므로 ping-pong drift는 없다(수렴 검증 #98 기록).
  field_manager {
    force_conflicts = true
  }

  depends_on = [helm_release.eck_operator]
}
