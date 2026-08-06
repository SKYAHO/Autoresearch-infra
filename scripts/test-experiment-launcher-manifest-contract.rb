#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 1 launcher CronJob의 실행 좌표와 전용 egress 경계를 실제 YAML 객체로 검증한다.
require "yaml"

repository_root = File.expand_path("..", __dir__)
manifest_path = File.join(
  repository_root,
  "deploy",
  "agent-orchestration",
  "launcher-cronjob.yaml"
)
raise "launcher CronJob manifest가 없습니다" unless File.file?(manifest_path)

documents = YAML.load_stream(File.read(manifest_path)).compact
cron_job = documents.find { |document| document["kind"] == "CronJob" }
network_policy = documents.find { |document| document["kind"] == "NetworkPolicy" }
raise "CronJob 문서가 없습니다" unless cron_job
raise "launcher NetworkPolicy 문서가 없습니다" unless network_policy

expected_launcher_image = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher@sha256:44ca561e7cd8f6df7b00c6a6d7c1d7ee971107d3e3234e5eb02086c90ca57cc7"
expected_executor_image = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor@sha256:fe0002e097ac750c90a083519cc6ac86420e84a44c1aa7aa6c7d0ff9120b707c"

spec = cron_job.fetch("spec")
raise "launcher schedule 불일치" unless spec["schedule"] == "* * * * *"
raise "launcher concurrencyPolicy 불일치" unless spec["concurrencyPolicy"] == "Forbid"
raise "launcher startingDeadlineSeconds 불일치" unless spec["startingDeadlineSeconds"] == 60
raise "launcher 성공 history 불일치" unless spec["successfulJobsHistoryLimit"] == 1
raise "launcher 실패 history 불일치" unless spec["failedJobsHistoryLimit"] == 3

job_spec = spec.dig("jobTemplate", "spec")
raise "launcher backoffLimit 불일치" unless job_spec&.fetch("backoffLimit") == 0
pod_template = job_spec.dig("template")
pod_spec = pod_template&.fetch("spec")
raise "launcher KSA 불일치" unless pod_spec&.fetch("serviceAccountName") == "agent-orchestration-launcher"
raise "launcher KSA token이 필요합니다" unless pod_spec["automountServiceAccountToken"] == true
raise "launcher restartPolicy 불일치" unless pod_spec["restartPolicy"] == "Never"

init_containers = pod_spec.fetch("initContainers")
containers = pod_spec.fetch("containers")
raise "launcher initContainer는 bootstrap-db 하나여야 합니다" unless init_containers.map { |item| item["name"] } == ["bootstrap-db"]
raise "launcher app container는 launcher 하나여야 합니다" unless containers.map { |item| item["name"] } == ["launcher"]
raise "launcher bootstrap image 불일치" unless init_containers.first["image"] == expected_launcher_image
raise "launcher image 불일치" unless containers.first["image"] == expected_launcher_image

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
  raise "#{name} 불일치" unless environment.fetch(name) == { "name" => name, "value" => value }
end

%w[ORCH_GITHUB_APP_ID ORCH_GITHUB_APP_INSTALLATION_ID].each do |name|
  reference = environment.dig(name, "valueFrom", "secretKeyRef")
  raise "#{name} Secret 이름 불일치" unless reference&.fetch("name") == "autoresearch-experiment-branch-writer-app"
end

labels = pod_template.dig("metadata", "labels")
raise "launcher NetworkPolicy label 누락" unless labels == {
  "app.kubernetes.io/name" => "agent-orchestration-launcher",
  "app.kubernetes.io/part-of" => "agent-orchestration",
  "app.kubernetes.io/component" => "launcher"
}
raise "launcher NetworkPolicy selector 불일치" unless network_policy.dig("spec", "podSelector", "matchLabels") == labels
raise "launcher NetworkPolicy는 egress만 제한해야 합니다" unless network_policy.dig("spec", "policyTypes") == ["Egress"]

puts "Experiment launcher manifest contract: passed"
