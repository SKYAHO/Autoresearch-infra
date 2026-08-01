# Google OAuth 운영 런북

이 문서는 ArgoCD, Airflow, MLflow, Grafana, Kibana의 Google OAuth 운영
규약을 정의한다. 인증 구현과 Secret key는 제품별 현재 계약을 유지한다. 이
문서의 목적은 이름을 강제로 통일하는 것이 아니라, 정본·주입·검증·롤백
절차를 한 곳에서 찾게 하는 것이다.

## 운영 원칙

- OAuth client ID와 secret은 항상 한 쌍으로 발급·갱신한다.
- 실제 OAuth payload, cookie secret, allowlist 이메일은 Git, PR 본문,
  Terraform 코드와 공개 로그에 기록하지 않는다.
- Secret Manager는 client 자격의 정본으로 사용하되, 제품별 K8s Secret은
  해당 workload가 요구하는 key 이름과 형식을 유지한다.
- allowlist 정본은 제품의 인증 모델에 따라 다르다. 모든 제품을 하나의
  `authenticated-emails` key로 바꾸지 않는다.
- Secret 갱신은 실행 중인 Pod에 자동 반영된다고 가정하지 않는다. 갱신 후
  서비스별 rollout과 로그인 smoke test를 수행한다.
- redirect URI와 로컬 port는 제품별로 유지한다. Google OAuth 콘솔의 URI를
  임의로 합치지 않는다.

현재 ArgoCD는 Terraform이 `terraform.tfvars`의 이메일을 RBAC ConfigMap으로
렌더하므로 state에 policy 내용이 포함될 수 있다. 이 문서는 해당 구조를
확장하지 않으며, state에 개인 이메일을 남기지 않는 엄격한 정책으로 전환하려면
별도 RBAC/IAM 설계와 마이그레이션이 필요하다.

## 현재 운영 계약

| 서비스 | 인증 구현 | K8s Secret / key | allowlist 정본·방식 | 변경 주체 | redirect URI / 접근 | 갱신 후 조치 |
|---|---|---|---|---|---|---|
| ArgoCD | 내장 OIDC + RBAC | `argocd/argocd-google-oidc`: `clientId`, `clientSecret` | `terraform.tfvars`의 admin/readonly 이메일 → Terraform이 `argocd-rbac-cm` policy로 렌더 | `argocd-k8s` 운영자, IAM 승인자 | `https://localhost:8443/auth/callback` / `argocd-server` port-forward | `deployment/argo-cd-argocd-server` rollout |
| Airflow | Flask-AppBuilder native OAuth | `airflow/airflow-web-oauth`: `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`, `GOOGLE_ALLOWED_EMAILS` | 운영자 주입 K8s Secret의 쉼표 구분 목록. webserver 시작 시 빈 목록·형식 오류를 거부 | Airflow 배포 운영자, #475 절차 | `http://localhost:8080/oauth-authorized/google`, `http://localhost:8080/auth/oauth-authorized/google` / Bastion 터널 | `deployment/airflow-webserver` rollout |
| MLflow | oauth2-proxy | `mlflow/mlflow-oauth`: `client-id`, `client-secret`, `cookie-secret`, `authenticated-emails` | 운영자 주입 Secret의 파일 목록 | `mlflow-k8s` 운영자 | `http://localhost:4180/oauth2/callback` / proxy port-forward 또는 내부 LB | `deployment/mlflow-oauth-proxy` rollout |
| Kibana | oauth2-proxy + Kibana basic/anonymous 내부 연동 | `elastic/kibana-oauth`: `client-id`, `client-secret`, `cookie-secret`, `authenticated-emails` | 운영자 주입 Secret의 파일 목록 | `elastic-k8s` 운영자 | `http://localhost:4181/oauth2/callback` / proxy port-forward | `deployment/kibana-oauth-proxy` rollout |
| Grafana | Grafana native OAuth | `monitoring/grafana-google-oauth`: `GF_AUTH_GOOGLE_CLIENT_ID`, `GF_AUTH_GOOGLE_CLIENT_SECRET` | 별도 이메일 파일 없음. `allow_sign_up=false`와 사전 생성 Grafana 계정의 이메일 매칭으로 제한 | 모니터링 운영자, Grafana 관리자 | `http://localhost:3000/login/google` / Grafana port-forward | `deployment/kube-prometheus-stack-grafana` rollout |

