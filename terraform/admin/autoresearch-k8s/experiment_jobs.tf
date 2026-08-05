# Auto Research 실험은 기존 앱·Agent Orchestration namespace와 분리한다. Job 생성
# 권한이 있는 API가 임의 Pod 사양을 만들 수 있는 위험을 줄이기 위해 Pod Security,
# quota, LimitRange, NetworkPolicy와 전용 KSA를 한 경계에서 함께 관리한다.
resource "kubernetes_namespace_v1" "experiment_jobs" {
  metadata {
    name = var.experiment_job_namespace
    labels = {
      "app.kubernetes.io/name"             = "autoresearch-experiments"
      "app.kubernetes.io/part-of"          = "auto-research"
      "pod-security.kubernetes.io/enforce" = "restricted"
      # 현재 live GKE control plane v1.35를 기준으로 고정한다. 다음 마이너
      # 업그레이드 전에는 runbook의 PSA dry-run과 Job image 호환성을 확인한 뒤
      # 의도적으로 이 값을 올린다.
      "pod-security.kubernetes.io/enforce-version" = "v1.35"
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/audit-version"   = "latest"
      "pod-security.kubernetes.io/warn"            = "restricted"
      "pod-security.kubernetes.io/warn-version"    = "latest"
    }
  }
}

# GKE metadata server는 source Pod identity와 KSA annotation으로 Workload Identity를
# 교환하므로 Kubernetes API token을 컨테이너에 마운트할 필요가 없다. 저신뢰 에이전트에
# 불필요한 Kubernetes 자격 증명을 노출하지 않기 위해 명시적으로 비활성화한다.
resource "kubernetes_service_account_v1" "experiment_job" {
  metadata {
    name      = var.experiment_job_k8s_service_account
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = local.experiment_job_gcp_service_account_email
    }
  }

  automount_service_account_token = false
}

