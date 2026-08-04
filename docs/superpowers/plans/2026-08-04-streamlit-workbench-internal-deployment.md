# Streamlit Experiment Workbench Internal Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 검증된 Streamlit UI image digest를 `autoresearch` namespace의 내부 전용 Deployment와 ClusterIP Service로 배포한다.

**Architecture:** ArgoCD `agent-orchestration` Application이 manual sync하는 `deploy/agent-orchestration` 디렉터리에 UI manifest를 추가한다. UI Pod는 기존 API request-token Secret을 환경 변수로만 받고 API ingress와 UI egress NetworkPolicy는 API TCP 8000·DNS·node probe로 제한한다.

**Tech Stack:** Kubernetes Deployment, Service, NetworkPolicy, ArgoCD manual sync, Terraform-managed namespace and port-forward RBAC.

## Global Constraints

- UI image는 앱 release workflow가 생성한 `@sha256:` digest만 사용한다.
- Ingress, LoadBalancer, public IP, 새 KSA/GSA, 새 IAM, Secret Manager access는 추가하지 않는다.
- UI Pod는 `automountServiceAccountToken: false`, non-root UID/GID `10001`, read-only root filesystem, capabilities drop-all을 사용한다.
- 실제 Terraform apply, ArgoCD target revision 갱신, manual sync는 PR review와 운영자 승인을 받은 뒤에만 실행한다.

---

### Task 1: UI Deployment와 ClusterIP Service 추가

**Files:**
- Create: `deploy/agent-orchestration/ui-deployment.yaml`
- Create: `deploy/agent-orchestration/ui-service.yaml`
- Test: Kubernetes client dry-run manifest parsing

**Interfaces:**
- Consumes: `autoresearch-agent-orchestration-ui@sha256:<digest>`, Secret `agent-orchestration-api-token` key `ORCH_API_TOKEN`, Service `agent-orchestration-api:8000`
- Produces: component label `ui`를 가진 port `8501` Deployment와 internal Service

- [ ] **Step 1: manifest 검증 기준을 작성한다**

새 manifest에는 `ClusterIP`, API base URL, `ORCH_UI_API_TOKEN` secretKeyRef,
`automountServiceAccountToken: false`, `/_stcore/health` readiness·liveness probe,
request `100m/256Mi`, limit `500m/512Mi`가 있어야 한다.

- [ ] **Step 2: UI Deployment를 구현한다**

replica 1의 `agent-orchestration-ui` Deployment를 작성한다. `HOME=/tmp`와 emptyDir `/tmp`
mount를 두어 Streamlit의 임시 파일 요구와 read-only root filesystem을 양립시킨다.
이미지는 release digest placeholder로 시작하고 `ORCH_UI_API_BASE_URL`은
`http://agent-orchestration-api:8000`으로 설정한다.

- [ ] **Step 3: UI Service를 구현한다**

`agent-orchestration-ui` selector, port·targetPort `8501`, type `ClusterIP`만 가진
Service를 작성한다. ServiceMonitor·Ingress·LoadBalancer annotation은 추가하지 않는다.

- [ ] **Step 4: manifest 구문을 검증한다**

```bash
kubectl apply --dry-run=client -f deploy/agent-orchestration/ui-deployment.yaml
kubectl apply --dry-run=client -f deploy/agent-orchestration/ui-service.yaml
```

- [ ] **Step 5: Deployment·Service 변경을 커밋한다**

```bash
git add deploy/agent-orchestration/ui-deployment.yaml \
  deploy/agent-orchestration/ui-service.yaml
git commit -m "feat: 내부 Streamlit UI 배포 추가"
```

### Task 2: 최소 NetworkPolicy 경계 추가

**Files:**
- Modify: `deploy/agent-orchestration/network-policy.yaml`
- Test: manifest dry-run과 정책 rule review

**Interfaces:**
- Consumes: UI component label, API component label, reviewed node/service CIDR
- Produces: UI-to-API TCP 8000과 DNS만 가능한 UI policy, UI Pod만 허용하는 API ingress

