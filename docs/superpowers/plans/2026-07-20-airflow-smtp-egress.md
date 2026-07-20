# Airflow Gmail SMTP egress 허용 구현 계획

> **For agentic workers:** 소규모 NetworkPolicy 단건 변경으로 스레드 내 진행합니다.
>
> Issue: #277 (관련: `SKYAHO/Autoresearch-airflow#87`)

**목표:** dev GKE의 Airflow scheduler가 Gmail SMTP STARTTLS endpoint인
`smtp.gmail.com:587`에 연결해 DAG 성공·실패 알림을 발송할 수 있게 합니다.

**아키텍처 결정:** `terraform/admin/airflow-k8s`가 소유하는
`kubernetes_network_policy_v1.airflow_egress`의 기존 외부 endpoint egress에
TCP 587을 추가합니다. 표준 Kubernetes NetworkPolicy는 FQDN 목적지를 지원하지
않고 Gmail SMTP IP는 고정되지 않으므로 기존 TCP 443 규칙과 같은
`0.0.0.0/0` 목적지를 사용하되 허용 포트는 587 하나로 제한합니다.

---

## Task 1: Terraform NetworkPolicy 변경

- [x] `terraform/admin/airflow-k8s/main.tf`의 외부 endpoint egress 블록에
  TCP 587 ports 블록을 추가합니다.
- [x] 기존 DNS, Cloud SQL, Redis, HTTPS, MLflow, metadata egress 규칙은
  변경하지 않습니다.

## Task 2: 운영 문서 갱신

- [x] `terraform/admin/airflow-k8s/README.md`에 SMTP 목적, 보안 경계,
  검증 및 롤백 절차를 기록합니다.
- [x] `docs/CHANGE_HISTORY.md`에 장기 보존할 결정과 영향 범위를 기록합니다.

## Task 3: 검증

- [x] `terraform -chdir=terraform/admin/airflow-k8s fmt -check`
- [x] Terraform 1.13.5에서 `init -backend=false`와 `validate`
- [x] 실제 backend와 운영자 인증으로 plan을 실행해
  `0 add / 1 change / 0 destroy`와 NetworkPolicy in-place 변경만 확인합니다.
- [x] `git diff --check`

## 적용 후 검증

별도 적용 승인 후 Airflow namespace의 일회성 Pod에서 DNS와 TCP 587 연결을
확인하고, Kubernetes Secret 값을 출력하지 않는 SMTP smoke로 메일 전달을
검증합니다. 이어서 `Autoresearch-airflow#87`의 합성 성공·실패 callback smoke를
실행합니다.

## 롤백

추가한 TCP 587 ports 블록을 제거하고 admin root를 다시 plan/apply합니다.
NetworkPolicy 한 개의 in-place 갱신이며 Pod, node, IAM, GCP 리소스를 재생성하지
않습니다.

## 비용/보안 영향

- 비용: 없음.
- IAM/GCP 리소스: 변경 없음.
- 네트워크: `airflow` namespace 전체 Pod가 외부 IPv4 TCP 587에 연결할 수 있게
  됩니다. 목적지 FQDN 제한은 표준 NetworkPolicy로 표현할 수 없으며, credential은
  별도 Kubernetes Secret에만 저장합니다.
