#!/usr/bin/env ruby
# frozen_string_literal: true
require "fileutils"
require "tmpdir"
require "yaml"
require_relative "check-agent-orchestration-deployment-verification"

def expect_failure
  Dir.mktmpdir("deployment-verifier-contract-") do |directory|
    FileUtils.mkdir_p(File.join(directory, "deploy"))
    FileUtils.mkdir_p(File.join(directory, "config", "environments", "dev"))
    FileUtils.cp_r(AgentOrchestrationDeploymentVerification::DEPLOY_DIRECTORY, File.join(directory, "deploy"))
    FileUtils.cp(
      File.join(AgentOrchestrationDeploymentVerification::ROOT, "config/environments/dev/environment.yaml"),
      File.join(directory, "config/environments/dev/environment.yaml")
    )
    yield directory
    begin
      AgentOrchestrationDeploymentVerification.check!(directory)
    rescue AgentOrchestrationDeploymentVerification::ContractError
      next
    end
    raise "위험한 verifier mutation을 감지하지 못했습니다"
  end
end

def mutate_job(directory)
  path = File.join(directory, "deploy/agent-orchestration/deployment-verification-job.yaml")
  document = YAML.load_file(path)
  yield document
  File.write(path, document.to_yaml)
end

def mutate_policies(directory)
  path = File.join(directory, "deploy/agent-orchestration/network-policy.yaml")
  documents = YAML.load_stream(File.read(path)).compact
  yield documents
  File.write(path, documents.map(&:to_yaml).join("---\n"))
end

expect_failure { |root| mutate_job(root) { |job| job.dig("spec", "template", "spec")["automountServiceAccountToken"] = true } }
expect_failure { |root| mutate_job(root) { |job| job.dig("metadata")["namespace"] = "default" } }
expect_failure { |root| mutate_job(root) { |job| job.dig("metadata", "annotations")["argocd.argoproj.io/hook"] = "Sync" } }
expect_failure { |root| mutate_job(root) { |job| job.dig("spec")["backoffLimit"] = 0 } }
expect_failure { |root| mutate_job(root) { |job| job.dig("spec", "template", "spec")["serviceAccountName"] = "privileged" } }
expect_failure { |root| mutate_job(root) { |job| job.dig("spec", "template", "spec")["volumes"] = [{ "name" => "secret" }] } }
expect_failure { |root| mutate_job(root) { |job| job.dig("spec", "template", "spec")["containers"][0]["image"] = "api:latest" } }
expect_failure { |root| mutate_job(root) { |job| job.dig("spec", "template", "spec")["containers"][0]["image"] = "registry/api@sha256:#{'0' * 64}" } }
expect_failure { |root| mutate_job(root) { |job| job.dig("spec", "template", "spec")["containers"][0]["envFrom"] = [{ "secretRef" => { "name" => "secret" } }] } }
expect_failure { |root| mutate_job(root) { |job| job.dig("spec", "template", "spec")["containers"][0]["volumeMounts"] = [{ "name" => "secret", "mountPath" => "/secret" }] } }
expect_failure { |root| mutate_job(root) { |job| job.dig("spec", "template", "spec")["containers"][0]["command"][-1] = "raise SystemExit(0)" } }
expect_failure { |root| mutate_job(root) { |job| job.dig("spec", "template", "spec")["containers"][0]["securityContext"]["runAsNonRoot"] = false } }
expect_failure do |root|
  mutate_policies(root) { |documents| documents.reject! { |document| document.dig("metadata", "name") == "agent-orchestration-deployment-verifier" } }
end
expect_failure do |root|
  mutate_policies(root) do |documents|
    api = documents.find { |document| document.dig("metadata", "name") == "agent-orchestration-api-egress" }
    api.dig("spec", "ingress").reject! do |rule|
      rule["from"]&.first&.dig("podSelector", "matchLabels", "app.kubernetes.io/component") == "deployment-verifier"
    end
  end
end
expect_failure do |root|
  mutate_policies(root) do |documents|
    verifier = documents.find { |document| document.dig("metadata", "name") == "agent-orchestration-deployment-verifier" }
    verifier.dig("spec", "egress") << { "to" => [{ "ipBlock" => { "cidr" => "0.0.0.0/0" } }], "ports" => [{ "protocol" => "TCP", "port" => 443 }] }
  end
end
expect_failure do |root|
  path = File.join(root, "config/environments/dev/environment.yaml")
  environment = YAML.safe_load(File.read(path))
  environment["gke"]["services_cidr"] = "172.16.129.0/24"
  File.write(path, environment.to_yaml)
end
puts "Agent Orchestration deployment verification contract self-test: passed"
