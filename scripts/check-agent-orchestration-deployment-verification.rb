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
    job = YAML.load_file(path)
    raise ContractError, "PostSync verifier Job이 없습니다" unless job["kind"] == "Job"
    annotations = job.dig("metadata", "annotations") || {}
    raise ContractError, "PostSync hook이 아닙니다" unless annotations["argocd.argoproj.io/hook"] == "PostSync"
    spec = job.dig("spec", "template", "spec") || {}
    raise ContractError, "Kubernetes API token mount가 금지됩니다" unless spec["automountServiceAccountToken"] == false
    raise ContractError, "검증 Job restartPolicy가 Never가 아닙니다" unless spec["restartPolicy"] == "Never"
    container = (spec["containers"] || []).find { |item| item["name"] == "verify" }
    raise ContractError, "verify container가 없습니다" unless container
    raise ContractError, "검증 image는 digest로 고정해야 합니다" unless container["image"].to_s.match?(/@sha256:[0-9a-f]{64}$/)
    source = (container["command"] || []).last.to_s
    raise ContractError, "candidate endpoint 검증이 없습니다" unless source.include?("/internal/executor/experiments/{experiment_id}/candidate")
    raise ContractError, "verifier는 Secret env를 가질 수 없습니다" unless (container["env"] || []).empty?
  end
end

AgentOrchestrationDeploymentVerification.check!
puts "Agent Orchestration deployment verification contract: passed"
