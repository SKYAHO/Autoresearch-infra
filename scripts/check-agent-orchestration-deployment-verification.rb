#!/usr/bin/env ruby
# frozen_string_literal: true

# ArgoCD PostSync verifier의 최소권한·NetworkPolicy·image 정합성 계약을 검사한다.
require "yaml"

module AgentOrchestrationDeploymentVerification
  ROOT = File.expand_path("..", __dir__)
  DEPLOY_DIRECTORY = File.join(ROOT, "deploy", "agent-orchestration")
  VERIFIER_LABELS = {
    "app.kubernetes.io/name" => "agent-orchestration-deployment-verification",
    "app.kubernetes.io/part-of" => "agent-orchestration",
    "app.kubernetes.io/component" => "deployment-verifier"
  }.freeze
  API_LABELS = {
    "app.kubernetes.io/component" => "api",
    "app.kubernetes.io/part-of" => "agent-orchestration"
  }.freeze

  class ContractError < StandardError; end
  module_function

  def documents(path)
    YAML.load_stream(File.read(path)).compact
  end

  def check!(repository_root = ROOT)
    deploy_directory = File.join(repository_root, "deploy", "agent-orchestration")
    job_path = File.join(deploy_directory, "deployment-verification-job.yaml")
    policy_path = File.join(deploy_directory, "network-policy.yaml")
    environment_path = File.join(repository_root, "config/environments/dev/environment.yaml")
    raise ContractError, "verifier Job manifest가 없습니다" unless File.file?(job_path)
    raise ContractError, "verifier NetworkPolicy manifest가 없습니다" unless File.file?(policy_path)
    raise ContractError, "dev 환경 카탈로그가 없습니다" unless File.file?(environment_path)

    job_documents = documents(job_path)
    raise ContractError, "verifier manifest는 Job 한 개만 포함해야 합니다" unless job_documents.length == 1

    job = job_documents.first
    container = check_job!(job)
    check_api_image!(container, deploy_directory)
    environment = YAML.safe_load(File.read(environment_path))
    check_network_policies!(documents(policy_path), job, environment)
  end

  def check_job!(job)
    raise ContractError, "PostSync verifier Job이 없습니다" unless job["kind"] == "Job"
    raise ContractError, "verifier namespace는 autoresearch여야 합니다" unless job.dig("metadata", "namespace") == "autoresearch"
    annotations = job.dig("metadata", "annotations") || {}
    raise ContractError, "PostSync hook이 아닙니다" unless annotations["argocd.argoproj.io/hook"] == "PostSync"
    raise ContractError, "hook delete policy가 다릅니다" unless annotations["argocd.argoproj.io/hook-delete-policy"] == "BeforeHookCreation,HookSucceeded"
    raise ContractError, "verifier label이 다릅니다" unless job.dig("spec", "template", "metadata", "labels") == VERIFIER_LABELS

    spec = job.dig("spec", "template", "spec") || {}
    raise ContractError, "verifier backoffLimit은 1이어야 합니다" unless job.dig("spec", "backoffLimit") == 1
    raise ContractError, "verifier deadline은 300초여야 합니다" unless job.dig("spec", "activeDeadlineSeconds") == 300
    raise ContractError, "Kubernetes API token mount가 금지됩니다" unless spec["automountServiceAccountToken"] == false
    raise ContractError, "전용 ServiceAccount를 지정할 수 없습니다" if spec.key?("serviceAccountName")
    raise ContractError, "verifier는 volume을 사용할 수 없습니다" unless (spec["volumes"] || []).empty?
    raise ContractError, "검증 Job restartPolicy가 Never가 아닙니다" unless spec["restartPolicy"] == "Never"
    raise ContractError, "initContainer를 둘 수 없습니다" unless (spec["initContainers"] || []).empty?
    raise ContractError, "Pod seccomp가 RuntimeDefault가 아닙니다" unless spec.dig("securityContext", "seccompProfile", "type") == "RuntimeDefault"

    containers = spec["containers"] || []
    raise ContractError, "verifier는 verify container 하나만 가져야 합니다" unless containers.map { |item| item["name"] } == ["verify"]
    container = containers.first
    raise ContractError, "검증 image는 digest로 고정해야 합니다" unless container["image"].to_s.match?(/@sha256:[0-9a-f]{64}$/)
    source = (container["command"] || []).last.to_s
    raise ContractError, "candidate endpoint 검증이 없습니다" unless source.include?("/internal/executor/experiments/{experiment_id}/candidate")
    unless source.include?("http://agent-orchestration-api.autoresearch.svc.cluster.local:8000/")
      raise ContractError, "probe 대상은 NetworkPolicy가 허용한 API Service TCP 8000이어야 합니다"
    end
    raise ContractError, "probe 내부 deadline은 150초여야 합니다" unless source.include?("time.monotonic() + 150")
    raise ContractError, "verifier는 환경변수를 가질 수 없습니다" unless (container["env"] || []).empty?
    raise ContractError, "verifier는 Secret envFrom을 가질 수 없습니다" unless (container["envFrom"] || []).empty?
    raise ContractError, "verifier는 volumeMount를 가질 수 없습니다" unless (container["volumeMounts"] || []).empty?
    security = container["securityContext"] || {}
    raise ContractError, "verifier는 root 실행이 금지됩니다" unless security["runAsNonRoot"] == true
    raise ContractError, "verifier 실행 UID가 다릅니다" unless security["runAsUser"] == 10_001
    raise ContractError, "verifier 실행 GID가 다릅니다" unless security["runAsGroup"] == 10_001
    raise ContractError, "verifier root filesystem은 read-only여야 합니다" unless security["readOnlyRootFilesystem"] == true
    raise ContractError, "verifier privilege escalation이 금지됩니다" unless security["allowPrivilegeEscalation"] == false
    raise ContractError, "verifier capability는 모두 drop해야 합니다" unless security.dig("capabilities", "drop") == ["ALL"]
    container
  end

  def check_api_image!(container, deploy_directory)
    deployment = documents(File.join(deploy_directory, "api-deployment.yaml")).find { |document| document["kind"] == "Deployment" }
    api_container = (deployment&.dig("spec", "template", "spec", "containers") || []).find { |item| item["name"] == "api" }
    raise ContractError, "API Deployment의 api container가 없습니다" unless api_container
    raise ContractError, "verifier image는 API image digest와 일치해야 합니다" unless container["image"] == api_container["image"]
  end

  def check_network_policies!(policy_documents, job, environment)
    services_cidr = environment.dig("gke", "services_cidr")
    raise ContractError, "환경 카탈로그 services CIDR이 없습니다" unless services_cidr
    policies = policy_documents.select { |document| document["kind"] == "NetworkPolicy" }
    verifier = policies.find { |policy| policy.dig("metadata", "name") == "agent-orchestration-deployment-verifier" }
    api = policies.find { |policy| policy.dig("metadata", "name") == "agent-orchestration-api-egress" }
    raise ContractError, "verifier NetworkPolicy가 없습니다" unless verifier
    raise ContractError, "API NetworkPolicy가 없습니다" unless api

    labels = job.dig("spec", "template", "metadata", "labels")
    raise ContractError, "verifier selector가 Job label과 다릅니다" unless verifier.dig("spec", "podSelector", "matchLabels") == labels
    raise ContractError, "verifier ingress/egress default-deny가 아닙니다" unless verifier.dig("spec", "policyTypes") == ["Ingress", "Egress"] && verifier.dig("spec", "ingress") == []

    expected_egress = [
      {
        "to" => [
          { "ipBlock" => { "cidr" => services_cidr } },
          { "podSelector" => { "matchLabels" => API_LABELS } }
        ],
        "ports" => [{ "protocol" => "TCP", "port" => 8000 }]
      },
      {
        "to" => [{ "ipBlock" => { "cidr" => services_cidr } }],
        "ports" => [{ "protocol" => "UDP", "port" => 53 }, { "protocol" => "TCP", "port" => 53 }]
      },
      {
        "to" => [{ "namespaceSelector" => { "matchLabels" => { "kubernetes.io/metadata.name" => "kube-system" } } }],
        "ports" => [{ "protocol" => "UDP", "port" => 53 }, { "protocol" => "TCP", "port" => 53 }]
      }
    ]
    unless verifier.dig("spec", "egress") == expected_egress
      raise ContractError, "verifier egress가 API TCP 8000과 DNS만 허용하지 않습니다"
    end

    allowed = (api.dig("spec", "ingress") || []).any? do |rule|
      rule["from"] == [{ "podSelector" => { "matchLabels" => labels } }] &&
        rule["ports"] == [{ "protocol" => "TCP", "port" => 8000 }]
    end
    raise ContractError, "API ingress에 verifier TCP 8000 허용이 없습니다" unless allowed

    api_ingress = api.dig("spec", "ingress") || []
    unless api_ingress.length == 4
      raise ContractError, "API ingress는 UI, node probe, verifier, executor 4개여야 합니다"
    end

    executor_ingress = {
      "from" => [{
        "namespaceSelector" => {
          "matchLabels" => { "kubernetes.io/metadata.name" => "autoresearch-experiments" }
        },
        "podSelector" => {
          "matchLabels" => { "app.kubernetes.io/component" => "experiment-executor" }
        }
      }],
      "ports" => [{ "protocol" => "TCP", "port" => 8000 }]
    }
    unless api_ingress.count { |rule| rule == executor_ingress } == 1
      raise ContractError,
            "API ingress는 autoresearch-experiments의 experiment-executor에 TCP 8000만 허용해야 합니다"
    end

  end
end

if $PROGRAM_NAME == __FILE__
  AgentOrchestrationDeploymentVerification.check!
  puts "Agent Orchestration deployment verification contract: passed"
end
