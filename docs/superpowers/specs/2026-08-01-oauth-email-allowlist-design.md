# oauth2-proxy 이메일 allowlist 우회 수정 설계

## 배경

MLflow와 Kibana의 oauth2-proxy 설정은 Google 로그인 뒤 허용 이메일 파일을
사용하도록 작성되어 있지만, 동시에 `--email-domain=*`를 지정하고 있습니다.
oauth2-proxy v7.7.1에서는 `*`가 모든 이메일 도메인을 허용하는 모드가 되어
이메일 파일의 거부 결과를 다시 허용할 수 있습니다. 따라서 현재 설정은
의도한 이메일 allowlist 경계를 보장하지 않습니다.

MLflow oauth2-proxy는 내부 LoadBalancer VIP를 통해 VPC에서 접근할 수 있고,
Kibana oauth2-proxy는 Terraform admin root에서 관리되므로, 두 경로 모두
인증 설정을 수정해야 합니다.

## 목표

- MLflow와 Kibana에서 `--authenticated-emails-file`을 유일한 이메일 기반
  접근 제한으로 사용합니다.
- 허용 목록 Secret의 주입 경로와 oauth2-proxy 버전은 변경하지 않습니다.
- 변경 후 정적 검증으로 저장소의 배포 manifest와 Terraform 설정에
  `--email-domain` 또는 `OAUTH2_PROXY_EMAIL_DOMAINS`가 남지 않았음을 확인합니다.

## 변경 범위

### MLflow

- 대상: `deploy/mlflow/oauth2-proxy.yaml`
- `--email-domain=*`를 제거합니다.
- `--authenticated-emails-file`과 Secret volume/key 매핑은 유지합니다.
- 배포 반영은 ArgoCD sync 이후 rollout 상태 확인으로 검증합니다.

### Kibana

- 대상: `terraform/admin/elastic-k8s/oauth2_proxy.tf`
- `--email-domain=*`를 제거합니다.
- `--authenticated-emails-file`과 Secret volume/key 매핑은 유지합니다.
- 배포 반영은 Terraform apply 이후 rollout 상태 확인으로 검증합니다.

### 문서 및 검증

- 두 서비스의 운영 문서에서 allowlist의 실제 동작 경로와 배포 주체를
  변경된 설정에 맞게 갱신합니다.
- 설정 회귀를 잡는 정적 검증을 추가하거나 기존 검증 패턴에 포함합니다.
- MLflow는 ArgoCD 자동 sync이므로 **PR 머지 전**, Kibana는 Terraform apply 전에
  operator가 값 비노출 Secret preflight를 수행하고 `entries=N` 결과만 PR에
  기록합니다. 이 작업에서는 클러스터 접근 및 GCP apply를 수행하지 않습니다.

## 비목표

- Google OAuth client, cookie secret, authenticated-emails Secret의 값 변경
- Service, Internal LoadBalancer VIP, NetworkPolicy, IAM 권한 변경
- oauth2-proxy 이미지 버전 업그레이드
- MLflow 또는 Kibana 애플리케이션 인증 방식 변경
- `terraform apply`, ArgoCD sync 등 실제 운영 반영

## 보안 및 운영 영향

- 변경 후 Google 로그인 성공만으로는 통과하지 못하며,
  `authenticated-emails` 파일에 있는 이메일만 oauth2-proxy를 통과합니다.
- MLflow 내부 VIP의 VPC 접근성 자체는 그대로이므로, 네트워크 경계와
  이메일 allowlist가 함께 방어 계층으로 유지됩니다.
- oauth2-proxy v7.7.1은 `authenticated-emails-file`을 CSV로 읽고 각 행을
  trim/lowercase한 정확한 이메일 문자열로 저장합니다. `--email-domain`을 넘기지
  않으면 도메인 판정은 false이고 파일의 정확한 이메일 일치 결과가 최종 판정이 된다.
  두 설정은 AND가 아니라 OR로 결합되므로, `--email-domain=example.com`도 해당
  도메인의 모든 계정을 허용하며 `*`는 전체를 허용한다. 따라서 두 서비스에는
  domain 인자와 동등한 환경변수를 모두 두지 않는다.
