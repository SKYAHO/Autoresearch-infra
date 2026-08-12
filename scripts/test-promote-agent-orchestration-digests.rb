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

def expect_equal(expected, actual, description)
  return if expected == actual

  raise "#{description} 불일치: 기대=#{expected.inspect}, 실제=#{actual.inspect}"
end

def check_promoted_api_digest!
  target = AgentOrchestrationDigestPromotion::TARGETS.fetch(:api)
  directory = File.join(AgentOrchestrationDigestPromotion::ROOT, "deploy/agent-orchestration")
  actual = Dir.glob(File.join(directory, "*.yaml")).sort.flat_map do |path|
    AgentOrchestrationDigestPromotion.image_references(
      File.read(path),
      target.fetch(:repository)
    )
  end
  # (#635) 기대 digest는 "지금 main에 승격된 값"이라 리터럴로 박으면 승격 봇이
  # 이 상수를 모른 채 manifest만 갱신할 때마다 self-test가 깨진다. 실제로 이
  # 테스트가 검증해야 할 건 특정 digest 값이 아니라 "manifest 전체가 같은 값을
  # 가리키는가"이므로, 기대값을 첫 참조에서 그대로 파생한다.
  #
  # #616 log-collector-deployment.yaml과 #630 pull-request-opener-deployment.yaml의
  # bootstrap-db initContainer가 각각 한 참조씩 더한다.
  # 개수를 상수로 박아 두는 이유는 manifest가 늘 때 TARGETS 등록을 강제하기 위해서다 —
  # 등록을 빠뜨리면 promote!의 validate_directory_references!가 승격을 막는다.
  raise "승격된 API image 참조가 없습니다" if actual.empty?

  expect_equal(Array.new(9, actual.first), actual, "승격된 API image 참조")
end

check_promoted_api_digest!

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
