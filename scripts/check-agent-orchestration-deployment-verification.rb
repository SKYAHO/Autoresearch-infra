#!/usr/bin/env ruby
# frozen_string_literal: true

# ArgoCD PostSync verifier가 최소권한·불변 endpoint 계약을 지키는지 검사한다.
require "yaml"

module AgentOrchestrationDeploymentVerification
  ROOT = File.expand_path("..", __dir__)
  PATH = File.join(ROOT, "deploy/agent-orchestration/deployment-verification-job.yaml")
  class ContractError < StandardError; end
  module_function

  def check!(path = PATH)
    documents = YAML.load_stream(File.read(path)).compact
    raise ContractError, "verifier manifest는 Job 한 개만 포함해야 합니다" unless documents.length == 1

    job = documents.first
    raise ContractError, "PostSync verifier Job이 없습니다" unless job["kind"] == "Job"
    annotations = job.dig("metadata", "annotations") || {}
    raise ContractError, "PostSync hook이 아닙니다" unless annotations["argocd.argoproj.io/hook"] == "PostSync"
    spec = job.dig("spec", "template", "spec") || {}
    raise ContractError, "Kubernetes API token mount가 금지됩니다" unless spec["automountServiceAccountToken"] == false
    raise ContractError, "전용 ServiceAccount를 지정할 수 없습니다" if spec.key?("serviceAccountName")
    raise ContractError, "verifier는 volume을 사용할 수 없습니다" unless (spec["volumes"] || []).empty?
    raise ContractError, "검증 Job restartPolicy가 Never가 아닙니다" unless spec["restartPolicy"] == "Never"
    containers = spec["containers"] || []
    raise ContractError, "verifier는 verify container 하나만 가져야 합니다" unless containers.map { |item| item["name"] } == ["verify"]
    raise ContractError, "initContainer를 둘 수 없습니다" unless (spec["initContainers"] || []).empty?

    container = containers.first
    raise ContractError, "검증 image는 digest로 고정해야 합니다" unless container["image"].to_s.match?(/@sha256:[0-9a-f]{64}$/)
    source = (container["command"] || []).last.to_s
    raise ContractError, "candidate endpoint 검증이 없습니다" unless source.include?("/internal/executor/experiments/{experiment_id}/candidate")
    raise ContractError, "verifier는 환경변수를 가질 수 없습니다" unless (container["env"] || []).empty?
    raise ContractError, "verifier는 Secret envFrom을 가질 수 없습니다" unless (container["envFrom"] || []).empty?
    raise ContractError, "verifier는 volumeMount를 가질 수 없습니다" unless (container["volumeMounts"] || []).empty?

    api_path = File.join(ROOT, "deploy/agent-orchestration/api-deployment.yaml")
    api_documents = YAML.load_stream(File.read(api_path)).compact
    api_deployment = api_documents.find { |document| document["kind"] == "Deployment" }
    api_container = (api_deployment&.dig("spec", "template", "spec", "containers") || []).find do |item|
      item["name"] == "api"
    end
    raise ContractError, "API Deployment의 api container가 없습니다" unless api_container
    unless container["image"] == api_container["image"]
      raise ContractError, "verifier image는 API image digest와 일치해야 합니다"
    end
  end
end

AgentOrchestrationDeploymentVerification.check!
puts "Agent Orchestration deployment verification contract: passed"
