#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 1 launcher CronJob의 실행 좌표와 전용 egress 경계를 실제 YAML 객체로 검증한다.
require "ipaddr"
require "json"
require "yaml"

module ExperimentLauncherManifestContract
  REPOSITORY_ROOT = File.expand_path("..", __dir__)
  MANIFEST_PATH = File.join(
    REPOSITORY_ROOT,
    "deploy",
    "agent-orchestration",
    "launcher-cronjob.yaml"
  )
  ENVIRONMENT_PATH = File.join(
    REPOSITORY_ROOT,
    "config",
    "environments",
    "dev",
    "environment.yaml"
  )
  PRIVATE_GOOGLEAPIS_CIDR = "199.36.153.8/30"

  class ContractError < StandardError; end

  module_function

  def check!(repository_root = REPOSITORY_ROOT)
    manifest_path = File.join(
      repository_root,
      "deploy",
      "agent-orchestration",
      "launcher-cronjob.yaml"
    )
    environment_path = File.join(
      repository_root,
      "config",
      "environments",
      "dev",
      "environment.yaml"
    )
    raise ContractError, "launcher CronJob manifest가 없습니다" unless File.file?(manifest_path)
    raise ContractError, "dev 환경 카탈로그가 없습니다" unless File.file?(environment_path)

    documents = YAML.load_stream(File.read(manifest_path)).compact
    cron_job = documents.find { |document| document["kind"] == "CronJob" }
    network_policy = documents.find { |document| document["kind"] == "NetworkPolicy" }
    raise ContractError, "CronJob 문서가 없습니다" unless cron_job
    raise ContractError, "launcher NetworkPolicy 문서가 없습니다" unless network_policy

    check_cron_job!(cron_job)
    check_network_policy!(
      network_policy,
      cron_job.dig("spec", "jobTemplate", "spec", "template"),
      YAML.safe_load(File.read(environment_path))
    )
    check_image_digest_consistency!(File.dirname(manifest_path))
    check_api_executor_token!(File.dirname(manifest_path))
    check_log_collector_contract!(File.dirname(manifest_path), cron_job)
  end

  # (#616) 수집기 Deployment와 launcher CronJob이 공유하는 두 계약을 고정한다.
  # 둘 다 지금까지 주석으로만 있었고, 이 저장소는 "한쪽만 갱신되어 조용히 어긋나는"
  # 실패를 이미 겪었다(#562).
  #
  # 특히 두 번째 검사가 노리는 것은 #579의 임시 TTL 3600을 기본값 30으로 회수하는
  # 변경이다. 그 PR은 launcher-cronjob.yaml만 건드릴 가능성이 높은데, 그때 수집기의
  # 주기가 그대로면 마지막 컨테이너의 꼬리 청크를 flush할 창이 사라진다.
  def check_log_collector_contract!(manifest_directory, cron_job)
    path = File.join(manifest_directory, "log-collector-deployment.yaml")
    # 수집기 배포 전에는 이 파일이 없다. 없는 것은 위반이 아니다.
    return unless File.file?(path)

    deployment = YAML.load_stream(File.read(path)).compact.find do |document|
      document["kind"] == "Deployment"
    end
    raise ContractError, "수집기 Deployment 문서가 없습니다" unless deployment

    collector = pod_environment(deployment.dig("spec", "template", "spec", "containers"))
    launcher = pod_environment(
      cron_job.dig("spec", "jobTemplate", "spec", "template", "spec", "containers")
    )

    expect_equal(
      launcher["ORCH_JOB_NAMESPACE"],
      collector["ORCH_JOB_NAMESPACE"],
      "수집 대상 namespace(갈리면 수집기가 조용히 빈 결과만 남깁니다)"
    )

    # launcher가 값을 생략하면 앱 기본값 30이 적용된다(launcher/config.py).
    ttl = Integer(launcher.fetch("ORCH_TTL_AFTER_FINISHED_SEC", "30"))
    interval = Integer(collector.fetch("ORCH_LOG_COLLECT_INTERVAL_SEC", "5"))
    return if interval < ttl

    raise ContractError,
          "ORCH_LOG_COLLECT_INTERVAL_SEC(#{interval})는 " \
          "ORCH_TTL_AFTER_FINISHED_SEC(#{ttl})보다 작아야 합니다. 완료 Job이 " \
          "회수되기 전에 마지막 컨테이너의 꼬리 청크를 flush할 창이 필요합니다."
  end

  # container 배열에서 `name: value` 환경 변수만 뽑는다. valueFrom(secretKeyRef)은
  # 값이 manifest에 없으므로 비교 대상이 아니다.
  def pod_environment(containers)
    Array(containers).flat_map { |container| Array(container["env"]) }
                     .reject { |entry| entry["value"].nil? }
                     .to_h { |entry| [entry.fetch("name"), entry.fetch("value").to_s] }
  end

  # (#575) candidate 보고 인증은 발신·수신 양쪽이 같은 token을 가져야 성립한다.
  # 발신 측 candidate-finalizer는 executor namespace Secret을 파일로 mount하고,
  # 수신 측 API는 자기 namespace 사본을 환경 변수로 읽는다. 이 검사는 후자의
  # 참조 형태만 고정한다 — 값도, 두 사본의 동일성도 검사 대상이 아니다(그건
  # 운영 절차와 smoke가 확인한다).
  #
  # 이 참조가 없으면 새 API image가 startup에서 죽고, Service는 candidate
  # endpoint가 없는 직전 Pod만 Ready로 유지한다. 그 상태는 배포가 "성공한 것처럼"
  # 보이므로 정적 검사로 잡는다.
  def check_api_executor_token!(manifest_directory)
    path = File.join(manifest_directory, "api-deployment.yaml")
    raise ContractError, "API Deployment manifest가 없습니다" unless File.file?(path)

    deployment = YAML.load_stream(File.read(path)).compact.find do |document|
      document["kind"] == "Deployment"
    end
    raise ContractError, "API Deployment 문서가 없습니다" unless deployment

    containers = deployment.dig("spec", "template", "spec", "containers") || []
    entry = containers
      .flat_map { |container| container["env"] || [] }
      .find { |item| item["name"] == "ORCH_EXECUTOR_API_TOKEN" }

    unless entry
      raise ContractError,
            "API Deployment에 ORCH_EXECUTOR_API_TOKEN env가 없습니다. " \
            "새 API image는 이 값을 필수로 읽어 startup에서 실패합니다."
    end

    expect_equal(
      { "name" => "autoresearch-experiment-executor-api-token", "key" => "token" },
      entry.dig("valueFrom", "secretKeyRef"),
      "ORCH_EXECUTOR_API_TOKEN Secret 참조"
    )

    # envFrom은 Secret에 key가 추가될 때 그것까지 API 환경으로 흘려보낸다.
    containers.each do |container|
      next unless container["envFrom"]

      raise ContractError,
            "API Deployment는 envFrom을 사용할 수 없습니다(단일 key secretKeyRef만 허용)."
    end
  end

  # (#566) 같은 애플리케이션 이미지를 여러 manifest가 참조하는데, 승격에서 일부만
  # 갱신되면 서로 다른 커밋의 이미지가 한 배포에 섞인다. #562에서 실제로 발생했다 —
  # launcher만 갱신하고 api-migration-job(ArgoCD PreSync hook)을 놓쳐, 마이그레이션이
  # 옛 이미지로 실행되면서 새 launcher가 없는 컬럼을 조회해 매분 죽었다.
  #
  # 이 검사는 "어느 digest가 옳은가"를 알지 못한다. `deploy/agent-orchestration/`의
  # 모든 manifest에서 같은 이미지 이름이 같은 digest를 가리키는지만 본다. 정본
  # digest는 위 check_cron_job!의 기대값이 고정한다.
  def check_image_digest_consistency!(manifest_directory)
    digests = Hash.new { |store, key| store[key] = {} }

    Dir.glob(File.join(manifest_directory, "*.yaml")).sort.each do |path|
      YAML.load_stream(File.read(path)).compact.each do |document|
        collect_images(document).each do |image|
          repository, digest = image.split("@", 2)
          next if digest.nil?

          digests[repository][digest] ||= []
          digests[repository][digest] << File.basename(path)
        end
      end
    end

    digests.each do |repository, by_digest|
      next if by_digest.size <= 1

      detail = by_digest.map do |digest, files|
        "#{digest[0, 19]}… → #{files.uniq.sort.join(', ')}"
      end
      raise ContractError,
            "#{File.basename(repository)} 이미지가 manifest마다 다른 digest를 " \
            "가리킵니다(#{detail.join(' / ')}). 승격은 참조 전체를 함께 갱신합니다."
    end
  end

  # container·initContainer 어디에 있든 image 필드를 모은다. Job/CronJob/Deployment의
  # podSpec 깊이가 달라 구조를 가정하지 않고 재귀로 훑는다.
  def collect_images(node)
    case node
    when Hash
      images = node["image"].is_a?(String) ? [node["image"]] : []
      images + node.values.flat_map { |value| collect_images(value) }
    when Array
      node.flat_map { |value| collect_images(value) }
    else
      []
    end
  end

  def check_cron_job!(cron_job)
    expected_launcher_image = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher@sha256:d6aa767ae052a1499275fc631c926b89b48cbed73d3d0c0ef33fe491fbf6008e"
    expected_executor_image = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:0604c56e2a51e690860bb2e33089b4fa3abd9d898f84d7ce94a31369720e9ee8"
    # DB bootstrap은 launcher image가 아니라 API image로 실행한다.
    # `agent_orchestration/bootstrap_secrets.py`는 애플리케이션 저장소 최상위
    # 모듈인데 launcher.Dockerfile이 이를 COPY하지 않아 launcher image에 없다.
    expected_bootstrap_image = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-api@sha256:136a6c692b2347dfafdf76c0b62d5ec59ca9848965c76630f139928b299e7e53"

    spec = cron_job.fetch("spec")
    expect_equal("* * * * *", spec["schedule"], "launcher schedule")
    expect_equal("Forbid", spec["concurrencyPolicy"], "launcher concurrencyPolicy")
    expect_equal(60, spec["startingDeadlineSeconds"], "launcher startingDeadlineSeconds")
    expect_equal(1, spec["successfulJobsHistoryLimit"], "launcher 성공 history")
    expect_equal(3, spec["failedJobsHistoryLimit"], "launcher 실패 history")

    job_spec = spec.dig("jobTemplate", "spec")
    expect_equal(0, job_spec&.fetch("backoffLimit"), "launcher backoffLimit")
    pod_template = job_spec.dig("template")
    pod_spec = pod_template&.fetch("spec")
    expect_equal(
      "agent-orchestration-launcher",
      pod_spec&.fetch("serviceAccountName"),
      "launcher KSA"
    )
    expect_equal(true, pod_spec["automountServiceAccountToken"], "launcher KSA token")
    expect_equal("Never", pod_spec["restartPolicy"], "launcher restartPolicy")

    init_containers = pod_spec.fetch("initContainers")
    containers = pod_spec.fetch("containers")
    expect_equal(["bootstrap-db"], init_containers.map { |item| item["name"] }, "launcher initContainer")
    expect_equal(["launcher"], containers.map { |item| item["name"] }, "launcher app container")
    expect_equal(expected_bootstrap_image, init_containers.first["image"], "launcher bootstrap image")
    expect_equal(expected_launcher_image, containers.first["image"], "launcher image")

    environment = containers.first.fetch("env").to_h { |item| [item.fetch("name"), item] }
    expected_literals = {
      "ORCH_JOB_NAMESPACE" => "autoresearch-experiments",
      "ORCH_EXECUTOR_IMAGE" => expected_executor_image,
      # (#604) 값이 없으면 executor가 results_root_unset 경고만 남기고 측정 산출물을
      # Pod와 함께 잃는다. 기존 objectCreator IAM과 executor의
      # if_generation_match=0 precondition이 write-once 경계를 이루므로 새 IAM 없이
      # 이 root만 launcher가 executor Job에 전달한다.
      "ORCH_EXPERIMENT_RESULTS_ROOT" =>
        "gs://autoresearch-503903-autoresearch-dev-experiment-results",
      "ORCH_EXECUTOR_SERVICE_ACCOUNT" => "experiment-job",
      "ORCH_EXECUTOR_NODE_POOL" => "batch-od",
      "ORCH_TRAINING_DATASET_URI" =>
        "gs://autoresearch-503903-autoresearch-dev-experiment-results/training-snapshots/by-hash/d3d273e66324042cd8e547068c194231cf1812d53cb68236edba56b067055293/",
      "ORCH_TRAINING_TIMEOUT_SEC" => "1800",
      "ORCH_TRAINING_DOWNLOAD_TIMEOUT_SEC" => "600",
      "ORCH_UV_SYNC_TIMEOUT_SEC" => "900",
      # (#599) 값이 빠지거나 틀리면 mlflow가 Pod 로컬 file store로 조용히 fallback해
      # run이 Pod과 함께 사라진다. 학습은 그대로 성공하고 exit 0으로 끝나므로 사유
      # 코드도 로그도 남지 않는다 — 정적으로 잡아야 하는 부류다. executor egress가
      # 이 좌표만 따로 열어 두므로 host·port를 바꾸면 정책도 함께 고쳐야 한다.
      "ORCH_MLFLOW_TRACKING_URI" => "http://mlflow.mlflow.svc.cluster.local:5000",
      "ORCH_GITHUB_APP_SECRET_NAME" => "autoresearch-experiment-branch-writer-app",
      "ORCH_GITHUB_REPOSITORY" => "SKYAHO/Autoresearch",
      # (#624) namespace ResourceQuota의 hard ceiling(Jobs/Pods 5, requests
      # 5 CPU/10Gi)과 같은 값이다. launcher는 Job을 만들기 전에 DB 상태를 먼저
      # RUNNING으로 바꾸므로, 이 값이 quota보다 크면 Job 없는 RUNNING 실험이
      # 남는다. quota를 낮추는 변경은 이 값을 먼저 낮춘 뒤에만 한다.
      "ORCH_MAX_CONCURRENT_EXPERIMENTS" => "5",
      # (#562) Phase 2 좌표. launcher/config.py의 from_environment()가 아래를 모두
      # _required_environment로 읽으므로, 하나라도 빠지면 launcher가 기동 즉시
      # 죽고 실험이 0건이 된다. 두 Secret 이름은 어드미션 계약이 volume의
      # secretName으로 고정하는 값과 같아야 하고, workspace 상한은 계약이 문자열로
      # 비교하므로 표기까지 같아야 한다.
      "ORCH_EXECUTOR_API_URL" =>
        "http://agent-orchestration-api.autoresearch.svc.cluster.local:8000",
      "ORCH_EXECUTOR_API_TOKEN_SECRET_NAME" =>
        "autoresearch-experiment-executor-api-token",
      "ORCH_CODEX_HOME_SECRET_NAME" => "autoresearch-experiment-codex-auth",
      "ORCH_EXECUTOR_WORKSPACE_SIZE_LIMIT" => "8Gi",
      # 60000은 어드미션 계약의 activeDeadlineSeconds 상한과 같은 값이다. 이 값을
      # 넘기면 launcher는 기동하지만 어드미션이 Job을 거부하고 실패가 launcher
      # 로그에만 남아, 조용히 아무 Job도 만들어지지 않는다. Codex 상한은 Job 전체
      # 상한보다 작아야 하며(작지 않으면 launcher가 기동 시 거부한다) 나머지
      # 시간은 Stage 1 채점·clone·검증·push가 쓴다.
      "ORCH_ACTIVE_DEADLINE_SEC" => "60000",
      "ORCH_CODEX_TIMEOUT_SEC" => "6000",
      # (#579) 장애 smoke 동안 완료 Job/Pod event를 조사할 시간을 확보한다.
      # end-to-end 성공 증거 수집 후 애플리케이션 기본값 30으로 회수한다.
      "ORCH_TTL_AFTER_FINISHED_SEC" => "3600"
    }
    expected_literals.each do |name, value|
      entry = environment[name]
      raise ContractError, "#{name} env가 없습니다" unless entry

      expect_equal(
        { "name" => name, "value" => value },
        entry,
        name
      )
    end
    check_timeout_values!(environment)
    if environment.key?("ORCH_TRAINING_DATASET_PATH")
      raise ContractError, "구식 ORCH_TRAINING_DATASET_PATH는 사용할 수 없습니다"
    end

    {
      "ORCH_GITHUB_APP_ID" => "app-id",
      "ORCH_GITHUB_APP_INSTALLATION_ID" => "installation-id"
    }.each do |name, key|
      expect_equal(
        {
          "name" => "autoresearch-experiment-branch-writer-app",
          "key" => key
        },
        environment.dig(name, "valueFrom", "secretKeyRef"),
        "#{name} Secret 참조"
      )
    end
  end

  # Codex timeout은 8개 container 각각에 적용되는 Pod 상한이 아니다. executor의
  # codex-worker 한 container가 한 번 실행하는 단일 `codex exec` subprocess의 상한이며,
  # active deadline은 Job 전체 상한이다. exact literal 검사만 두면 두 값의 관계를
  # 바꾼 뒤 launcher가 기동 시 실패하는 경로를 이 저장소에서 설명할 수 없으므로, 숫자
  # 관계와 admission 상한도 별도로 계산한다.
  def check_timeout_values!(environment)
    active_deadline = parse_positive_timeout!(environment, "ORCH_ACTIVE_DEADLINE_SEC")
    codex_timeout = parse_positive_timeout!(environment, "ORCH_CODEX_TIMEOUT_SEC")
    raise ContractError, "Codex timeout은 active deadline보다 작아야 합니다" unless codex_timeout < active_deadline
    raise ContractError, "active deadline은 60000초 이하여야 합니다" unless active_deadline <= 60000
  end

  def parse_positive_timeout!(environment, name)
    value = environment.dig(name, "value")
    parsed = Integer(value, 10)
    raise ArgumentError if parsed < 1

    parsed
  rescue ArgumentError, TypeError
    raise ContractError, "#{name}은 양의 정수여야 합니다"
  end

  def check_network_policy!(network_policy, pod_template, environment)
    labels = pod_template.dig("metadata", "labels")
    expected_labels = {
      "app.kubernetes.io/name" => "agent-orchestration-launcher",
      "app.kubernetes.io/part-of" => "agent-orchestration",
      "app.kubernetes.io/component" => "launcher"
    }
    expect_equal(expected_labels, labels, "launcher NetworkPolicy label")
    expect_equal(
      labels,
      network_policy.dig("spec", "podSelector", "matchLabels"),
      "launcher NetworkPolicy selector"
    )
    expect_equal(["Egress"], network_policy.dig("spec", "policyTypes"), "launcher policyTypes")

    egress = network_policy.dig("spec", "egress") || []
    if egress.any? do |rule|
      rule.fetch("to", []).any? do |destination|
        destination.dig("ipBlock", "cidr") == "0.0.0.0/0"
      end
    end
      raise ContractError, "launcher 공개 인터넷 egress(0.0.0.0/0)는 금지됩니다"
    end

    expected = expected_egress(environment)
    expect_equal(
      normalize_egress(expected),
      normalize_egress(egress),
      "launcher egress 전체 경계"
    )
  end

  def expected_egress(environment)
    private_services_cidr = environment.dig("network", "private_services_cidr")
    services_cidr = environment.dig("gke", "services_cidr")
    master_cidr = environment.dig("gke", "master_ipv4_cidr")
    [private_services_cidr, services_cidr, master_cidr].each do |cidr|
      raise ContractError, "환경 카탈로그 CIDR이 누락됐습니다" unless cidr

      IPAddr.new(cidr)
    rescue IPAddr::InvalidAddressError
      raise ContractError, "환경 카탈로그 CIDR이 유효하지 않습니다: #{cidr.inspect}"
    end
    kubernetes_service_vip = "#{IPAddr.new(services_cidr).succ}/32"

    [
      ip_rule(private_services_cidr, [port("TCP", 5432)]),
      ip_rule(services_cidr, [port("UDP", 53), port("TCP", 53)]),
      {
        "to" => [{
          "namespaceSelector" => {
            "matchLabels" => { "kubernetes.io/metadata.name" => "kube-system" }
          }
        }],
        "ports" => [port("UDP", 53), port("TCP", 53)]
      },
      ip_rule("169.254.169.254/32", [port("TCP", 80)]),
      ip_rule("169.254.169.252/32", [port("TCP", 987), port("TCP", 988)]),
      ip_rule(PRIVATE_GOOGLEAPIS_CIDR, [port("TCP", 443)]),
      {
        "to" => [
          { "ipBlock" => { "cidr" => kubernetes_service_vip } },
          { "ipBlock" => { "cidr" => master_cidr } }
        ],
        "ports" => [port("TCP", 443)]
      }
    ]
  end

  def ip_rule(cidr, ports)
    {
      "to" => [{ "ipBlock" => { "cidr" => cidr } }],
      "ports" => ports
    }
  end

  def port(protocol, number)
    { "protocol" => protocol, "port" => number }
  end

  def normalize_egress(rules)
    rules.flat_map do |rule|
      destinations = rule.key?("to") ? rule.fetch("to") : [{ "allDestinations" => true }]
      ports = rule.key?("ports") ? rule.fetch("ports") : [{ "allPorts" => true }]
      destinations.product(ports).map do |destination, network_port|
        normalized_port = network_port.dup
        normalized_port["protocol"] ||= "TCP" unless normalized_port.key?("allPorts")
        [canonical(destination), canonical(normalized_port)]
      end
    end.sort_by { |entry| JSON.generate(entry) }
  end

  def canonical(value)
    case value
    when Hash
      value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
    when Array
      value.map { |item| canonical(item) }.sort_by { |item| JSON.generate(item) }
    else
      value
    end
  end

  def expect_equal(expected, actual, description)
    return if expected == actual

    raise ContractError, "#{description} 불일치: 기대=#{expected.inspect}, 실제=#{actual.inspect}"
  end
end

if $PROGRAM_NAME == __FILE__
  ExperimentLauncherManifestContract.check!
  puts "Experiment launcher manifest contract: passed"
end
