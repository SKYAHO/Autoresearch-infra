#!/bin/sh
# #488 oauth2-proxy 이메일 allowlist 설정 회귀 검증.
# 실제 Secret 값이나 클러스터에 접근하지 않고, 두 서비스가
# authenticated-emails-file만 이메일 제한으로 사용하도록 정적 검사한다.
set -eu

FAIL=0

check_target() {
  label="$1"
  file="$2"
  if grep -Fq -- '--email-domain=*' "$file"; then
    echo "ERR $label: --email-domain=*가 남아 있음 ($file)"
    FAIL=1
  else
    echo "OK  $label: --email-domain=* 없음"
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

if [ "$FAIL" -ne 0 ]; then
  echo "결과: oauth2-proxy 이메일 allowlist 검증 실패"
  exit 1
fi

echo "결과: oauth2-proxy 이메일 allowlist 검증 통과"
