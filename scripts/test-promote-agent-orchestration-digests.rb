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
  suffixes = { api: "a", ui: "b", launcher: "c", runner: "d", executor: "e" }
  AgentOrchestrationDigestPromotion::TARGETS.to_h { |name, target| [name, "#{target[:repository]}@sha256:#{suffixes.fetch(name) * 64}"] }
end
V12_API_REF = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker/autoresearch-agent-orchestration-api@sha256:657bb3bb64a6e900b422f868ac2f5ac75459210654fe87f1fa892a2b815ba3d6"

def expect_equal(expected, actual, description)
  return if expected == actual

  raise "#{description} 불일치: 기대=#{expected.inspect}, 실제=#{actual.inspect}"
end

def check_v12_api_digest!
  target = AgentOrchestrationDigestPromotion::TARGETS.fetch(:api)
  directory = File.join(AgentOrchestrationDigestPromotion::ROOT, "deploy/agent-orchestration")
  actual = Dir.glob(File.join(directory, "*.yaml")).sort.flat_map do |path|
    AgentOrchestrationDigestPromotion.image_references(
      File.read(path),
      target.fetch(:repository)
    )
  end
  expect_equal(Array.new(7, V12_API_REF), actual, "v0.12.0 API image references")
end

check_v12_api_digest!

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