- [ ] **Step 1: API ingress allowlist rule을 추가한다**

기존 API ingress에 `app.kubernetes.io/component: ui`와
`app.kubernetes.io/part-of: agent-orchestration` podSelector만 TCP 8000으로 허용한다.
node subnet의 probe·port-forward rule은 유지한다.

- [ ] **Step 2: UI 전용 default-deny 정책을 추가한다**

UI ingress는 node subnet TCP 8501만 허용한다. UI egress는 Service CIDR과 API podSelector의
TCP 8000, Service CIDR과 `kube-system` namespace selector의 UDP/TCP 53만 허용한다.
Cloud SQL, Runner, metadata server, Kubernetes API, private Google APIs, public HTTPS는
rule에 포함하지 않는다.

- [ ] **Step 3: manifest 구문과 정적 CIDR을 검증한다**

```bash
kubectl apply --dry-run=client -f deploy/agent-orchestration/network-policy.yaml
git diff --check
```

node subnet과 Service CIDR은 reviewed dev Terraform values와 대조한다.

- [ ] **Step 4: NetworkPolicy 변경을 커밋한다**

```bash
git add deploy/agent-orchestration/network-policy.yaml
git commit -m "feat: Streamlit UI 네트워크 경계 추가"
```

### Task 3: ArgoCD 운영 runbook과 구조 문서 갱신

**Files:**
- Modify: `docs/runbooks/2026-07-30-agent-orchestration-gke.md`
- Modify: `docs/README.md`
- Modify: `.claude/docs/agent-project-reference.md`

**Interfaces:**
- Consumes: UI digest from application release and Tasks 1-2 manifest contracts
- Produces: target revision → manual sync → port-forward → rollback runbook

- [ ] **Step 1: runbook의 prerequisite와 manifest placeholder를 갱신한다**

UI digest를 third immutable input으로 추가한다. API token payload를 출력하지 않고,
UI가 기존 Kubernetes Secret key만 참조한다는 점을 기록한다.

- [ ] **Step 2: post-sync 및 rollback 절차를 추가한다**

ArgoCD diff에서 UI image digest, UI Service ClusterIP, API ingress UI rule과 UI egress 최소성을
확인한다. manual sync 뒤 `rollout status deployment/agent-orchestration-ui`와
`kubectl port-forward service/agent-orchestration-ui 8501:8501`으로 UI 접근을 검증한다.
rollback은 이전 digest commit target revision으로 되돌리는 절차로 기록한다.

- [ ] **Step 3: 문서 변경을 커밋한다**

```bash
git add docs/runbooks/2026-07-30-agent-orchestration-gke.md docs/README.md \
  .claude/docs/agent-project-reference.md
git commit -m "docs: Streamlit UI 내부 배포 절차 추가"
```

### Task 4: PR 전 검증과 배포 handoff

**Files:**
- Verify: `deploy/agent-orchestration/ui-deployment.yaml`
- Verify: `deploy/agent-orchestration/ui-service.yaml`
- Verify: `deploy/agent-orchestration/network-policy.yaml`

- [ ] **Step 1: 좁은 manifest 검증을 실행한다**

```bash
kubectl apply --dry-run=client -f deploy/agent-orchestration/ui-deployment.yaml
kubectl apply --dry-run=client -f deploy/agent-orchestration/ui-service.yaml
kubectl apply --dry-run=client -f deploy/agent-orchestration/network-policy.yaml
git diff --check
```

- [ ] **Step 2: Draft PR을 만든다**

PR 본문에 `Closes #512`, 외부 노출·IAM·비용 영향 없음, UI resource request/limit,
ArgoCD manual sync와 별도 운영 승인 필요성을 기록한다.

- [ ] **Step 3: 승인된 배포 순서를 따른다**

앱 release의 UI digest를 manifest에 고정한 뒤 PR을 merge한다. 이어 target revision을
reviewed admin apply로 갱신하고 ArgoCD diff 확인 후 manual sync한다. 이 단계는 PR 구현과
분리된 실제 운영 변경이므로 별도 사용자 승인을 다시 받는다.
