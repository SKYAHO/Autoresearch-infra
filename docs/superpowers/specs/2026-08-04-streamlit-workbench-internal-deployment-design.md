# 내부 Streamlit Experiment Workbench 배포 설계

## 목적

팀이 외부 공개 없이 Streamlit Experiment Workbench를 사용할 수 있도록
`autoresearch` namespace에 최소 권한 UI Deployment와 ClusterIP Service를 추가한다.
접근은 권한을 가진 팀원의 `kubectl port-forward`로만 제공한다.

## 범위

- `agent-orchestration` manifest에 UI Deployment와 `ClusterIP:8501` Service를 추가한다.
- 기존 `agent-orchestration-api-token` Secret의 요청 토큰을 UI 컨테이너 환경에만
  `ORCH_UI_API_TOKEN`으로 주입한다.
- UI Pod와 API Pod 사이의 TCP 8000, DNS, node-originated probe 외 통신을
  NetworkPolicy로 차단한다.
- UI 배포, port-forward, 롤백 절차를 Agent Orchestration runbook에 기록한다.

다음은 범위 밖이다.

- Ingress, LoadBalancer, public IP, OAuth, 사용자별 인증을 추가하지 않는다.
- 새 GSA/KSA, Secret Manager 접근, Cloud SQL 접근, Kubernetes API 권한을 추가하지 않는다.
- 실제 `terraform apply`, ArgoCD sync, manifest apply는 별도 운영 승인 후 수행한다.

## 배포 단위

UI Deployment는 1 replica로 시작하며, `agent-orchestration-ui` component label을
가진다. Pod는 `automountServiceAccountToken: false`, `RuntimeDefault` seccomp,
`allowPrivilegeEscalation: false`, read-only root filesystem, capabilities drop-all,
UID/GID `10001`을 사용한다. 초기 resource request는 CPU `100m`, memory `256Mi`이고,
limit은 CPU `500m`, memory `512Mi`이다.

컨테이너는 `SKYAHO/Autoresearch` release workflow가 제공한
`autoresearch-agent-orchestration-ui@sha256:...` immutable digest를 사용한다.
`ORCH_UI_API_BASE_URL`은 namespace 내부 API Service의 `http://agent-orchestration-api:8000`로
고정하고, 실제 토큰 값은 manifest·문서·로그에 기록하지 않는다.

Service는 selector를 UI label로 제한한 `ClusterIP`이며 port `8501`만 노출한다.
Ingress와 LoadBalancer를 만들지 않으므로 GCP public IP·외부 비용·외부 공격 표면이
추가되지 않는다.

## 네트워크 경계

기존 API NetworkPolicy ingress에는 `agent-orchestration-ui` component label을 가진
Pod만 TCP 8000으로 허용하는 rule을 추가한다. UI 전용 NetworkPolicy는 다음만 허용한다.

- node subnet에서 UI TCP 8501로 들어오는 kubelet probe 및 kubectl port-forward 경로
- API Service CIDR 및 API Pod selector로 향하는 TCP 8000
- Service CIDR과 `kube-system` selector로 향하는 UDP/TCP 53 DNS

Cloud SQL, Runner, Kubernetes API, metadata server, public HTTPS egress는 UI에 허용하지
않는다. UI는 Kubernetes API 토큰과 GCP IAM 권한이 없으며, 기존 API Secret을 읽을
권한도 없다. Kubernetes가 Secret 값을 컨테이너 환경에 주입할 뿐이다.

## 운영 절차

1. 앱 저장소의 UI 이미지 이슈를 merge하고, 해당 `main` source SHA로 release workflow를
   실행해 UI image digest를 얻는다.
2. 인프라 manifest에 그 digest를 고정하고, PR에서 NetworkPolicy ingress·egress와
   외부 노출이 없음을 검토한다.
3. 승인된 운영자가 manifest를 적용하거나 ArgoCD sync를 수행한다.
4. 팀원은 `kubectl -n autoresearch port-forward service/agent-orchestration-ui 8501:8501`
   로 접속한다.

## 롤백

UI 오류는 port-forward 사용을 중지하고 UI Deployment를 0 replica로 조정하거나,
이전 검증 digest로 manifest를 되돌려 복구한다. UI를 완전히 제거해야 하면 UI
Deployment·Service·NetworkPolicy와 API ingress의 UI rule을 같은 변경에서 제거한다.
API·Runner Deployment, API Secret, KSA/GSA, Cloud SQL은 롤백 대상으로 삼지 않는다.