세부 주입 명령과 서비스별 소유 root는 다음 문서를 정본으로 참조한다.

- ArgoCD: [`terraform/admin/argocd-k8s/README.md`](../terraform/admin/argocd-k8s/README.md)
- Airflow: `SKYAHO/Autoresearch-airflow`의 `docs/gke-helm-gitsync.md`
- MLflow: [`terraform/admin/mlflow-k8s/README.md`](../terraform/admin/mlflow-k8s/README.md)
- Kibana: [`terraform/admin/elastic-k8s/README.md`](../terraform/admin/elastic-k8s/README.md)
- Grafana: [`GRAFANA_OPERATIONS_RUNBOOK.md`](GRAFANA_OPERATIONS_RUNBOOK.md)

## Secret Manager와 K8s Secret의 관계

| 구분 | Secret Manager | Kubernetes Secret | 비고 |
|---|---|---|---|
| client ID/secret | 아래 서비스별 표에 명시한 Secret Manager payload 정본 | 제품별 key 이름으로 변환한 실행 사본 | Secret Manager metadata와 payload 주입은 Terraform 밖에서 수행 |
| oauth2-proxy cookie | 보통 저장하지 않음 | `cookie-secret` | 변경 시 기존 proxy 세션이 무효화될 수 있음 |
| MLflow/Kibana allowlist | 공통 Secret Manager 정본으로 통합하지 않음 | `authenticated-emails` 파일 | 현재 운영 계약 유지. 변경 시 해당 Secret만 갱신 |
| Airflow allowlist | 공통 Secret Manager 정본으로 통합하지 않음 | `GOOGLE_ALLOWED_EMAILS` | #475/#208에서 운영자 주입으로 전환 |
| ArgoCD/Grafana access control | 각각 Terraform 이메일 또는 Grafana DB 계정 | ConfigMap/DB 기반 | oauth2-proxy allowlist key로 변경하지 않음 |

현재 Secret Manager 이름은 패턴으로 추론하지 않고 아래 값을 그대로 사용한다.

| 서비스 | Secret Manager client ID / secret |
|---|---|
| Airflow | `autoresearch-dev-airflow-oauth-client-id` / `autoresearch-dev-airflow-oauth-client-secret` |
| MLflow | `autoresearch-dev-mlflow-oauth-client-id` / `autoresearch-dev-mlflow-oauth-client-secret` |
| Grafana | `autoresearch-dev-grafana-oauth-client-id` / `autoresearch-dev-grafana-oauth-client-secret` |
| Kibana | `autoresearch-dev-kibana-oauth-client-id` / `autoresearch-dev-kibana-oauth-client-secret` |
| ArgoCD | `argocd-google-oidc-client-id` / `argocd-google-oidc-client-secret` |

Secret Manager 자동 동기화(External Secrets Operator/CSI Driver)는 이 런북의
범위가 아니다. 도입하려면 workload별 IAM, 동기화 지연, rotation trigger, 삭제
정책을 별도 설계·검증해야 한다.

## 구현 방식을 통일하지 않는 이유

- ArgoCD는 OIDC email claim을 Kubernetes RBAC policy에 매핑해야 하므로
  oauth2-proxy의 `authenticated-emails` 파일로 대체하지 않는다.
- Airflow는 Flask-AppBuilder의 user registration·role mapping을 사용하므로
  webserver Python 설정에서 allowlist를 검증한다.
- MLflow와 Kibana는 내부 서비스 앞단의 oauth2-proxy가 공통 파일 기반
  allowlist를 이미 지원하므로 현재 Secret 계약을 유지한다.
- Grafana는 `allow_sign_up=false`와 사전 생성 계정의 이메일 매칭을 사용한다.
  별도 allowlist 파일을 추가하면 Grafana DB 계정 정책과 이중 정본이 생긴다.

따라서 #476의 결과는 공통 운영 절차이며, native OIDC/OAuth와 oauth2-proxy를
서로 교체하는 런타임 마이그레이션이 아니다.

## client ID/secret 갱신 절차

1. 영향을 받는 서비스와 현재 redirect URI를 확인한다. Google OAuth 콘솔에는
   서비스별 URI를 유지한다.
