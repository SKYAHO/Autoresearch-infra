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
- 변경 후 정적 검증으로 두 서비스에 `--email-domain=*`가 남지 않았음을
  확인합니다.

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
- PR에는 허용 계정과 비허용 계정의 live smoke test 절차를 기록하되,
  이 작업에서는 클러스터 접근 및 GCP apply를 수행하지 않습니다.

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
- 허용 목록에서 제거한 사용자의 기존 oauth2-proxy 세션은 cookie 만료 전까지
  남을 수 있으므로, 운영 smoke test는 새 private window 또는 cookie 삭제
  후 수행합니다.

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
- 두 대상에 `--email-domain=*`가 없고
  `--authenticated-emails-file`이 정확히 유지됨
- 변경 diff에 Secret 값, tfvars, state, IAM/네트워크 변경이 없음
- 실제 반영 후 별도 운영자가 허용/비허용 계정 smoke test를 수행할 수
  있도록 명령과 기대 결과가 PR에 기록됨