- 빈 파일, `*`, `@example.com`처럼 실제 이메일과 일치하지 않는 한 줄은 proxy를
  정상 기동시키지만 모든 로그인을 403으로 거부한다. CRLF와 앞뒤 공백은 trim되어
  정확한 이메일이라면 정상 허용된다. 현재 manifest처럼 Secret volume `items`에
  `authenticated-emails` 키를 지정한 경우 그 키가 없으면 kubelet이
  `CreateContainerConfigError`로 container 시작을 막는다. 다른 수동 구성에서
  마운트 파일 자체가 없으면 oauth2-proxy의 파일 로드가 fatal로 종료된다.
- 현재 두 manifest는 `client-id`·`client-secret`·`cookie-secret`만 명시적
  `secretKeyRef`로 주입하고 `envFrom`을 쓰지 않으므로, operator Secret에 추가한
  임의 키가 `OAUTH2_PROXY_EMAIL_DOMAINS`로 적용될 수 없다. CI는 두 대상의
  `envFrom` 부재도 확인한다. 다만 CI는 runtime Secret payload 자체를 읽지 않으므로
  허용 이메일 값은 운영 preflight와 live smoke test로 검증한다. 새 oauth2-proxy
  대상은 세 대상 검사 함수에 명시적으로 등록해야 하며, 전역 검사는 미등록 대상의
  `envFrom`만으로 주입되는 runtime 환경변수까지 자동 식별하지 않는다.
- 위 판정은 v7.7.1의 [validator 구현](https://github.com/oauth2-proxy/oauth2-proxy/blob/v7.7.1/validator.go#L46-L101)에
  근거합니다. `*`는 `allowAll`을 켜서 파일 판정 뒤 최종 결과를 허용하지만,
  wildcard를 제거하면 도메인 판정 실패 시 파일의 정확한 이메일 일치 결과가
  사용됩니다.
- 허용 목록에서 제거한 사용자는 새 allowlist가 반영된 뒤 다음 보호된 요청에서
  차단된다. v7.7.1의 [`getAuthenticatedSession`](https://github.com/oauth2-proxy/oauth2-proxy/blob/v7.7.1/oauthproxy.go#L1097-L1125)은 요청마다
  `p.Validator(session.Email)`를 호출하며, 실패하면 session cookie를 지우고
  `ErrAccessDenied`(403)를 반환한다. Secret projected volume 교체는
  [`WatchFileForUpdates`](https://github.com/oauth2-proxy/oauth2-proxy/blob/v7.7.1/pkg/watcher/watcher.go#L12-L70)가 감시하지만, 운영 절차는 모든 pod에서
  새 목록을 확정하기 위해 Secret 갱신 뒤 rollout restart와 완료 확인을 요구한다.
  계정 제거에는 cookie-secret 회전이 필요 없고, cookie 유출 대응 또는 전원 강제
  로그아웃 때만 별도 회전한다.

## 롤백

1. 변경된 manifest/Terraform 파일을 직전 승인 커밋으로 되돌립니다.
2. MLflow는 ArgoCD에서 되돌린 manifest를 sync하고 Deployment rollout을
   확인합니다.
3. Kibana는 Terraform plan으로 변경 범위를 확인한 뒤 승인된 apply를
   수행하고 Deployment rollout을 확인합니다.
4. 롤백 시에도 Secret 값이나 state를 출력하지 않습니다.

## 검증 기준

- `git diff --check` 통과
- MLflow YAML 파싱 및 oauth2-proxy args 검증
- Kibana Terraform fmt/validate 통과
- 저장소의 배포 manifest와 Terraform 설정에 `--email-domain` 및
  `OAUTH2_PROXY_EMAIL_DOMAINS`가 없고
  `--authenticated-emails-file`이 정확히 유지됨
- 변경 diff에 Secret 값, tfvars, state, IAM/네트워크 변경이 없음
- MLflow PR 머지 전 및 Kibana apply 전, operator가 Secret preflight의
  `entries=N` 결과를 값 노출 없이 기록함
- 실제 반영 후 별도 운영자가 허용/비허용 계정 smoke test를 수행할 수
  있도록 명령과 기대 결과가 PR에 기록됨
