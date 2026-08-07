#!/usr/bin/env ruby
# frozen_string_literal: true
require "fileutils"
require "tmpdir"
require_relative "promote-agent-orchestration-digests"

def with_manifest_copy
  Dir.mktmpdir("agent-orchestration-promotion-") do |root|
    FileUtils.mkdir_p(File.join(root, "deploy"))
    FileUtils.cp_r(File.join(AgentOrchestrationDigestPromotion::ROOT, "deploy/agent-orchestration"), File.join(root, "deploy"))
    yield root
  end
end

def expect_promotion_error(message)
  yield
  raise "#{message}: 실패해야 하는 입력을 허용했습니다"
rescue AgentOrchestrationDigestPromotion::PromotionError
  nil
end

api = "#{AgentOrchestrationDigestPromotion::API_REPOSITORY}@sha256:#{'a' * 64}"
ui = "#{AgentOrchestrationDigestPromotion::UI_REPOSITORY}@sha256:#{'b' * 64}"

with_manifest_copy do |root|
  AgentOrchestrationDigestPromotion.promote!(root: root, api_ref: api, ui_ref: ui)
  directory = File.join(root, "deploy/agent-orchestration")
  api_references = AgentOrchestrationDigestPromotion::API_REFERENCE_COUNTS.keys.flat_map do |filename|
    AgentOrchestrationDigestPromotion.image_references(
      File.read(File.join(directory, filename)),
      AgentOrchestrationDigestPromotion::API_REPOSITORY
    )
  end
  ui_references = AgentOrchestrationDigestPromotion.image_references(
    File.read(File.join(directory, AgentOrchestrationDigestPromotion::UI_FILE)),
    AgentOrchestrationDigestPromotion::UI_REPOSITORY
  )
  raise "API digest 갱신 실패" unless api_references == Array.new(7, api)
  raise "UI digest 갱신 실패" unless ui_references == [ui]
end

with_manifest_copy do |root|
  path = File.join(root, "deploy/agent-orchestration/runner-deployment.yaml")
  File.write(path, File.read(path).sub(/@sha256:[0-9a-f]{64}/, ":latest"))
  expect_promotion_error("부분 API digest") do
    AgentOrchestrationDigestPromotion.promote!(root: root, api_ref: api, ui_ref: ui)
  end
end

expect_promotion_error("잘못된 repository") do
  AgentOrchestrationDigestPromotion.promote!(api_ref: "invalid", ui_ref: ui)
end

puts "Agent Orchestration digest promotion self-test: passed"
