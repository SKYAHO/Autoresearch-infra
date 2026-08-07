#!/usr/bin/env ruby
# frozen_string_literal: true
require "tmpdir"
require "fileutils"
require "yaml"
require_relative "check-agent-orchestration-deployment-verification"

def expect_failure
  Dir.mktmpdir do |directory|
    path = File.join(directory, "job.yaml")
    document = YAML.load_file(AgentOrchestrationDeploymentVerification::PATH)
    yield document
    File.write(path, document.to_yaml)
    begin
      AgentOrchestrationDeploymentVerification.check!(path)
    rescue AgentOrchestrationDeploymentVerification::ContractError
      next
    end
    raise "위험한 verifier mutation을 감지하지 못했습니다"
  end
end

expect_failure { |job| job.dig("spec", "template", "spec")["automountServiceAccountToken"] = true }
expect_failure { |job| job.dig("spec", "template", "spec")["serviceAccountName"] = "privileged" }
expect_failure { |job| job.dig("spec", "template", "spec")["volumes"] = [{ "name" => "secret" }] }
expect_failure { |job| job.dig("spec", "template", "spec")["containers"][0]["image"] = "api:latest" }
expect_failure { |job| job.dig("spec", "template", "spec")["containers"][0]["image"] = "registry/api@sha256:#{'0' * 64}" }
expect_failure { |job| job.dig("spec", "template", "spec")["containers"][0]["envFrom"] = [{ "secretRef" => { "name" => "secret" } }] }
expect_failure { |job| job.dig("spec", "template", "spec")["containers"][0]["volumeMounts"] = [{ "name" => "secret", "mountPath" => "/secret" }] }
puts "Agent Orchestration deployment verification contract self-test: passed"
