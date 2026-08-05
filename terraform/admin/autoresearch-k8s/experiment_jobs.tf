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
    # 여전히 성공하고, `count/jobs.batch` quota는 이 상한과 무관하게 평소처럼
    # 점유된다.
    #
    # initContainers 계산: k8s는 일반 initContainer(순차 실행)를 app 컨테이너
    # 합계와 max() 비교하므로, initContainer 1개(1 vCPU) + app 컨테이너 1개
    # (1 vCPU)는 max(1,1)=1로 이 상한 경계값에 걸려 통과한다. 반면
    # `restartPolicy: Always`인 native sidecar initContainer는 app 컨테이너와
    # 동시에 떠 있어 합산(sum) 대상이 되므로 같은 조합이 2 vCPU로 상한을
    # 넘겨 거부된다.
    #
    # #539의 branch-bootstrap Job은 정확히 전자에 해당한다 — initContainer
    # `github-token-minter` 1개 + app 컨테이너 `branch-bootstrap` 1개이고,
    # 두 컨테이너 모두 LimitRange 기본값(500m/1Gi)을 받으므로 Pod 합계는
    # max(500m, 500m)=500m, max(1Gi, 1Gi)=1Gi로 상한 안에 들어온다. 다만 이는
    # 여유가 아니라 "sidecar가 아니어서" 통과하는 것이므로, token-minter를
    # native sidecar(`restartPolicy: Always`)로 바꾸는 변경은 이 상한에 먼저
    # 걸린다. 같은 root의 admission 정책이 initContainer·app 컨테이너를 각각
    # 하나로 못 박아 그 이상은 애초에 제출되지 않는다.
    #
    # 헤드룸 0: 이 값을 컨테이너 상한과 동일하게 둬 컨테이너가 하나라도 추가되면
    # (의도적 sidecar든 GCS FUSE CSI 같은 주입형 sidecar든) 무조건 거부된다.
    # 이 namespace에는 현재 sidecar를 주입하는 mutating webhook이 없다 — 값을
    # 올리는 대신 "이 namespace에는 sidecar 주입을 쓰지 않는다"를 제약으로
    # 유지한다. 다중 컨테이너 Pod가 실제로 필요해지면 그 변경에서 상한 값을
    # 함께 재검토한다.
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
# 검토(#523)를 마친 뒤에만 활성화하며, 문제 발생 시 되돌리는 스위치로 유지한다.
#
# #539에서 이 권한의 주체를 API KSA에서 launcher KSA로 옮겼다. API는 사용자 입력을
# 받고 gh CLI를 subprocess로 실행하며 공개 인터넷 443으로 나가는 넓은 표면적의
# 컴포넌트인 반면, launcher는 외부 입력도 인터넷 egress도 없이 1분마다 DB를 읽고
# Job을 만들고 종료하는 단일 목적 CronJob이다. Job 생성 권한은 좁은 쪽이 갖는다.
# API는 상태 조회용 experiment-job-observer만 유지한다.
#
# 동사는 launcher가 실제로 호출하는 세 개뿐이다(계획서는 Pods·Events read도
# 제안했지만 launcher 코드에 해당 호출이 없어 최소 권한으로 뺐다 — 필요해지면 그
# 시점에 추가한다).
#   list   → 실행 중 Job 수를 세어 동시 실행 상한을 지킨다
#   get    → 같은 이름 Job이 이미 있는지 확인해 중복 생성을 막는다
#   create → Job을 제출한다
# delete·update·patch는 주지 않는다. 회수는 activeDeadlineSeconds와 TTL controller가
# 담당한다.
resource "kubernetes_role_v1" "experiment_job_launcher" {
  for_each = var.enable_experiment_job_creation ? toset(["enabled"]) : toset([])

  metadata {
    name      = "experiment-job-launcher"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["create", "get", "list"]
  }
}

# Role은 Job이 존재하는 experiment namespace에 두고, 주체인 KSA는 app namespace에
# 있다. RoleBinding은 권한이 적용될 namespace에 놓이며 subject에 KSA의 namespace를
# 명시한다.
resource "kubernetes_role_binding_v1" "experiment_job_launcher" {
  for_each = var.enable_experiment_job_creation ? toset(["enabled"]) : toset([])

  metadata {
    name      = "experiment-job-launcher"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.experiment_job_launcher[each.key].metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.agent_orchestration_launcher.metadata[0].name
    namespace = kubernetes_namespace_v1.autoresearch.metadata[0].name
  }
}

