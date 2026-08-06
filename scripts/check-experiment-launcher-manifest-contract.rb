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
  end

  def check_cron_job!(cron_job)
    expected_launcher_image = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher@sha256:44ca561e7cd8f6df7b00c6a6d7c1d7ee971107d3e3234e5eb02086c90ca57cc7"
    expected_executor_image = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:fe0002e097ac750c90a083519cc6ac86420e84a44c1aa7aa6c7d0ff9120b707c"
    # DB bootstrap은 launcher image가 아니라 API image로 실행한다.
    # `agent_orchestration/bootstrap_secrets.py`는 애플리케이션 저장소 최상위
    # 모듈인데 launcher.Dockerfile이 이를 COPY하지 않아 launcher image에 없다.
    expected_bootstrap_image = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-api@sha256:36507859b830032aedaa7a6fbf1b77e69466ceec7b56af084dc694e21c51ecde"

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
      "ORCH_GITHUB_APP_SECRET_NAME" => "autoresearch-experiment-branch-writer-app",
      "ORCH_GITHUB_REPOSITORY" => "SKYAHO/Autoresearch",
      "ORCH_MAX_CONCURRENT_EXPERIMENTS" => "2"
    }
    expected_literals.each do |name, value|
      expect_equal(
        { "name" => name, "value" => value },
        environment.fetch(name),
        name
      )
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
