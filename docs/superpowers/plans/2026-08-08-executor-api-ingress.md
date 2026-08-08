# Executor Experiment API Ingress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** dev executor Pod가 Experiment API TCP 8000을 호출하도록 허용한 live NetworkPolicy 규칙을 Argo CD Git desired state와 계약 검사에 반영한다.

**Architecture:** 기존 `agent-orchestration-api-egress` NetworkPolicy의 네 번째 ingress로 executor source peer를 추가한다. namespace selector와 Pod selector를 같은 peer에 두어 AND 의미를 고정하고, Ruby 계약 검사와 mutation self-test가 selector 분리·포트 변경·규칙 수 drift를 거부한다.

**Tech Stack:** Kubernetes NetworkPolicy YAML, Ruby YAML contract tests, Docker `ruby:3.4-alpine`.

## Global Constraints

- 대상은 `autoresearch/agent-orchestration-api-egress` 하나다.
- source namespace label은 `app.kubernetes.io/name=autoresearch-experiments`다.
- source Pod label은 `app.kubernetes.io/component=experiment-executor`다.
- destination은 `TCP/8000` 하나다.
- 두 selector는 같은 `from` peer 안에 있어야 한다.
- API ingress는 4개, API egress는 10개를 유지한다.
- IAM, image digest, executor egress는 변경하지 않는다.

---

### Task 1: Executor-to-API ingress와 fail-closed 계약 추가

**Files:**

- Modify: `scripts/check-agent-orchestration-deployment-verification.rb`
- Modify: `scripts/test-check-agent-orchestration-deployment-verification.rb`
- Modify: `deploy/agent-orchestration/network-policy.yaml`
- Test: `scripts/check-agent-orchestration-deployment-verification.rb`
- Test: `scripts/test-check-agent-orchestration-deployment-verification.rb`

**Interfaces:**

- Consumes: `AgentOrchestrationDeploymentVerification.check_network_policies!`가 읽는 API NetworkPolicy 문서.
- Produces: executor source peer와 TCP 8000을 고정하는 Git desired state 및 mutation-sensitive 계약.

- [ ] **Step 1: 누락된 executor ingress를 요구하는 계약을 먼저 작성한다**

`check_network_policies!`에서 API ingress 배열 길이가 4인지, 아래 exact rule이 한 개
존재하는지, API egress 길이가 10인지 검사한다.

```ruby
executor_ingress = {
  "from" => [{
    "namespaceSelector" => {
      "matchLabels" => { "app.kubernetes.io/name" => "autoresearch-experiments" }
    },
    "podSelector" => {
      "matchLabels" => { "app.kubernetes.io/component" => "experiment-executor" }
    }
  }],
  "ports" => [{ "protocol" => "TCP", "port" => 8000 }]
}
```

- [ ] **Step 2: RED 상태를 확인한다**

Run:

```bash
docker run --rm -v "$PWD":/workspace -w /workspace ruby:3.4-alpine \
  ruby scripts/check-agent-orchestration-deployment-verification.rb
```

Expected: 현재 API ingress가 3개이므로 계약 오류로 실패한다.

- [ ] **Step 3: NetworkPolicy에 최소 ingress 규칙을 추가한다**

기존 verifier ingress 뒤에 아래 원문을 추가한다.

```yaml
- from:
    - namespaceSelector:
        matchLabels:
          app.kubernetes.io/name: autoresearch-experiments
      podSelector:
        matchLabels:
          app.kubernetes.io/component: experiment-executor
  ports:
    - port: 8000
      protocol: TCP
```

- [ ] **Step 4: GREEN 상태를 확인한다**

Run:

```bash
docker run --rm -v "$PWD":/workspace -w /workspace ruby:3.4-alpine \
  ruby scripts/check-agent-orchestration-deployment-verification.rb
```

Expected: `Agent Orchestration deployment verification contract: passed`.

- [ ] **Step 5: selector 분리 mutation self-test를 추가한다**

API ingress의 executor rule을 찾아 하나의 source peer를 namespace peer와 Pod peer 두
개로 분리한다. `expect_failure`가 이 mutation을 거부해야 한다.

```ruby
expect_failure do |root|
  mutate_policies(root) do |documents|
    api = documents.find do |document|
      document.dig("metadata", "name") == "agent-orchestration-api-egress"
    end
    rule = api.dig("spec", "ingress").find do |item|
      item.dig("from", 0, "podSelector", "matchLabels", "app.kubernetes.io/component") ==
        "experiment-executor"
    end
    source = rule.fetch("from").first
    rule["from"] = [
      { "namespaceSelector" => source.fetch("namespaceSelector") },
      { "podSelector" => source.fetch("podSelector") }
    ]
  end
end
```

- [ ] **Step 6: 전체 관련 검증을 실행한다**

Run:

```bash
docker run --rm -v "$PWD":/workspace -w /workspace ruby:3.4-alpine \
  ruby scripts/check-agent-orchestration-deployment-verification.rb
docker run --rm -v "$PWD":/workspace -w /workspace ruby:3.4-alpine \
  ruby scripts/test-check-agent-orchestration-deployment-verification.rb
git diff --check
```

Expected: 두 Ruby 검사가 `passed`를 출력하고 `git diff --check`가 exit 0이다.

- [ ] **Step 7: 범위와 수량을 확인한다**

Run:

```bash
git diff -- deploy/agent-orchestration/network-policy.yaml \
  scripts/check-agent-orchestration-deployment-verification.rb \
  scripts/test-check-agent-orchestration-deployment-verification.rb
```

Expected: executor API ingress와 계약·self-test만 변경되고 IAM, digest, executor egress는
변경되지 않는다.
