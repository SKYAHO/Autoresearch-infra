#!/usr/bin/env ruby
# frozen_string_literal: true

# 검증된 release digest만 Agent Orchestration manifest의 허용된 참조에 반영한다.
module AgentOrchestrationDigestPromotion
  ROOT = File.expand_path("..", __dir__)
  API_REPOSITORY = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-api"
  UI_REPOSITORY = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-ui"
  API_REFERENCE_COUNTS = {
    "api-deployment.yaml" => 2,
    "api-migration-job.yaml" => 2,
    "launcher-cronjob.yaml" => 1,
    "runner-deployment.yaml" => 1,
    "deployment-verification-job.yaml" => 1
  }.freeze
  UI_FILE = "ui-deployment.yaml"
  class PromotionError < StandardError; end
  module_function

  def promote!(root: ROOT, api_ref:, ui_ref:)
    validate_ref!(api_ref, API_REPOSITORY, "API")
    validate_ref!(ui_ref, UI_REPOSITORY, "UI")
    directory = File.join(root, "deploy", "agent-orchestration")
    api_paths = API_REFERENCE_COUNTS.keys.map { |name| File.join(directory, name) }
    api_paths.each { |path| raise PromotionError, "manifest가 없습니다: #{path}" unless File.file?(path) }
    current = api_paths.flat_map do |path|
      references = image_references(File.read(path), API_REPOSITORY)
      expected_count = API_REFERENCE_COUNTS.fetch(File.basename(path))
      unless references.length == expected_count
        raise PromotionError, "#{File.basename(path)}의 API digest 참조 수가 #{expected_count}개가 아닙니다"
      end

      references
    end.uniq
    raise PromotionError, "API digest가 이미 불일치합니다" unless current.length == 1
    replace_all!(api_paths, current.first, api_ref)

    ui_path = File.join(directory, UI_FILE)
    raise PromotionError, "manifest가 없습니다: #{ui_path}" unless File.file?(ui_path)
    ui_current = image_references(File.read(ui_path), UI_REPOSITORY)
    raise PromotionError, "UI digest 참조는 하나여야 합니다" unless ui_current.length == 1
    replace_all!([ui_path], ui_current.first, ui_ref)
  end

  def validate_ref!(ref, repository, name)
    raise PromotionError, "#{name} digest 형식 또는 repository가 올바르지 않습니다" unless ref.match?(%r{\A#{Regexp.escape(repository)}@sha256:[0-9a-f]{64}\z})
  end

  def replace_all!(paths, old_ref, new_ref)
    paths.each do |path|
      content = File.read(path)
      next if old_ref == new_ref
      File.write(path, content.gsub(old_ref, new_ref))
    end
  end

  def image_references(content, repository)
    content.scan(/#{Regexp.escape(repository)}@sha256:[0-9a-f]{64}/)
  end
end

if $PROGRAM_NAME == __FILE__
  AgentOrchestrationDigestPromotion.promote!(api_ref: ENV.fetch("API_DIGEST_REF"), ui_ref: ENV.fetch("UI_DIGEST_REF"))
  puts "Agent Orchestration digest promotion: passed"
end
