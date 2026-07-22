# ArgoCD Google(Gmail) OIDC 로그인 설계 (#289)

## 배경·목적

ArgoCD UI는 현재 port-forward(`localhost:8443`) + 로컬 `admin` 단일 계정으로만
접근한다. admin 비밀번호 공유는 개인별 감사·회수가 안 되고 팀원 권한을 나눌 수
없다. Airflow(#232)·Grafana(#155)·MLflow(#232)가 쓰는 **내부 UI Google 로그인 +
허용 이메일 권한 분리** 패턴을 ArgoCD에도 적용한다.

## 결정

- **Dex 없이 ArgoCD 내장 직접 OIDC**로 Google을 연결한다. dev 규모(팀원 5명)에서
  Dex 파드는 과하고, group claim이 필요 없으므로 이메일 기준 RBAC로 충분하다.
  `dex.enabled: false` 유지.
- **git-safe**: client id/secret은 values·Terraform state에 두지 않는다.
  `oidc.config`는 `$argocd-google-oidc:clientId` / `$argocd-google-oidc:clientSecret`
  참조만 담고, 실제 값은 별도 Secret `argocd-google-oidc`(label
  `app.kubernetes.io/part-of=argocd`)로 Secret Manager에서 주입한다(#213 패턴).
- **허용 이메일은 로컬 `terraform.tfvars`에만.** `argocd_admin_user_emails`,
  `argocd_readonly_user_emails` 변수를 `templatefile()`로 `policy.csv`에 렌더한다.
  Grafana/Airflow allowlist와 동일하게 PII를 Git에 두지 않는다.
- **RBAC**: `policy.default: ""`(거부) + `scopes: "[email]"`. 목록 밖 계정은
  로그인해도 권한이 없다.
- **로컬 `admin` 유지**: CLI·자동화·break-glass. SSO는 UI 로그인용이다.
- **redirect URI 불변**: port-forward → `https://localhost:8443` 접근이라 redirect
  URI는 `https://localhost:8443/auth/callback` 고정(Airflow/MLflow 터널 패턴).

## 왜 이 방식인가

| 대안 | 기각 사유 |
|---|---|
| oauth2-proxy 앞단(Airflow/MLflow 방식) | ArgoCD는 자체 OIDC/토큰 체계가 있어 앞단 proxy는 CLI/API 인증과 충돌. 네이티브 OIDC가 정석 |
| Dex + Google connector | Dex 파드 추가. group claim이 필요 없는 dev에선 과함 |
| client id/secret을 values에 | 공개 저장소 + Terraform state 노출. git-safe 원칙 위반 |

## 영향·리스크

- 리소스 변경 없음(비용 0). 인증 경로만 추가. 로컬 admin 회귀 없음.
- self-signed cert + `https://localhost:8443` OIDC는 브라우저 인증서 경고를
  동반하나 dev 내부 경로 특성상 허용(기존 UI 접근과 동일).
- Secret `argocd-google-oidc` 미주입 상태로 apply하면 oidc.config가 참조를 못 찾아
  SSO 로그인만 실패하고 로컬 admin은 정상 → 안전한 부분 실패.

## 롤백

`oidc.config`·RBAC 관련 변수/템플릿을 되돌려 apply하면 로컬 admin 단일 계정으로
복귀한다. `argocd-google-oidc` Secret과 Google OAuth client는 별도 삭제한다.
