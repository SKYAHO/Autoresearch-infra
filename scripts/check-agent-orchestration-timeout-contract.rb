#!/usr/bin/env ruby
# frozen_string_literal: true

# Agent Orchestration API와 Runner의 단일 timeout ConfigMap 계약을 검증한다.
# Ruby 표준 라이브러리 Psych로 YAML 객체를 읽어 외부 Python 의존성 없이 실행한다.
# API와 OAuth Runner가 같은 ConfigMap key를 참조하고, Runner Codex timeout 110초 및
# 공통 Runner HTTP timeout 120초가 유지되는지 검사한다.

require "fileutils"
require "tmpdir"
require "yaml"

module AgentOrchestrationTimeoutContract
  REPOSITORY_ROOT = File.expand_path("..", __dir__)
  DEPLOY_DIRECTORY = File.join(REPOSITORY_ROOT, "deploy", "agent-orchestration")
  TIMEOUT_CONFIG_MAP_NAME = "agent-orchestration-runner-timeout"
  TIMEOUT_ENV_NAME = "CODEX_RUNNER_TIMEOUT_SEC"
  TIMEOUT_VALUE = "120"

  class ContractError < StandardError; end

  module_function

  def documents(path)
    YAML.load_stream(File.read(path)).compact
  end

  def deployment(path)
    documents(path).find { |document| document.fetch("kind") == "Deployment" } ||
      raise(ContractError, "Deployment가 없습니다: #{path}")
  end

  def environment(deployment_document)
    container = deployment_document.dig("spec", "template", "spec", "containers", 0)
    raise ContractError, "주 컨테이너가 없습니다" unless container

    container.fetch("env").to_h { |item| [item.fetch("name"), item] }
  end

  def check!(repository_root = REPOSITORY_ROOT)
    deploy_directory = File.join(repository_root, "deploy", "agent-orchestration")
    config_map = documents(File.join(deploy_directory, "runner-timeout-config-map.yaml")).first
    expect_equal("ConfigMap", config_map.fetch("kind"), "timeout manifest kind")
    expect_equal(
      TIMEOUT_CONFIG_MAP_NAME,
      config_map.dig("metadata", "name"),
      "timeout ConfigMap 이름"
    )
    expect_equal(
      { TIMEOUT_ENV_NAME => TIMEOUT_VALUE },
      config_map.fetch("data"),
      "timeout ConfigMap data"
    )

    check_deployment_reference!(deploy_directory, "api-deployment.yaml")
    runner_environment = check_deployment_reference!(deploy_directory, "runner-deployment.yaml")
    expect_equal("110", runner_environment.fetch("CODEX_TIMEOUT_SEC").fetch("value"), "Runner Codex timeout")
  end

  def self_test!
    check!
    Dir.mktmpdir("agent-orchestration-timeout-contract-") do |temporary_root|
      FileUtils.mkdir_p(File.join(temporary_root, "deploy"))
      FileUtils.cp_r(DEPLOY_DIRECTORY, File.join(temporary_root, "deploy"))
      runner_path = File.join(
        temporary_root,
        "deploy",
        "agent-orchestration",
        "runner-deployment.yaml"
      )
      mutation = File.read(runner_path).sub(
        "name: #{TIMEOUT_CONFIG_MAP_NAME}",
        "name: mismatched-timeout-config"
      )
      File.write(runner_path, mutation)

      begin
        check!(temporary_root)
      rescue ContractError
        return
      end
      raise ContractError, "mismatched ConfigMap reference를 감지하지 못했습니다"
    end
  end

  def check_deployment_reference!(deploy_directory, filename)
    deployment_document = deployment(File.join(deploy_directory, filename))
    deployment_environment = environment(deployment_document)
    expected_reference = {
      "name" => TIMEOUT_ENV_NAME,
      "valueFrom" => {
        "configMapKeyRef" => {
          "name" => TIMEOUT_CONFIG_MAP_NAME,
          "key" => TIMEOUT_ENV_NAME
        }
      }
    }
    expect_equal(
      expected_reference,
      deployment_environment.fetch(TIMEOUT_ENV_NAME),
      "#{filename} timeout ConfigMap reference"
    )
    deployment_environment
  end

  def expect_equal(expected, actual, description)
    return if expected == actual

    raise ContractError, "#{description} 불일치: 기대=#{expected.inspect}, 실제=#{actual.inspect}"
  end
end

if $PROGRAM_NAME == __FILE__
  AgentOrchestrationTimeoutContract.check!
  puts "Agent Orchestration timeout contract: Codex=110, shared Runner HTTP=120"
end
