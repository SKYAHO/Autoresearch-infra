#!/usr/bin/env ruby
# frozen_string_literal: true

# Agent Orchestration API·Runner의 timeout 및 immutable image 계약을 검증한다.
# Ruby 표준 라이브러리 Psych로 YAML 객체를 읽어 외부 Python 의존성 없이 실행한다.
# API와 OAuth Runner가 같은 ConfigMap key를 참조하고, Runner Codex timeout 110초 및
# 공통 Runner HTTP timeout 120초, API image 다섯 container 참조의 동등한 digest pin을 검사한다.

require "fileutils"
require "tmpdir"
require "yaml"

module AgentOrchestrationTimeoutContract
  REPOSITORY_ROOT = File.expand_path("..", __dir__)
  DEPLOY_DIRECTORY = File.join(REPOSITORY_ROOT, "deploy", "agent-orchestration")
  TIMEOUT_CONFIG_MAP_NAME = "agent-orchestration-runner-timeout"
  TIMEOUT_ENV_NAME = "CODEX_RUNNER_TIMEOUT_SEC"
  TIMEOUT_VALUE = "120"
  TIMEOUT_TEMPLATE_ANNOTATION = "autoresearch.io/codex-runner-timeout-sec"

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
    config_map_data = config_map.fetch("data")
    timeout_value = config_map_data.fetch(TIMEOUT_ENV_NAME)
    expect_equal(
      { TIMEOUT_ENV_NAME => timeout_value },
      config_map_data,
      "timeout ConfigMap data"
    )

    api_deployment = deployment(File.join(deploy_directory, "api-deployment.yaml"))
    runner_deployment = deployment(File.join(deploy_directory, "runner-deployment.yaml"))
    migration_job = job(File.join(deploy_directory, "api-migration-job.yaml"))
    check_image_reference_contract!(api_deployment, runner_deployment, migration_job)
    check_deployment_reference!(deploy_directory, "api-deployment.yaml", timeout_value)
    runner_environment = check_deployment_reference!(
      deploy_directory,
      "runner-deployment.yaml",
      timeout_value
    )
    expect_equal(TIMEOUT_VALUE, timeout_value, "timeout ConfigMap data")
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

  def check_deployment_reference!(deploy_directory, filename, timeout_value)
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
    pod_template_annotations = deployment_document.dig(
      "spec",
      "template",
      "metadata",
      "annotations"
    ) || {}
    expect_equal(
      timeout_value,
      pod_template_annotations.fetch(TIMEOUT_TEMPLATE_ANNOTATION, nil),
      "#{filename} pod template timeout annotation"
    )
    deployment_environment
  end

  def job(path)
    documents(path).find { |document| document.fetch("kind") == "Job" } ||
      raise(ContractError, "Job이 없습니다: #{path}")
  end

  def check_image_reference_contract!(api_deployment, runner_deployment, migration_job)
    api_image = container_image(api_deployment, "containers", "api")
    api_bootstrap_image = container_image(api_deployment, "initContainers", "bootstrap-db")
    runner_bootstrap_image = container_image(
      runner_deployment,
      "initContainers",
      "bootstrap-codex-auth"
    )
    runner_image = container_image(runner_deployment, "containers", "runner")
    migration_bootstrap_image = container_image(migration_job, "initContainers", "bootstrap-db")
    migration_image = container_image(migration_job, "containers", "migrate")

    {
      "API container image" => api_image,
      "API DB bootstrap image" => api_bootstrap_image,
      "Runner Codex auth bootstrap image" => runner_bootstrap_image,
      "Migration DB bootstrap image" => migration_bootstrap_image,
      "Migration container image" => migration_image,
      "Runner container image" => runner_image
    }.each do |description, image|
      unless image.match?(%r{\A.+@sha256:[0-9a-f]{64}\z})
        raise ContractError, "#{description}는 immutable digest여야 합니다: #{image.inspect}"
      end
    end

    expect_equal(api_image, api_bootstrap_image, "API DB bootstrap image")
    expect_equal(api_image, runner_bootstrap_image, "Runner Codex auth bootstrap API image")
    expect_equal(api_image, migration_bootstrap_image, "Migration DB bootstrap API image")
    expect_equal(api_image, migration_image, "Migration container API image")
  end

  def container_image(deployment_document, section, container_name)
    containers = deployment_document.dig("spec", "template", "spec", section) || []
    container = containers.find { |item| item.fetch("name") == container_name }
    raise ContractError, "#{section}에 #{container_name} container가 없습니다" unless container

    container.fetch("image")
  end

  def expect_equal(expected, actual, description)
    return if expected == actual

    raise ContractError, "#{description} 불일치: 기대=#{expected.inspect}, 실제=#{actual.inspect}"
  end
end

if $PROGRAM_NAME == __FILE__
  AgentOrchestrationTimeoutContract.check!
  puts "Agent Orchestration deployment contract: Codex=110, shared Runner HTTP=120"
end
