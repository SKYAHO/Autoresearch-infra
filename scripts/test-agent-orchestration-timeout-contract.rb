#!/usr/bin/env ruby
# frozen_string_literal: true

# Timeout ConfigMap 계약 checker의 부정 mutation 회귀 테스트입니다.
require_relative "check-agent-orchestration-timeout-contract"

AgentOrchestrationTimeoutContract.self_test!
puts "Agent Orchestration timeout contract self-test: passed"
