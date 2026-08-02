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
| Airflow | Flask-AppBuilder native OAuth | `airflow/airflow-web-oauth`: `GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`, `GOOGLE_ALLOWED_EMAILS` | 운영자 주입 K8s Secret의 쉼표 구분 목록. webserver 시작 시 빈 목록·형식 오류를 거부 | Airflow 배포 운영자, 인프라 [#475](https://github.com/SKYAHO/Autoresearch-infra/issues/475) 절차. Airflow [#207](https://github.com/SKYAHO/Autoresearch-airflow/issues/207) / [#208](https://github.com/SKYAHO/Autoresearch-airflow/pull/208)에서 적용·검증 완료 | `http://localhost:8080/oauth-authorized/google`, `http://localhost:8080/auth/oauth-authorized/google` / Bastion 터널 | `deployment/airflow-webserver` rollout |
| MLflow | oauth2-proxy | `mlflow/mlflow-oauth`: `client-id`, `client-secret`, `cookie-secret`, `authenticated-emails` | 운영자 주입 Secret의 파일 목록이 **유일한** 이메일 경계(#488 해소 — `--email-domain` 미사용) | `mlflow-k8s` 운영자 | `http://localhost:4180/oauth2/callback` / proxy port-forward 또는 내부 LB | `deployment/mlflow-oauth-proxy` rollout |
| Kibana | oauth2-proxy + Kibana basic 인증(`elastic` 사용자) 이중 로그인 | `elastic/kibana-oauth`: `client-id`, `client-secret`, `cookie-secret`, `authenticated-emails` | 운영자 주입 Secret의 파일 목록이 **유일한** 이메일 경계(#488 해소 — `--email-domain` 미사용) | `elastic-k8s` 운영자 | `kibana_public_base_url`(기본 `http://localhost:4181`) + `/oauth2/callback` / proxy port-forward | `deployment/kibana-oauth-proxy` rollout |
| Grafana | Grafana native OAuth | `monitoring/grafana-google-oauth`: `GF_AUTH_GOOGLE_CLIENT_ID`, `GF_AUTH_GOOGLE_CLIENT_SECRET` | 별도 이메일 파일 없음. `allow_sign_up=false`와 사전 생성 Grafana 계정의 이메일 매칭으로 제한 | 모니터링 운영자, Grafana 관리자 | `http://localhost:3000/login/google` / Grafana port-forward | `deployment/kube-prometheus-stack-grafana` rollout |

세부 주입 명령과 서비스별 소유 root는 다음 문서를 정본으로 참조한다.

Kibana callback URI는 표의 기본값을 무조건 고정한 값이 아니다. 실제 값은
`terraform/admin/elastic-k8s/variables.tf`의 `kibana_public_base_url`에서
파생되며, 로컬 `tfvars`로 덮어쓸 수 있다. Google OAuth 콘솔과 운영 검증에서는
해당 환경의 변수값에 `/oauth2/callback`을 붙인 값을 사용한다.

- ArgoCD: [`terraform/admin/argocd-k8s/README.md`](../terraform/admin/argocd-k8s/README.md)
- Airflow: `SKYAHO/Autoresearch-airflow`의 `docs/gke-helm-gitsync.md`
- MLflow: [`terraform/admin/mlflow-k8s/README.md`](../terraform/admin/mlflow-k8s/README.md)
- Kibana: [`terraform/admin/elastic-k8s/README.md`](../terraform/admin/elastic-k8s/README.md)
- Grafana: [`GRAFANA_OPERATIONS_RUNBOOK.md`](GRAFANA_OPERATIONS_RUNBOOK.md)

## Secret Manager와 K8s Secret의 관계

| 구분 | Secret Manager | Kubernetes Secret | 비고 |
|---|---|---|---|
| client ID/secret | 아래 서비스별 표에 명시한 Secret Manager payload 정본 | 제품별 key 이름으로 변환한 실행 사본 | Secret Manager metadata와 payload 주입은 Terraform 밖에서 수행 |
| oauth2-proxy cookie | 보통 저장하지 않음 | `cookie-secret` | 값을 교체하면 기존 proxy session cookie를 복호화할 수 없어 전원 재로그인이 필요함. client만 교체할 때는 기존 값을 보존 |
| MLflow/Kibana allowlist | 공통 Secret Manager 정본으로 통합하지 않음 | `authenticated-emails` 파일 | Secret key 계약 유지. `--email-domain=*` 우회는 [#488](https://github.com/SKYAHO/Autoresearch-infra/issues/488)에서 제거됐고 CI가 재도입을 차단한다 |
| Airflow allowlist | 공통 Secret Manager 정본으로 통합하지 않음 | `GOOGLE_ALLOWED_EMAILS` | 인프라 [#475](https://github.com/SKYAHO/Autoresearch-infra/issues/475) 및 Airflow [#207](https://github.com/SKYAHO/Autoresearch-airflow/issues/207)·[PR #208](https://github.com/SKYAHO/Autoresearch-airflow/pull/208)에서 운영자 주입으로 전환·적용 완료 |
| ArgoCD/Grafana access control | 각각 Terraform 이메일 또는 Grafana DB 계정 | ConfigMap/DB 기반 | oauth2-proxy allowlist key로 변경하지 않음 |

현재 Secret Manager 이름은 패턴으로 추론하지 않고 아래 값을 그대로 사용한다.

| 서비스 | Secret Manager client ID / secret |
|---|---|
| Airflow | `autoresearch-dev-airflow-oauth-client-id` / `autoresearch-dev-airflow-oauth-client-secret` |
| MLflow | `autoresearch-dev-mlflow-oauth-client-id` / `autoresearch-dev-mlflow-oauth-client-secret` |
| Grafana | `autoresearch-dev-grafana-oauth-client-id` / `autoresearch-dev-grafana-oauth-client-secret` |
| Kibana | `autoresearch-dev-kibana-oauth-client-id` / `autoresearch-dev-kibana-oauth-client-secret` |
| ArgoCD | `argocd-google-oidc-client-id` / `argocd-google-oidc-client-secret` (Terraform 미관리, `prevent_destroy` 없음) |

Airflow·MLflow·Grafana·Kibana의 client Secret Manager 정본은 Terraform이
관리하며 `prevent_destroy = true`가 설정되어 있다. ArgoCD의 두 OAuth secret은
Terraform 리소스가 없는 운영자 수동 생성 정본이므로 같은 보호 장치가 없다.
ArgoCD secret을 삭제하거나 이름을 바꾸면 자동 복구되지 않으므로, rotation 전
백업과 break-glass 경로를 먼저 확인한다.

Secret Manager 자동 동기화(External Secrets Operator/CSI Driver)는 이 런북의
범위가 아니다. 도입하려면 workload별 IAM, 동기화 지연, rotation trigger, 삭제
정책을 별도 설계·검증해야 한다.

## 구현 방식을 통일하지 않는 이유

- ArgoCD는 OIDC email claim을 Kubernetes RBAC policy에 매핑해야 하므로
  oauth2-proxy의 `authenticated-emails` 파일로 대체하지 않는다.
- Airflow는 Flask-AppBuilder의 user registration·role mapping을 사용하므로
  webserver Python 설정에서 allowlist를 검증한다.
- MLflow와 Kibana는 내부 서비스 앞단의 oauth2-proxy Secret key 계약을 유지한다.
  `authenticated-emails` 파일이 **유일한** 이메일 경계다 — 과거 `--email-domain=*`가
  파일 판정을 덮어쓰던 우회는 [#488](https://github.com/SKYAHO/Autoresearch-infra/issues/488)에서
  제거됐고, `scripts/check-oauth-email-allowlist.sh`가 `lint`(required check)에서
  재도입을 차단한다.
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
6. [`verify-oauth-clients.sh`](../scripts/verify-oauth-clients.sh)의 결과를 판정한다.
   이 스크립트는 대상 서비스 하나가 아니라 5개 서비스를 모두 검사한다. 따라서
   갱신 대상 서비스에 `ERR` 또는 `WARN`이 있으면 해당 rotation은 실패·보류하고,
   다른 서비스의 `WARN`은 별도 정본 등록 작업으로 추적한다. 스크립트가 `WARN`만
   출력해도 exit 0일 수 있으므로 exit code만으로 성공 판정하지 않는다. 대상
   서비스가 `ERR`·`WARN` 없이 `OK`이고 로그인 smoke test까지 통과한 경우에만
   새 client 세대가 검증된 것으로 본다.
7. 새 client 세대의 비노출 검증을 마친 뒤에만 이전 version을 폐기한다.

ID만 또는 secret만 갱신하면 `invalid_client`가 발생할 수 있다. 두 version의
내용을 채팅·로그에 출력하지 말고, 저장소의
[`verify-oauth-clients.sh`](../scripts/verify-oauth-clients.sh)를 실행해 5개
서비스의 client ID 프로젝트 prefix와 Secret Manager↔Kubernetes Secret
client ID/secret 해시를 비노출로 대조한다.

## allowlist 변경 절차

allowlist 변경은 client rotation과 별도 작업으로 취급한다.

1. 변경 대상 서비스와 승인된 계정 변경 내역을 확인한다.
2. 서비스별 key/파일 형식을 유지해 Secret 또는 Terraform 입력을 갱신한다.
3. 변경 전후 payload를 출력하지 않고 key 존재와 값의 비어 있지 않음을
   비노출 방식으로 확인한다. MLflow/Kibana에서 `authenticated-emails` key가
   누락되면 Secret projected volume을 만들 수 없어 Pod가 정상 기동하지 못하고
   `FailedMount` 이벤트가 발생한다. key가 존재하고 값이 채워져 있으면 그 파일이
   최종 판정 기준이다(#488에서 `--email-domain=*` 제거).

   다만 **형식·개수 검사만으로는 부족하다.** 목록이 현재 팀 구성과 일치하는지,
   초기 예시 주소가 남아 있지 않은지는 검사되지 않으며, 이 상태는 proxy 기동·
   `/ping` probe·ArgoCD Health가 모두 초록이라 배포 신호로 감지되지 않는다
   (전원 403이 정상으로 보인다). 따라서 값 비노출 `entries=N`과 예시 주소 잔존
   점검(`placeholder_like=0`)을 함께 확인하고, 반영 후에는 허용 계정 로그인과
   제거 계정 거부를 smoke test로 확인한다.
   이 동작의 근거는 oauth2-proxy v7.7.1의
   [`validator.go`](https://github.com/oauth2-proxy/oauth2-proxy/blob/v7.7.1/validator.go)
   구현이다.
4. 해당 서비스만 rollout한다. 다른 서비스의 Secret을 함께 덮어쓰지 않는다.
5. 허용 계정 로그인과 제거 계정 거부를 확인한다.
6. 기존 세션은 즉시 폐기되지 않을 수 있음을 기록한다. 즉시 차단이 필요하면
   서비스별 세션/cookie 무효화 절차를 별도로 수행한다.

MLflow/Kibana의 “제거 계정 거부”는 이제 통과 기준으로 사용할 수 있다 —
`--email-domain=*`가 제거되어(#488) `authenticated-emails` 파일이 최종 판정이다.
allowlist 변경은 미허용 계정 거부가 확인된 뒤에 완료로 표시한다.

MLflow proxy는 port-forward뿐 아니라 내부 LoadBalancer(예약 IP는
`terraform output mlflow_ilb_ip`)를 통해서도 VPC 내부에 노출된다. 즉 그 VIP에
도달 가능한 VM·Pod는 proxy까지 접근할 수 있으므로, **네트워크 경계가 아니라
allowlist가 인가 경계**다. 그래서 이 목록의 정확성이 MLflow tracking/model
registry/API와 `--serve-artifacts` 경로의 노출 범위를 직접 결정한다.

재도입 방지: `--email-domain`(플래그), `OAUTH2_PROXY_EMAIL_DOMAINS`(환경변수),
`email-domain:`/`email_domains =`(Helm·config 키) 세 표기를 CI가 모두 차단하며,
oauth2-proxy 이미지를 참조하는 디렉터리에 `--authenticated-emails-file`이 없으면
실패한다. 이 가드 때문에 `--email-domain=*`를 되살리는 revert PR은 required
check에 걸려 머지되지 않는다(의도된 설계).

MLflow와 Grafana는 ArgoCD 자동 sync 대상이지만, 현재 `prune=false`,
`selfHeal=false`이다. 운영자가 실행한 `kubectl rollout restart`는 자동 sync가
되었다고 되돌려지지 않는다. 또한 operator가 주입한 live Kubernetes Secret은
Git 매니페스트의 관리 대상이 아니므로, sync가 Secret 값을 과거 값으로
덮어쓰지 않는다. 재시작으로 생성된 Pod는 그 시점의 live Secret을 읽고,
이후 매니페스트 변경으로 다시 생성되는 Pod도 같은 live Secret을 읽는다.
따라서 Secret 갱신 후에는 해당 서비스만 명시적으로 재시작하고, ArgoCD sync
상태와 로그인 smoke test를 함께 확인한다.

MLflow와 Kibana의 반영·복구 경로는 다르다.

| 서비스 | 정상 반영 | 잘못된 allowlist의 빠른 복구 |
|---|---|---|
| MLflow | `deploy/mlflow` 매니페스트를 main에 반영한 뒤 ArgoCD `mlflow` 자동 sync. operator 주입 `mlflow-oauth` Secret을 복원하고 `deployment/mlflow-oauth-proxy`를 rollout | 이전 Secret bundle을 먼저 복원·rollout하고, 필요하면 이전 매니페스트 commit으로 ArgoCD sync |
| Kibana | `terraform/admin/elastic-k8s`의 Deployment 변경을 `terraform apply`로 반영. operator 주입 `kibana-oauth` Secret은 별도 복원·rollout | 이전 Secret bundle을 먼저 복원·rollout하고, 필요하면 이전 Terraform commit을 apply. 뒤의 `elastic` basic 계정은 break-glass 경로 |

MLflow는 proxy가 유일한 UI 인증 계층이고 Kibana는 proxy 뒤에 `elastic` basic
인증이 한 겹 더 있으므로, 동일한 allowlist 오류라도 MLflow의 잔여 위험이 더
크다. 잘못된 Secret로 전원 잠금이 발생하면 각 서비스의 위 break-glass 경로를
사용한다.

## 롤백과 break-glass

| 서비스 | break-glass |
|---|---|
| ArgoCD | 로컬 `admin` 계정 유지. OIDC Secret/RBAC 변경 실패 시 `argocd-k8s` README의 admin 경로로 복구 |
| Airflow | 로컬 `admin` 계정 유지. OAuth Secret을 이전 세대로 복원하고 webserver rollout |
| MLflow/Kibana | proxy Secret을 이전 세대로 복원하고 proxy rollout. proxy를 우회하는 공개 endpoint는 만들지 않음 |
| Grafana | 사전 관리된 Grafana local admin 계정 유지. OAuth Secret을 이전 세대로 복원하고 Grafana rollout |

롤백 시에는 이전 client ID/secret의 쌍과 이전 allowlist를 함께 복원한다. OAuth
Secret 변경만으로 Terraform state를 직접 조작하거나 ArgoCD prune을 실행하지
않는다. Secret Manager 정본을 이전 값으로 되돌릴 때는 이전 payload를 안전한
파일에서 `gcloud secrets versions add <secret-id> --data-file=<previous-file>`로
새 version으로 다시 등록해 `latest`가 이전 세대가 되게 한다. 그 다음 K8s
Secret을 같은 세대로 복원하고 rollout한 뒤 `verify-oauth-clients.sh`를 실행한다.
실패한 version은 검증과 복구가 끝난 뒤에만 disable하며, 기존 version을 먼저
삭제하지 않는다.

현재 두 oauth2-proxy 매니페스트에는 `--cookie-expire`와 `--cookie-refresh`가
없다. v7.7.1 기본값은 cookie 만료 168시간(7일), refresh 비활성이다. 따라서
cookie-secret을 유지한 allowlist 변경은 기존 세션이 최대 기본 만료까지 남을 수
있고, 즉시 차단이 필요할 때는 cookie-secret 교체로 전원 재로그인을 유발하는
것을 기본 break-glass로 한다. 이 기본값은 [oauth2-proxy 세션 설정](https://github.com/oauth2-proxy/oauth2-proxy/blob/v7.7.1/docs/docs/configuration/sessions.md)의
공식 문서 기준이다.

## 검증 체크리스트

- [ ] 실제 payload가 Git, PR, 로그, Terraform state에 포함되지 않았다.
- [ ] Secret key 이름이 해당 제품의 현재 계약과 일치한다.
- [ ] allowlist key가 존재하고 비어 있지 않으며, 허용 계정 로그인과 제거 계정 거부를 확인했다. (`verify-oauth-clients.sh`는 allowlist 값의 존재·내용을 검사하지 않음. MLflow/Kibana는 #488 해결 전까지 이 항목을 완료 처리하지 않음)
- [ ] client ID와 secret이 같은 세대의 쌍이다.
- [ ] redirect URI와 port-forward/Bastion 경로가 기존 값과 일치한다.
- [ ] rollout status가 성공했다.
- [ ] 허용 계정 로그인과 미허용 계정 거부를 확인했다.
- [ ] break-glass 계정과 롤백 version을 확인했다.
- [ ] `verify-oauth-clients.sh` 출력에서 대상 서비스에 `ERR`·`WARN`이 없고, 다른 서비스의 `WARN`은 별도 추적했다.
- [ ] 변경 대상 서비스 외의 Secret과 workload를 변경하지 않았다.