# Job create 권한을 가진 주체(#539 이후 launcher KSA)가 손상돼도 실행 신원·이미지·
# 스케줄 위치를 바꾸지 못하도록 Kubernetes API 서버에서 거부한다. 이 정책은 create
# 권한 플래그와 별개인 방어 심층화이며, 활성화 전제조건의 서버 측 강제 소유자는 이
# root다. 아래 주석의 "손상된 제출자"는 create 권한을 가진 그 주체를 가리킨다.
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
        # quota 회수의 서버 측 강제. 이 root는 제출자 KSA에 delete를 주지 않고
        # enable_experiment_job_creation=false 롤백도 실행 중 Job을 멈추지 않으므로,
        # 두 필드가 없으면 count/jobs.batch=2가 영구 점유돼 회수 경로가 break-glass
        # 관리자 권한밖에 남지 않는다. 상한 3600초는 runbook의 Job 계약과 같은 값이다.
        # KSA의 automount_service_account_token=false는 Pod spec이 되돌릴 수 있는
        # "기본값"일 뿐이고 Pod Security restricted도 이 필드를 통제하지 않는다.
        # 손상된 제출자가 template에서 true로 덮어쓰는 경로를 서버에서 닫는다.
        {
          expression = "!has(object.spec.template.spec.automountServiceAccountToken) || object.spec.template.spec.automountServiceAccountToken == false"
          message    = "실험 Job은 ServiceAccount token을 mount할 수 없습니다."
        },
        # suspend: true로 제출된 Job은 Pod를 만들지 않고 activeDeadlineSeconds
        # 타이머도 돌지 않는다(suspend 시 status.startTime이 리셋된다). TTL은
        # Complete/Failed Job에만 적용되므로, 아래 두 시간 검증을 모두 만족하면서도
        # count/jobs.batch 슬롯을 무기한 점유하는 Job이 만들어진다. 손상된 제출자를
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
        # ── #539 branch-bootstrap Pod 형태 계약 ──────────────────────────────
        #
        # 위 규칙들은 "누가·어디서·어떤 이미지로" 도는지를 강제한다. 아래 다섯 개는
        # "private key가 어느 컨테이너까지 보이는지"를 강제한다. 이 Phase에서
        # 마운트되는 branch-writer App private key는 `SKYAHO/Autoresearch`의
        # Contents write 권한을 가지므로, 유출 시 저장소에 임의 코드를 push할 수
        # 있다 — 이 namespace가 다루는 시크릿 중 영향 범위가 가장 크다.
        #
        # 설계상 키는 initContainer에서만 보이고, 본 컨테이너는 그 결과물인 1시간
        # 만료 installation token만 받는다. 그 분리를 만드는 것은 애플리케이션
        # 저장소의 launcher 코드(`launcher/jobs.py`)인데, 그 코드는 이 저장소의
        # 리뷰·CI를 거치지 않는다. 따라서 같은 계약을 서버 측에서 한 번 더 강제한다.
        #
        # 주의: 이 정책은 namespace 전체에 바인딩되므로, 아래 이름 고정은 이
        # namespace를 사실상 branch-bootstrap 전용으로 만든다. 다른 형태의 실험
        # Job이 필요해지면 그 변경에서 이 규칙들을 먼저 넓혀야 한다.
        {
          expression = "has(object.spec.template.spec.initContainers) && object.spec.template.spec.initContainers.size() == 1 && object.spec.template.spec.initContainers[0].name == '${local.experiment_branch_bootstrap_init_container}'"
          message    = "실험 Job은 initContainer로 ${local.experiment_branch_bootstrap_init_container} 하나만 사용해야 합니다."
        },
        {
          expression = "object.spec.template.spec.containers.size() == 1 && object.spec.template.spec.containers[0].name == '${local.experiment_branch_bootstrap_app_container}'"
          message    = "실험 Job은 컨테이너로 ${local.experiment_branch_bootstrap_app_container} 하나만 사용해야 합니다."
        },
        # volume 목록 자체를 두 개로 못 박는다. 개수를 열어두면 승인된 두 volume을
        # 그대로 둔 채 hostPath·다른 Secret·PVC를 추가하는 경로가 남는다(Pod
        # Security restricted가 hostPath는 막지만 다른 Secret은 막지 않는다).
        #
        # sizeLimit을 문자열 '1Mi'로 비교하는 것은 Quantity가 제출된 표기를 그대로
        # 보존해 왕복하기 때문이다. 고정 템플릿이 리터럴 "1Mi"를 보내므로 일치하며,
        # 같은 값을 다른 표기(예: "1048576")로 바꾸는 템플릿 변경은 의도적으로
        # 거부된다 — 이 계약은 "값이 같음"이 아니라 "템플릿이 그대로임"을 확인한다.
        {
          expression = "has(object.spec.template.spec.volumes) && object.spec.template.spec.volumes.size() == 2 && object.spec.template.spec.volumes.exists_one(v, v.name == '${local.experiment_branch_writer_key_volume}' && has(v.secret) && has(v.secret.secretName) && v.secret.secretName == '${var.experiment_branch_writer_secret_name}') && object.spec.template.spec.volumes.exists_one(v, v.name == '${local.experiment_branch_token_volume}' && has(v.emptyDir) && has(v.emptyDir.medium) && v.emptyDir.medium == 'Memory' && has(v.emptyDir.sizeLimit) && v.emptyDir.sizeLimit == '1Mi')"
          message    = "실험 Job은 ${var.experiment_branch_writer_secret_name} Secret volume과 medium=Memory 1Mi token volume 두 개만 사용해야 합니다."
        },
        # 이 정책의 핵심 규칙이다. private key volume은 initContainer만, 그것도
        # readOnly로 마운트할 수 있다. 본 컨테이너는 GitHub과 실제로 통신하며 더
        # 오래 사는 쪽이라, 여기가 손상됐을 때 얻는 것이 "만료되는 token"인지
        # "영구 private key"인지가 이 규칙 하나로 갈린다.
        {
          expression = "(!has(object.spec.template.spec.initContainers) || object.spec.template.spec.initContainers.all(c, has(c.volumeMounts) && c.volumeMounts.exists_one(m, m.name == '${local.experiment_branch_writer_key_volume}' && has(m.readOnly) && m.readOnly == true))) && object.spec.template.spec.containers.all(c, !has(c.volumeMounts) || c.volumeMounts.all(m, m.name != '${local.experiment_branch_writer_key_volume}'))"
          message    = "GitHub App private key volume은 initContainer에만 readOnly로 mount해야 하며 본 컨테이너에는 mount할 수 없습니다."
        },
        # volume 계약만으로는 키가 본 컨테이너에 도달하는 경로를 다 막지 못한다.
        # `env[].valueFrom.secretKeyRef`나 `envFrom[].secretRef`는 volume을 전혀
        # 쓰지 않고 Secret 값을 환경 변수로 바로 주입하므로 위 다섯 규칙을 모두
        # 통과한다. Pod Security restricted도 Secret 참조 방식은 통제하지 않는다.
        #
        # Secret 이름만 금지하지 않고 `valueFrom`/`envFrom` 자체를 막는다. 이름
        # 기반 금지는 "다른 이름의 더 강한 권한 Secret"으로 우회되지만, 고정
        # 템플릿은 양쪽 컨테이너 모두 리터럴 `value`만 쓰므로(App ID, installation
        # ID, 파일 경로, 봉인 좌표) 잃는 것이 없다. 시크릿은 오직 initContainer의
        # readOnly volume 하나를 통해서만 Pod에 들어온다.
        {
          expression = "(!has(object.spec.template.spec.initContainers) || object.spec.template.spec.initContainers.all(c, !has(c.envFrom) && (!has(c.env) || c.env.all(e, !has(e.valueFrom))))) && object.spec.template.spec.containers.all(c, !has(c.envFrom) && (!has(c.env) || c.env.all(e, !has(e.valueFrom))))"
          message    = "실험 Job은 환경 변수로 Secret·ConfigMap 값을 주입할 수 없습니다(envFrom과 valueFrom 금지). 시크릿은 승인된 initContainer volume 경로만 사용합니다."
        },
        # Pod template label 고정. 이 규칙이 막는 것은 침해가 아니라 **불일치**다 —
        # GitHub egress를 여는 NetworkPolicy가 이 label로 대상을 고르므로, label이
        # 없는 Job은 admission을 통과해도 api.github.com에 닿지 못해 deadline까지
        # 매달렸다가 timeout으로만 실패한다. 여기서 거부하면 같은 실수가 제출 시점에
        # 명확한 사유로 드러난다. launcher의 동시 실행 계수도 같은 label selector를
        # 쓰므로, label 없는 Job이 자기 계수에서 빠지는 경로도 함께 닫힌다.
        {
          expression = "has(object.spec.template.metadata) && has(object.spec.template.metadata.labels) && 'app.kubernetes.io/component' in object.spec.template.metadata.labels && object.spec.template.metadata.labels['app.kubernetes.io/component'] == '${local.experiment_branch_bootstrap_component_label}'"
          message    = "실험 Job의 Pod template은 app.kubernetes.io/component=${local.experiment_branch_bootstrap_component_label} label을 가져야 합니다."
        },
        # 본 컨테이너는 token을 읽기만 한다. 쓰기 가능하게 마운트되면 컨테이너가
        # 자기 token 파일을 덮어써 initContainer가 만든 자격 증명 경로를 우회할 수
        # 있고, 사후 조사에서 어떤 token이 쓰였는지도 확정할 수 없게 된다.
        {
          expression = "object.spec.template.spec.containers.all(c, has(c.volumeMounts) && c.volumeMounts.exists_one(m, m.name == '${local.experiment_branch_token_volume}' && has(m.readOnly) && m.readOnly == true))"
          message    = "본 컨테이너는 token volume을 readOnly로만 mount해야 합니다."
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

# #539 branch-bootstrap Pod만 api.github.com에 도달해야 한다. 위 정책은 namespace의
# 모든 Pod에 적용되는 기본 경계이고, 이 정책은 그 위에 대상을 좁힌 추가 허용이다 —
# NetworkPolicy는 선택된 Pod에 대해 각 정책의 허용 규칙을 합집합으로 적용하므로,
# 두 정책이 함께 있으면 branch-bootstrap Pod는 "기본 경계 + 공개 443"을 갖고 다른
# Pod는 기본 경계만 갖는다. 이 정책의 `except` 목록은 이 규칙의 대상 범위만 좁힐 뿐
# 위 정책이 이미 허용한 metadata server(169.254.x)를 되돌리지 않는다.
#
# 이 클러스터의 dataplane은 Calico라 GKE Dataplane V2의 `FQDNNetworkPolicy`를 쓸 수
# 없어 `api.github.com`만 지정하는 방법이 없다. GitHub이 게시하는 API 대역은 수시로
# 교체돼 고정하면 예고 없이 브랜치 생성이 깨지므로, 공개 인터넷 443을 열되 사설·
# 링크로컬 대역을 제외하는 방식을 쓴다. 같은 판단이 이미 API Pod(#525)에 적용돼 있다.
#
# 이 정책이 넓히는 범위: branch-bootstrap Pod는 임의 공개 HTTPS 목적지에 도달할 수
# 있다. 그 Pod가 가진 자격 증명은 대상 저장소 Contents write 하나이고 수명은 최대
# activeDeadlineSeconds(현 계약 300초)이며, 사설 대역 목적지(Cloud SQL, Redis,
# in-cluster Service, private Google APIs VIP)는 except로 계속 차단된다.
#
# 예외적으로 이 cluster의 GKE DNS 엔드포인트는 공개 주소라(gke.tf의
# allow_external_traffic=true) 이 규칙의 대상에 들어온다. 실제 도달에는
# container.clusters.connect IAM이 필요하고 이 Pod의 GSA(-exp-job)는 결과 버킷
# objectCreator와 자기 Workload Identity 외에 아무 권한이 없어 접근할 수 없다.
# 공개 IP 엔드포인트 쪽은 master authorized networks가 비어 있어 별도로 막힌다.
# 같은 판단이 API Pod 정책(#525)에도 기록돼 있다.
resource "kubernetes_network_policy_v1" "experiment_jobs_branch_bootstrap_egress" {
  metadata {
    name      = "experiment-jobs-branch-bootstrap-egress"
    namespace = kubernetes_namespace_v1.experiment_jobs.metadata[0].name
  }

  spec {
    # 이 label은 애플리케이션 저장소 `launcher/jobs.py`가 Job과 Pod template 양쪽에
    # 붙인다. label이 없는 Pod는 이 정책의 대상이 아니라 GitHub에 도달하지 못하고
    # 실패한다(fail-closed).
    pod_selector {
      match_labels = {
        "app.kubernetes.io/component" = local.experiment_branch_bootstrap_component_label
      }
    }

    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr   = "0.0.0.0/0"
          except = local.public_egress_private_cidr_exceptions
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
