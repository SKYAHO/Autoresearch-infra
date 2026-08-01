#!/usr/bin/env ruby
# frozen_string_literal: true

# Timeout ConfigMap·immutable image 계약 checker의 부정 mutation 회귀 테스트입니다.
require "fileutils"
require "tmpdir"

require_relative "check-agent-orchestration-timeout-contract"

AgentOrchestrationTimeoutContract.self_test!

annotation_block = <<-ANNOTATION
      annotations:
        autoresearch.io/codex-runner-timeout-sec: "120"
ANNOTATION

%w[api-deployment.yaml runner-deployment.yaml].each do |filename|
  Dir.mktmpdir("agent-orchestration-timeout-annotation-") do |temporary_root|
    deploy_root = File.join(temporary_root, "deploy")
    FileUtils.mkdir_p(deploy_root)
    FileUtils.cp_r(AgentOrchestrationTimeoutContract::DEPLOY_DIRECTORY, deploy_root)
    deployment_path = File.join(deploy_root, "agent-orchestration", filename)
    File.write(deployment_path, File.read(deployment_path).sub(annotation_block, ""))

    begin
      AgentOrchestrationTimeoutContract.check!(temporary_root)
    rescue AgentOrchestrationTimeoutContract::ContractError
      next
    end
    raise "#{filename} pod template timeout annotation 누락을 감지하지 못했습니다"
  end
end

Dir.mktmpdir("agent-orchestration-timeout-config-map-") do |temporary_root|
  deploy_root = File.join(temporary_root, "deploy")
  FileUtils.mkdir_p(deploy_root)
  FileUtils.cp_r(AgentOrchestrationTimeoutContract::DEPLOY_DIRECTORY, deploy_root)
  config_map_path = File.join(
    deploy_root,
    "agent-orchestration",
    "runner-timeout-config-map.yaml"
  )
  mutation = File.read(config_map_path).sub(
    "#{AgentOrchestrationTimeoutContract::TIMEOUT_ENV_NAME}: \"120\"",
    "#{AgentOrchestrationTimeoutContract::TIMEOUT_ENV_NAME}: \"121\""
  )
  File.write(config_map_path, mutation)

  begin
    AgentOrchestrationTimeoutContract.check!(temporary_root)
  rescue AgentOrchestrationTimeoutContract::ContractError => error
    next if error.message.include?("pod template timeout annotation")

    raise "ConfigMap value mutation이 annotation 계약보다 먼저 실패했습니다: #{error.message}"
  end
  raise "ConfigMap value와 pod template annotation 불일치를 감지하지 못했습니다"
end

Dir.mktmpdir("agent-orchestration-api-image-contract-") do |temporary_root|
  deploy_root = File.join(temporary_root, "deploy")
  FileUtils.mkdir_p(deploy_root)
  FileUtils.cp_r(AgentOrchestrationTimeoutContract::DEPLOY_DIRECTORY, deploy_root)
  api_path = File.join(deploy_root, "agent-orchestration", "api-deployment.yaml")
  runner_path = File.join(deploy_root, "agent-orchestration", "runner-deployment.yaml")
  api_image = AgentOrchestrationTimeoutContract.deployment(api_path).dig(
    "spec", "template", "spec", "containers", 0, "image"
  )
  runner_image = AgentOrchestrationTimeoutContract.deployment(runner_path).dig(
    "spec", "template", "spec", "containers", 0, "image"
  )
  File.write(runner_path, File.read(runner_path).sub(api_image, runner_image))

  begin
    AgentOrchestrationTimeoutContract.check!(temporary_root)
  rescue AgentOrchestrationTimeoutContract::ContractError
    next
  end
  raise "Runner bootstrap API image 불일치를 감지하지 못했습니다"
end

puts "Agent Orchestration deployment contract self-test: passed"
