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
    expected_launcher_image = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher@sha256:5df85dc4f4c66f2503310dd610005fa180a80ad86bfc20575bff5bb86dce4e41"
    expected_executor_image = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:49f15d54b3cdb15c22912364b0b89bd457fa3fcdeee132a952bebb0908344625"
    # DB bootstrap은 launcher image가 아니라 API image로 실행한다.
    # `agent_orchestration/bootstrap_secrets.py`는 애플리케이션 저장소 최상위
    # 모듈인데 launcher.Dockerfile이 이를 COPY하지 않아 launcher image에 없다.
    expected_bootstrap_image = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-api@sha256:4d7d156cd08d1e5ebfa0c0283026d72ea7504dfaa40aa837edc917627b107c24"

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
      "ORCH_EXECUTOR_SERVICE_ACCOUNT" => "experiment-job",
      "ORCH_EXECUTOR_NODE_POOL" => "batch-od",
      "ORCH_TRAINING_DATASET_URI" =>
        "gs://autoresearch-503903-autoresearch-dev-experiment-results/training-snapshots/by-hash/d3d273e66324042cd8e547068c194231cf1812d53cb68236edba56b067055293/",
      "ORCH_TRAINING_TIMEOUT_SEC" => "1800",
      "ORCH_TRAINING_DOWNLOAD_TIMEOUT_SEC" => "600",
      "ORCH_UV_SYNC_TIMEOUT_SEC" => "900",
      "ORCH_GITHUB_APP_SECRET_NAME" => "autoresearch-experiment-branch-writer-app",
      "ORCH_GITHUB_REPOSITORY" => "SKYAHO/Autoresearch",
      "ORCH_MAX_CONCURRENT_EXPERIMENTS" => "2",
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
      # 3600은 어드미션 계약의 activeDeadlineSeconds 상한과 같은 값이다. 이 값을
      # 넘기면 launcher는 기동하지만 어드미션이 Job을 거부하고 실패가 launcher
      # 로그에만 남아, 조용히 아무 Job도 만들어지지 않는다. Codex 상한은 Job 전체
      # 상한보다 작아야 하며(작지 않으면 launcher가 기동 시 거부한다) 나머지
      # 시간은 clone·검증·push가 쓴다.
      "ORCH_ACTIVE_DEADLINE_SEC" => "3600",
      "ORCH_CODEX_TIMEOUT_SEC" => "1800",
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
