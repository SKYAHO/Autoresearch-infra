#!/usr/bin/env ruby
# frozen_string_literal: true
require "fileutils"
require "tmpdir"
require_relative "promote-agent-orchestration-digests"

def with_copy
  Dir.mktmpdir("agent-orchestration-promotion-") do |root|
    FileUtils.mkdir_p(File.join(root, "deploy"))
    FileUtils.cp_r(File.join(AgentOrchestrationDigestPromotion::ROOT, "deploy/agent-orchestration"), File.join(root, "deploy"))
    yield root
  end
end
def refs
  suffixes = { api: "a", ui: "b", launcher: "c", runner: "d" }
  AgentOrchestrationDigestPromotion::TARGETS.to_h { |name, target| [name, "#{target[:repository]}@sha256:#{suffixes.fetch(name) * 64}"] }
end
def expect_error
  yield
  raise "실패해야 하는 입력을 허용했습니다"
rescue AgentOrchestrationDigestPromotion::PromotionError
end

with_copy do |root|
  values = refs
  AgentOrchestrationDigestPromotion.promote!(root: root, **values)
  directory = File.join(root, "deploy/agent-orchestration")
  AgentOrchestrationDigestPromotion::TARGETS.each do |name, target|
    actual = Dir.glob(File.join(directory, "*.yaml")).flat_map { |path| AgentOrchestrationDigestPromotion.image_references(File.read(path), target[:repository]) }
    raise "#{name} digest 갱신 실패" unless actual == Array.new(target[:files].values.sum, values[name])
  end
end
with_copy do |root|
  path = File.join(root, "deploy/agent-orchestration/runner-deployment.yaml")
  File.write(path, File.read(path).sub(/@sha256:[0-9a-f]{64}/, ":latest"))
  expect_error { AgentOrchestrationDigestPromotion.promote!(root: root, **refs) }
end
with_copy do |root|
  File.write(File.join(root, "deploy/agent-orchestration/unexpected.yaml"), "image: #{refs[:api]}\n")
  expect_error { AgentOrchestrationDigestPromotion.promote!(root: root, **refs) }
end
with_copy { |root| expect_error { AgentOrchestrationDigestPromotion.promote!(root: root, **refs.merge(api: "invalid")) } }
puts "Agent Orchestration digest promotion self-test: passed"
