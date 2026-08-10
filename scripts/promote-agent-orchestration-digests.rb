#!/usr/bin/env ruby
# frozen_string_literal: true

# 검증된 동일 release의 Agent Orchestration image digest만 허용 manifest에 원자적으로 반영한다.
module AgentOrchestrationDigestPromotion
  ROOT = File.expand_path("..", __dir__)
  TARGETS = {
    # #616 log-collector-deployment.yaml은 image를 둘 쓴다 — 본체는 launcher image의
    # 다른 진입점이고, bootstrap-db initContainer는 launcher image에 없는 모듈 때문에
    # API image다(launcher-cronjob.yaml과 같은 이유). 둘 다 등록하지 않으면
    # validate_directory_references!가 "허용 범위 밖 image 참조"로 승격을 막는다.
    api: { repository: "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-api", files: { "api-deployment.yaml" => 2, "api-migration-job.yaml" => 2, "launcher-cronjob.yaml" => 1, "log-collector-deployment.yaml" => 1, "runner-deployment.yaml" => 1, "deployment-verification-job.yaml" => 1 } },
    ui: { repository: "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-ui", files: { "ui-deployment.yaml" => 1 } },
    launcher: { repository: "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-launcher", files: { "launcher-cronjob.yaml" => 1, "log-collector-deployment.yaml" => 1 } },
    runner: { repository: "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-runner", files: { "runner-deployment.yaml" => 1 } },
    executor: { repository: "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-executor", files: { "launcher-cronjob.yaml" => 1 } }
  }.freeze
  class PromotionError < StandardError; end
  module_function

  def promote!(root: ROOT, **refs)
    directory = File.join(root, "deploy", "agent-orchestration")
    replacements = TARGETS.map do |name, target|
      ref = refs.fetch(name)
      validate_ref!(ref, target.fetch(:repository), name)
      paths = target.fetch(:files).map { |filename, expected| [File.join(directory, filename), expected] }
      paths.each { |path, _| raise PromotionError, "manifest가 없습니다: #{path}" unless File.file?(path) }
      validate_directory_references!(directory, target)
      current = paths.flat_map do |path, expected|
        found = image_references(File.read(path), target.fetch(:repository))
        raise PromotionError, "#{File.basename(path)}의 #{name} digest 참조 수가 #{expected}개가 아닙니다" unless found.length == expected
        found
      end.uniq
      raise PromotionError, "#{name} digest가 이미 불일치합니다" unless current.length == 1
      [paths.map(&:first), current.first, ref]
    end
    replacements.each { |paths, old_ref, new_ref| replace_all!(paths, old_ref, new_ref) }
  end

  def validate_directory_references!(directory, target)
    expected = target.fetch(:files)
    actual = Dir.glob(File.join(directory, "*.yaml")).each_with_object({}) do |path, result|
      count = image_references(File.read(path), target.fetch(:repository)).length
      result[File.basename(path)] = count if count.positive?
    end
    raise PromotionError, "허용 범위 밖 image 참조가 있습니다" unless actual == expected
  end

  def validate_ref!(ref, repository, name)
    raise PromotionError, "#{name} digest 형식 또는 repository가 올바르지 않습니다" unless ref.match?(%r{\A#{Regexp.escape(repository)}@sha256:[0-9a-f]{64}\z})
  end
  def image_references(content, repository)
    content.scan(/#{Regexp.escape(repository)}@sha256:[0-9a-f]{64}/)
  end
  def replace_all!(paths, old_ref, new_ref)
    return if old_ref == new_ref
    paths.each { |path| File.write(path, File.read(path).gsub(old_ref, new_ref)) }
  end
end

if $PROGRAM_NAME == __FILE__
  AgentOrchestrationDigestPromotion.promote!(api: ENV.fetch("API_DIGEST_REF"), ui: ENV.fetch("UI_DIGEST_REF"), launcher: ENV.fetch("LAUNCHER_DIGEST_REF"), runner: ENV.fetch("RUNNER_DIGEST_REF"), executor: ENV.fetch("EXECUTOR_DIGEST_REF"))
  puts "Agent Orchestration digest promotion: passed"
end