2. 새 client ID와 secret을 같은 OAuth client 세대에서 발급하고, 두 값을
   해당 서비스의 Secret Manager 정본에 각각 새 version으로 등록한다.
3. 기존 K8s Secret의 key 이름을 유지한 채 새 값을 주입한다. MLflow와 Kibana의
   oauth2-proxy Secret은 `client-id`, `client-secret`, `cookie-secret`,
   `authenticated-emails` 4개 key를 함께 갖는 bundle이다. client만 교체할 때도
   기존 cookie secret과 allowlist를 보존해 전체 bundle을 재생성한다. 2개 key만
   넣어 Secret을 덮어쓰면 세션 전부가 끊기고 allowlist가 사라져 proxy가 기동
   실패하거나 접근 통제가 붕괴할 수 있다. 구체적인 재주입은 MLflow/Kibana
   root README 절차를 그대로 사용한다. `kubectl get secret` 검증에서는 key
   이름만 출력하고 payload를 출력하지 않는다.
4. 서비스별 rollout을 실행하고 `kubectl rollout status`가 성공하는지 확인한다.
5. 로그인 smoke test를 수행한다.
   - 허용 계정: 로그인 및 원래 역할 확인
   - 미허용 계정: 거부 확인
   - 기존 workload: ArgoCD sync, Airflow webserver, MLflow/Kibana proxy,
     Grafana health 확인
6. 새 client 세대의 비노출 검증을 마친 뒤에만 이전 version을 폐기한다.

ID만 또는 secret만 갱신하면 `invalid_client`가 발생할 수 있다. 두 version의
내용을 채팅·로그에 출력하지 말고, 저장소의
[`verify-oauth-clients.sh`](../scripts/verify-oauth-clients.sh)를 실행해 5개
서비스의 client ID 프로젝트 prefix와 Secret Manager↔Kubernetes Secret
client ID/secret 해시를 비노출로 대조한다.

## allowlist 변경 절차

allowlist 변경은 client rotation과 별도 작업으로 취급한다.

1. 변경 대상 서비스와 승인된 계정 변경 내역을 확인한다.
2. 서비스별 key/파일 형식을 유지해 Secret 또는 Terraform 입력을 갱신한다.
3. 변경 전후 payload를 출력하지 않고 key 존재만 확인한다.
4. 해당 서비스만 rollout한다. 다른 서비스의 Secret을 함께 덮어쓰지 않는다.
5. 허용 계정 로그인과 제거 계정 거부를 확인한다.
6. 기존 세션은 즉시 폐기되지 않을 수 있음을 기록한다. 즉시 차단이 필요하면
   서비스별 세션/cookie 무효화 절차를 별도로 수행한다.

## 롤백과 break-glass

| 서비스 | break-glass |
|---|---|
| ArgoCD | 로컬 `admin` 계정 유지. OIDC Secret/RBAC 변경 실패 시 `argocd-k8s` README의 admin 경로로 복구 |
| Airflow | 로컬 `admin` 계정 유지. OAuth Secret을 이전 세대로 복원하고 webserver rollout |
| MLflow/Kibana | proxy Secret을 이전 세대로 복원하고 proxy rollout. proxy를 우회하는 공개 endpoint는 만들지 않음 |
| Grafana | 사전 관리된 Grafana local admin 계정 유지. OAuth Secret을 이전 세대로 복원하고 Grafana rollout |

롤백 시에는 이전 client ID/secret의 쌍과 이전 allowlist를 함께 복원한다. OAuth
Secret 변경만으로 Terraform state를 직접 조작하거나 ArgoCD prune을 실행하지
않는다.

## 검증 체크리스트

- [ ] 실제 payload가 Git, PR, 로그, Terraform state에 포함되지 않았다.
- [ ] Secret key 이름이 해당 제품의 현재 계약과 일치한다.
- [ ] client ID와 secret이 같은 세대의 쌍이다.
- [ ] redirect URI와 port-forward/Bastion 경로가 기존 값과 일치한다.
- [ ] rollout status가 성공했다.
- [ ] 허용 계정 로그인과 미허용 계정 거부를 확인했다.
- [ ] break-glass 계정과 롤백 version을 확인했다.
- [ ] 변경 대상 서비스 외의 Secret과 workload를 변경하지 않았다.
