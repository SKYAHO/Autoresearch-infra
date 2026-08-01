#!/bin/sh
# #488 oauth2-proxy 이메일 allowlist 설정 회귀 검증.
# 실제 Secret 값이나 클러스터에 접근하지 않고, 두 서비스가
# authenticated-emails-file만 이메일 제한으로 사용하도록 정적 검사한다.
set -eu

FAIL=0

check_target() {
  label="$1"
  file="$2"
  if [ ! -f "$file" ]; then
    echo "ERR $label: 검사 대상 파일이 없음 ($file)"
    FAIL=1
    return
  fi

  if grep -Eq -- '--email-domain([[:space:]]|=|$)' "$file"; then
    echo "ERR $label: --email-domain 인자가 남아 있음 ($file)"
    FAIL=1
  else
    echo "OK  $label: --email-domain 인자 없음"
  fi

  count="$(grep -F -c -- '--authenticated-emails-file=/etc/oauth2-proxy/authenticated-emails' "$file" || true)"
  if [ "$count" -ne 1 ]; then
    echo "ERR $label: authenticated-emails-file 인자 수가 1이 아님 ($count)"
    FAIL=1
  else
    echo "OK  $label: authenticated-emails-file 유지"
  fi
}

check_mapping() {
  label="$1"
  file="$2"
  key_pattern="$3"
  path_pattern="$4"

  if grep -Eq "$key_pattern" "$file" && grep -Eq "$path_pattern" "$file"; then
    echo "OK  $label: authenticated-emails Secret 매핑 유지"
  else
    echo "ERR $label: authenticated-emails Secret 매핑 누락"
    FAIL=1
  fi
}

check_target "MLflow" "deploy/mlflow/oauth2-proxy.yaml"
check_target "Kibana" "terraform/admin/elastic-k8s/oauth2_proxy.tf"
check_mapping "MLflow" "deploy/mlflow/oauth2-proxy.yaml" \
  'key:[[:space:]]*authenticated-emails' \
  'path:[[:space:]]*authenticated-emails'
check_mapping "Kibana" "terraform/admin/elastic-k8s/oauth2_proxy.tf" \
  'key[[:space:]]*=[[:space:]]*"authenticated-emails"' \
  'path[[:space:]]*=[[:space:]]*"authenticated-emails"'

# 대상이 늘어날 때 domain allowlist나 환경변수 기반 우회 설정이 조용히
# 추가되지 않도록 인프라 설정 전체를 검사한다. 문서/이 스크립트는 제외한다.
if ! command -v rg >/dev/null 2>&1; then
  echo "ERR rg가 없어 email-domain 회귀를 검사할 수 없음"
  FAIL=1
elif rg -n --hidden --glob '!*.md' --glob '!scripts/check-oauth-email-allowlist.sh' \
  -- '--email-domain([[:space:]]|=|$)|OAUTH2_PROXY_EMAIL_DOMAINS' deploy terraform/admin; then
  echo "ERR 인프라 설정에 email-domain 또는 OAUTH2_PROXY_EMAIL_DOMAINS가 남아 있음"
  FAIL=1
else
  rg_status=$?
  if [ "$rg_status" -eq 1 ]; then
    echo "OK  인프라 설정 전체: email-domain 환경설정 없음"
  else
    echo "ERR email-domain 회귀 검사 실행 실패 (rg exit=$rg_status)"
    FAIL=1
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  echo "결과: oauth2-proxy 이메일 allowlist 검증 실패"
  exit 1
fi

echo "결과: oauth2-proxy 이메일 allowlist 검증 통과"
