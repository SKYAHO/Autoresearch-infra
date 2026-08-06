#!/usr/bin/env ruby
# frozen_string_literal: true

# Launcher NetworkPolicy checker가 실제 YAML mutation을 거부하는지 검증한다.
require "fileutils"
require "tmpdir"
require "yaml"

require_relative "check-experiment-launcher-manifest-contract"

module ExperimentLauncherManifestContractTest
  module_function

  def fixture_root
    Dir.mktmpdir("experiment-launcher-manifest-contract-").tap do |root|
      manifest_directory = File.join(root, "deploy", "agent-orchestration")
      catalog_directory = File.join(root, "config", "environments", "dev")
      FileUtils.mkdir_p(manifest_directory)
      FileUtils.mkdir_p(catalog_directory)
      FileUtils.cp(
        ExperimentLauncherManifestContract::MANIFEST_PATH,
        File.join(manifest_directory, "launcher-cronjob.yaml")
      )
      FileUtils.cp(
        ExperimentLauncherManifestContract::ENVIRONMENT_PATH,
        File.join(catalog_directory, "environment.yaml")
      )
    end
  end

  def mutate_policy(root)
    manifest_path = File.join(
      root,
      "deploy",
      "agent-orchestration",
      "launcher-cronjob.yaml"
    )
    documents = YAML.load_stream(File.read(manifest_path)).compact
    policy = documents.find { |document| document["kind"] == "NetworkPolicy" }
    raise "fixture NetworkPolicy가 없습니다" unless policy

    yield policy
    File.write(
      manifest_path,
      documents.map(&:to_yaml).join("---\n")
    )
  end

  def expect_failure(label)
    root = fixture_root
    yield root
    begin
      ExperimentLauncherManifestContract.check!(root)
    rescue ExperimentLauncherManifestContract::ContractError
      return
    ensure
      FileUtils.remove_entry(root) if File.exist?(root)
    end
    raise "#{label} mutation을 감지하지 못했습니다"
  end

  def run!
    ExperimentLauncherManifestContract.check!

    expect_failure("공개 인터넷 egress 추가") do |root|
      mutate_policy(root) do |policy|
        policy.dig("spec", "egress") << {
          "to" => [{ "ipBlock" => { "cidr" => "0.0.0.0/0" } }],
          "ports" => [{ "protocol" => "TCP", "port" => 443 }]
        }
      end
    end

    expect_failure("Cloud SQL 포트 변경") do |root|
      mutate_policy(root) do |policy|
        rule = policy.dig("spec", "egress").find do |item|
          item.dig("to", 0, "ipBlock", "cidr") == "192.168.0.0/20"
        end
        rule.fetch("ports").first["port"] = 3306
      end
    end

    expect_failure("Kubernetes API service VIP 변경") do |root|
      mutate_policy(root) do |policy|
        target = policy.dig("spec", "egress")
          .flat_map { |item| item.fetch("to", []) }
          .find { |item| item.dig("ipBlock", "cidr") == "172.16.128.1/32" }
        target.fetch("ipBlock")["cidr"] = "172.16.128.2/32"
      end
    end

    expect_failure("예상하지 않은 namespaceSelector 추가") do |root|
      mutate_policy(root) do |policy|
        policy.dig("spec", "egress") << {
          "to" => [{
            "namespaceSelector" => {
              "matchLabels" => { "kubernetes.io/metadata.name" => "default" }
            }
          }],
          "ports" => [{ "protocol" => "TCP", "port" => 443 }]
        }
      end
    end

    expect_failure("Secret Manager VIP 삭제") do |root|
      mutate_policy(root) do |policy|
        policy.dig("spec", "egress").reject! do |item|
          item.dig("to", 0, "ipBlock", "cidr") == "199.36.153.8/30"
        end
      end
    end

    expect_failure("환경 카탈로그 services CIDR drift") do |root|
      environment_path = File.join(
        root,
        "config",
        "environments",
        "dev",
        "environment.yaml"
      )
      environment = YAML.safe_load(File.read(environment_path))
      environment.fetch("gke")["services_cidr"] = "172.16.129.0/24"
      File.write(environment_path, environment.to_yaml)
    end
  end
end

ExperimentLauncherManifestContractTest.run!
puts "Experiment launcher manifest contract self-test: passed"