# 실험은 일반 앱 pool이 아니라 batch-od pool에 고정한다. 이 pool은 #297 대응으로
# 만들었지만 Autoresearch-airflow의 어떤 KPO도 현재 이 pool로 스케줄되지 않는다
# (#523) — 유휴 상태이므로 별도 경합 계획 없이 실험 Job이 그대로 쓴다. 다른
# 컴포넌트가 이 pool을 실제로 쓰기 시작하면 그 변경에서 capacity·우선순위 계획을
# 다시 승인한다. quota는 pool의
# e2-standard-2 두 노드(min 0/max 2)에서 각각 한 Job이 안정적으로 실행되는
# 보수적 상한이다. 완료 Job도 TTL 전에는 quota에 포함되므로 무한 재시도·대량 제출로
# batch 비용이 늘어나는 경로를 차단한다.
resource "kubernetes_resource_quota_v1" "experiment_jobs" {
  metadata {
    name      = "experiment-jobs-quota"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  spec {
    hard = {
      "count/jobs.batch" = "2"
      "pods"             = "2"
      "requests.cpu"     = "2"
      "requests.memory"  = "4Gi"
      "limits.cpu"       = "2"
      "limits.memory"    = "4Gi"
    }
  }

  depends_on = [kubernetes_namespace_v1.experiment_jobs]
}

resource "kubernetes_limit_range_v1" "experiment_jobs" {
  metadata {
    name      = "experiment-jobs-limits"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "500m"
        memory = "1Gi"
      }
      default_request = {
        cpu    = "500m"
        memory = "1Gi"
      }
      max = {
        cpu    = "1"
        memory = "2Gi"
      }
    }

    # Pod 합계 상한. 컨테이너별 상한(위)만으로는 컨테이너 여러 개짜리 Pod가
    # 총합으로 노드 allocatable을 넘겨 Pod 생성까지는 통과하고 스케줄만
    # deadline+TTL까지 Pending으로 묶여 `pods`/`requests.cpu` quota를 점유하는
    # 경로가 열린다(#523). 이 상한은 그 Pod 생성 자체를 LimitRange가 막아
    # `FailedCreate` 이벤트로 즉시 드러내고 해당 quota 소비를 없앤다 — Job
    # `create` 자체(ValidatingAdmissionPolicy)는 이 값을 검사하지 않으므로
    # 여전히 성공한다. 값은 문서가 명시한 단일 컨테이너 계약과 동일해 현재 고정
    # 템플릿에는 영향이 없다.
    limit {
      type = "Pod"
      max = {
        cpu    = "1"
        memory = "2Gi"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.experiment_jobs]
}

# API는 Job·Pod 상태와 log만 읽는다. Secret·exec·ServiceAccount·Role 수정 권한은
# 의도적으로 포함하지 않는다.
resource "kubernetes_role_v1" "experiment_job_observer" {
  metadata {
    name      = "experiment-job-observer"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }

  # ImagePullBackOff·FailedScheduling·Job Pod 생성 quota 초과의 상세 원인은 Event에
  # 남는다. namespace 범위의 읽기 전용으로만 허용하며, API는 자기 실험 ID의
  # involvedObject만 사용자 상태에 연결해야 한다.
  rule {
    api_groups = ["", "events.k8s.io"]
    resources  = ["events"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "experiment_job_observer" {
  metadata {
    name      = "experiment-job-observer"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.experiment_job_observer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.agent_orchestration_api.metadata[0].name
    namespace = kubernetes_namespace_v1.autoresearch.metadata[0].name
  }
}

# Kubernetes RBAC만으로는 Job 내부 image·volume·환경 변수를 제한할 수 없다. 따라서
# 이 Role은 고정 템플릿·허용 digest·admission 검증이 앱/클러스터에 적용됐다는 별도
# 검토가 끝날 때까지 기본 false로 유지한다.
resource "kubernetes_role_v1" "experiment_job_creator" {
  for_each = var.enable_experiment_job_creation ? toset(["enabled"]) : toset([])

  metadata {
    name      = "experiment-job-creator"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding_v1" "experiment_job_creator" {
  for_each = var.enable_experiment_job_creation ? toset(["enabled"]) : toset([])

  metadata {
    name      = "experiment-job-creator"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.experiment_job_creator[each.key].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.agent_orchestration_api.metadata[0].name
    namespace = kubernetes_namespace_v1.autoresearch.metadata[0].name
  }
}

# API KSA가 손상돼도 Job create 권한만으로 실행 신원·이미지·스케줄 위치를 바꾸지
# 못하도록 Kubernetes API 서버에서 거부한다. 이 정책은 create 권한을 기본 false로
# 두는 것과 별개인 방어 심층화이며, 활성화 전제조건의 서버 측 강제 소유자는 이 root다.
resource "kubernetes_manifest" "experiment_job_admission_policy" {
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicy"
    metadata = {
      name = "autoresearch-experiment-job-contract"
    }
    spec = {
      failurePolicy = "Fail"
      matchConstraints = {
        resourceRules = [{
          apiGroups   = ["batch"]
          apiVersions = ["v1"]
          operations  = ["CREATE", "UPDATE"]
          resources   = ["jobs"]
          scope       = "Namespaced"
        }]
      }
      validations = [
        # Job의 pod template에는 serviceAccountName defaulting이 적용되지 않는다
        # (Pod 오브젝트와 달리 실측상 필드가 그대로 비어 온다). 가드 없이 비교하면
        # 누락 Job이 CEL 런타임 오류로만 거부돼 사유가 드러나지 않으므로 명시한다.
        {
          expression = "has(object.spec.template.spec.serviceAccountName) && object.spec.template.spec.serviceAccountName == '${var.experiment_job_k8s_service_account}'"
          message    = "실험 Job은 승인된 serviceAccountName을 명시해야 합니다."
        },
        # initContainers도 같은 Pod에서 같은 KSA로 실행돼 metadata server로 GSA
        # token을 얻고 egress allowlist도 동일하므로, containers만 검사하면
        # mutable tag 이미지를 initContainers에 넣어 digest 고정을 우회할 수 있다.
        # ephemeralContainers는 PodTemplateSpec에서 API 서버가 금지하므로 대상 밖.
        # 미설정 list는 has() 가드로, 빈 list는 all()이 true라 양쪽 다 통과한다.
        {
          expression = "object.spec.template.spec.containers.all(c, c.image.matches('^.+@sha256:[a-f0-9]{64}$')) && (!has(object.spec.template.spec.initContainers) || object.spec.template.spec.initContainers.all(c, c.image.matches('^.+@sha256:[a-f0-9]{64}$')))"
          message    = "실험 Job의 모든 컨테이너(initContainers 포함) 이미지는 sha256 digest로 고정해야 합니다."
        },
        # digest 고정은 불변성만 보장한다. 출처까지 막지 않으면
        # docker.io/library/x@sha256:... 같은 임의 외부 이미지가 통과하고, pull은
        # kubelet이 노드에서 하므로 pod egress NetworkPolicy로도 차단되지 않는다
        # (batch-od 노드는 Cloud NAT로 외부 registry 도달 가능).
        {
          expression = "object.spec.template.spec.containers.all(c, ${jsonencode(local.experiment_job_allowed_image_prefixes)}.exists(p, c.image.startsWith(p))) && (!has(object.spec.template.spec.initContainers) || object.spec.template.spec.initContainers.all(c, ${jsonencode(local.experiment_job_allowed_image_prefixes)}.exists(p, c.image.startsWith(p))))"
          message    = "실험 Job 이미지는 승인된 Artifact Registry 저장소에서만 가져올 수 있습니다."
        },
        # 필드를 아예 빼고 제출한 Job도 거부되어야 한다. 가드 없이 인덱싱하면
        # 거부는 되지만 "CEL 런타임 오류 → failurePolicy Fail"이라는 우회적 경로라
        # 의도한 동작인지 코드에서 드러나지 않는다. has()/in으로 명시해 누락 거부를
        # 규칙 자체로 표현하고, 메시지도 정확한 사유를 남기게 한다.
        {
          expression = "has(object.spec.template.spec.nodeSelector) && 'cloud.google.com/gke-nodepool' in object.spec.template.spec.nodeSelector && object.spec.template.spec.nodeSelector['cloud.google.com/gke-nodepool'] == '${var.experiment_job_node_pool}'"
          message    = "실험 Job은 nodeSelector로 batch-od node pool을 명시해야 합니다."
        },
        # all()만으로는 빈 목록(tolerations: [])이 통과한다 — CEL에서 빈 list의
        # all()은 true다. 그 Job은 batch-od taint를 못 넘어 Pending으로 남았다가
        # activeDeadlineSeconds로만 정리돼 최대 (deadline+TTL)만큼 quota를 잡는다.
        # size()==1로 "승인된 toleration 정확히 하나"를 강제해 runbook 서술과 맞춘다.
        # Job 오브젝트는 Pod가 아니라 DefaultTolerationSeconds admission의 대상이
        # 아니므로, 제출한 template이 그대로 평가된다.
        # operator는 Job pod template에서 defaulting되지 않는다(실측: Pod와 달리
        # `operator: Equal`이 채워지지 않고 필드가 비어 온다). Kubernetes 의미상
        # 빈 operator는 Equal이므로, runbook 표기 그대로 `workload=batch-od:NoSchedule`
        # 를 operator 없이 쓴 Job이 거부되지 않도록 미설정을 Equal로 취급한다.
        # key/value/effect는 has()로 명시 요구해 누락 사유가 메시지로 드러나게 한다.
        {
          expression = "has(object.spec.template.spec.tolerations) && object.spec.template.spec.tolerations.size() == 1 && object.spec.template.spec.tolerations.all(t, has(t.key) && t.key == 'workload' && (!has(t.operator) || t.operator == 'Equal') && has(t.value) && t.value == '${var.experiment_job_node_pool}' && has(t.effect) && t.effect == 'NoSchedule')"
          message    = "실험 Job은 workload=batch-od:NoSchedule toleration 하나만 사용해야 합니다."
        },
        # quota 회수의 서버 측 강제. 이 root는 API KSA에 delete를 주지 않고
        # enable_experiment_job_creation=false 롤백도 실행 중 Job을 멈추지 않으므로,
        # 두 필드가 없으면 count/jobs.batch=2가 영구 점유돼 회수 경로가 break-glass
        # 관리자 권한밖에 남지 않는다. 상한 3600초는 runbook의 Job 계약과 같은 값이다.
        # KSA의 automount_service_account_token=false는 Pod spec이 되돌릴 수 있는
        # "기본값"일 뿐이고 Pod Security restricted도 이 필드를 통제하지 않는다.
        # 손상된 API가 template에서 true로 덮어쓰는 경로를 서버에서 닫는다.
        {
          expression = "!has(object.spec.template.spec.automountServiceAccountToken) || object.spec.template.spec.automountServiceAccountToken == false"
          message    = "실험 Job은 ServiceAccount token을 mount할 수 없습니다."
        },
        # suspend: true로 제출된 Job은 Pod를 만들지 않고 activeDeadlineSeconds
        # 타이머도 돌지 않는다(suspend 시 status.startTime이 리셋된다). TTL은
        # Complete/Failed Job에만 적용되므로, 아래 두 시간 검증을 모두 만족하면서도
        # count/jobs.batch 슬롯을 무기한 점유하는 Job이 만들어진다. 손상된 API를
        # 가정하는 이 정책의 위협 모델에서는 Job 2개만으로 실험 실행이 영구 정지된다.
        {
          expression = "!has(object.spec.suspend) || object.spec.suspend == false"
          message    = "실험 Job은 suspend 상태로 제출할 수 없습니다."
        },
        {
          expression = "has(object.spec.activeDeadlineSeconds) && object.spec.activeDeadlineSeconds > 0 && object.spec.activeDeadlineSeconds <= 3600"
          message    = "실험 Job은 activeDeadlineSeconds를 1~3600초로 명시해야 합니다."
        },
        {
          expression = "has(object.spec.ttlSecondsAfterFinished) && object.spec.ttlSecondsAfterFinished >= 0 && object.spec.ttlSecondsAfterFinished <= 3600"
          message    = "실험 Job은 ttlSecondsAfterFinished를 0~3600초로 명시해야 합니다."
        },
      ]
    }
  }
}

resource "kubernetes_manifest" "experiment_job_admission_policy_binding" {
  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicyBinding"
    metadata = {
      name = "autoresearch-experiment-job-contract"
    }
    spec = {
      policyName        = kubernetes_manifest.experiment_job_admission_policy.manifest.metadata.name
      validationActions = ["Deny"]
      matchResources = {
        namespaceSelector = {
          matchLabels = {
            "kubernetes.io/metadata.name" = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
          }
        }
      }
    }
  }
}

# 실험 Job에는 inbound traffic이 필요 없다.
resource "kubernetes_network_policy_v1" "experiment_jobs_ingress" {
  metadata {
    name      = "experiment-jobs-ingress"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

# 기본 egress를 차단하고 DNS, Workload Identity metadata, 결과 GCS 업로드용
# Private Google Access만 허용한다. Redis·Cloud SQL·MLflow·외부 HTTPS는 이 MVP에
# 포함하지 않는다.
resource "kubernetes_network_policy_v1" "experiment_jobs_egress" {
  metadata {
    name      = "experiment-jobs-egress"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

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
    }

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }

        pod_selector {
          match_labels = {
            "k8s-app" = "kube-dns"
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

    egress {
      to {
        ip_block {
          cidr = var.private_googleapis_cidr
        }
      }

      ports {
        protocol = "TCP"
        port     = "443"
      }
    }
  }

  depends_on = [kubernetes_namespace_v1.experiment_jobs]
}
