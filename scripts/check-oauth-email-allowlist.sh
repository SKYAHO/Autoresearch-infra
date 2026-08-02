#!/bin/sh
# #488 oauth2-proxy 이메일 allowlist 설정 회귀 검증.
# 실제 Secret 값이나 클러스터에 접근하지 않고, 두 서비스가
# authenticated-emails-file만 이메일 제한으로 사용하도록 정적 검사한다.
set -eu

# 어느 작업 디렉터리에서 실행해도 저장소 기준으로 검사한다. self-test는
# OAUTH_ALLOWLIST_CHECK_ROOT로 격리 fixture를 지정할 수 있다.
script_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
repo_root="${OAUTH_ALLOWLIST_CHECK_ROOT:-$script_root}"
if ! cd "$repo_root"; then
  echo "ERR 검사 root에 접근할 수 없음 ($repo_root)" >&2
  exit 1
fi

FAIL=0
email_domain_pattern='--email-domain([^[:alnum:]-]|$)'

# if 조건의 grep 실패는 errexit 대상이 아니므로, else에서 다른 명령보다 먼저
# $?를 저장해 exit 1(정상 비매치)과 exit 2 이상(검사 오류)을 구분한다.
check_target() {
  label="$1"
  file="$2"
  email_file_pattern="$3"
  if [ ! -f "$file" ]; then
    echo "ERR $label: 검사 대상 파일이 없음 ($file)"
    FAIL=1
    return
  fi

  if grep -Eq -- "$email_domain_pattern" "$file"; then
    echo "ERR $label: --email-domain 인자가 남아 있음 ($file)"
    FAIL=1
  else
    grep_status=$?
    if [ "$grep_status" -eq 1 ]; then
      echo "OK  $label: --email-domain 인자 없음"
    else
      echo "ERR $label: --email-domain 검사 실행 실패 (grep exit=$grep_status)"
      FAIL=1
    fi
  fi

  if count="$(grep -E -c -- "$email_file_pattern" "$file")"; then
    grep_status=0
  else
    grep_status=$?
  fi
  if [ "$grep_status" -ne 0 ] && [ "$grep_status" -ne 1 ]; then
    echo "ERR $label: authenticated-emails-file 검사 실행 실패 (grep exit=$grep_status)"
    FAIL=1
    return
  fi
  case "$count" in
    ''|*[!0-9]*)
      echo "ERR $label: authenticated-emails-file 검사 결과가 숫자가 아님"
      FAIL=1
      return
      ;;
  esac
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

  for pattern in "$key_pattern" "$path_pattern"; do
    if grep -Eq "$pattern" "$file"; then
      continue
    fi
    grep_status=$?
    if [ "$grep_status" -eq 1 ]; then
      echo "ERR $label: authenticated-emails Secret 매핑 누락"
    else
      echo "ERR $label: authenticated-emails 매핑 검사 실행 실패 (grep exit=$grep_status)"
    fi
    FAIL=1
    return
  done
  echo "OK  $label: authenticated-emails Secret 매핑 유지"
}

check_no_env_from() {
  label="$1"
  file="$2"
  pattern="$3"

  if grep -Eq "$pattern" "$file"; then
    echo "ERR $label: envFrom 기반 Secret 전체 주입은 허용하지 않음 ($file)"
    FAIL=1
  else
    grep_status=$?
    if [ "$grep_status" -eq 1 ]; then
      echo "OK  $label: 명시적 Secret key 주입만 사용"
    else
      echo "ERR $label: envFrom 검사 실행 실패 (grep exit=$grep_status)"
      FAIL=1
    fi
  fi
}

check_target "MLflow" "deploy/mlflow/oauth2-proxy.yaml" \
  '^[[:space:]]*-[[:space:]]+"?--authenticated-emails-file=/etc/oauth2-proxy/authenticated-emails"?[[:space:]]*$'
check_target "Kibana" "terraform/admin/elastic-k8s/oauth2_proxy.tf" \
  '^[[:space:]]*"--authenticated-emails-file=/etc/oauth2-proxy/authenticated-emails",?[[:space:]]*$'
check_mapping "MLflow" "deploy/mlflow/oauth2-proxy.yaml" \
  'key:[[:space:]]*authenticated-emails' \
  'path:[[:space:]]*authenticated-emails'
check_mapping "Kibana" "terraform/admin/elastic-k8s/oauth2_proxy.tf" \
  'key[[:space:]]*=[[:space:]]*"authenticated-emails"' \
  'path[[:space:]]*=[[:space:]]*"authenticated-emails"'
check_no_env_from "MLflow" "deploy/mlflow/oauth2-proxy.yaml" '^[[:space:]]*envFrom:'
check_no_env_from "Kibana" "terraform/admin/elastic-k8s/oauth2_proxy.tf" \
  '^[[:space:]]*(env_from[[:space:]]*\{|dynamic[[:space:]]+"env_from"[[:space:]]*\{)'

# 대상이 늘어날 때 domain allowlist나 환경변수 기반 우회 설정이 조용히
# 추가되지 않도록 deploy/와 terraform/의 배포 manifest·설정을 검사한다.
# 실제 Secret 값은 정적으로 읽을 수 없으므로, 운영 preflight에서 별도로 확인한다.
# 새 oauth2-proxy 대상은 check_target/check_mapping/check_no_env_from에 명시적으로
# 등록하고, k8s/·charts/ 등 새 경로면 이 scan root도 확장해야 한다.
#
# 전역 검사는 같은 설정의 세 표기를 모두 잡는다: CLI 플래그(`--email-domain`),
# 환경변수(`OAUTH2_PROXY_EMAIL_DOMAINS`), 그리고 Helm values의 `extraArgs`나
# config file에서 쓰는 키 표기(`email-domain:` / `email_domains =`). 두 scan root에
# 이미 Helm values가 있어(deploy/*/values.yaml, terraform/admin/*/helm-values/*.yaml)
# 플래그 표기만 막으면 동일한 우회가 조용히 재도입될 수 있다. `email` 뒤가 `s`인
# `authenticated-emails-file`은 `email[-_]domain`과 매칭되지 않아 오탐되지 않는다.
# 다만 미등록 대상의 envFrom·동적 값 주입으로 만들어지는 runtime 환경변수까지
# 자동으로 식별하지는 않는다.
# GitHub runner 기본 명령인 grep만 사용하며 문서와 Terraform provider cache는 제외한다.
if grep -REn --exclude='*.md' \
  --exclude-dir='.terraform' \
  -- "$email_domain_pattern|OAUTH2_PROXY_EMAIL_DOMAINS|(^|[^[:alnum:]_])email[-_]domains?[[:space:]]*[:=]" deploy terraform; then
  echo "ERR 저장소 manifest/Terraform 설정에 email-domain 또는 OAUTH2_PROXY_EMAIL_DOMAINS가 남아 있음"
  FAIL=1
else
  grep_status=$?
  if [ "$grep_status" -eq 1 ]; then
    echo "OK  저장소 manifest/Terraform 설정: email-domain 환경설정 없음"
  else
    echo "ERR email-domain 회귀 검사 실행 실패 (grep exit=$grep_status)"
    FAIL=1
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  echo "결과: oauth2-proxy 이메일 allowlist 검증 실패"
  exit 1
fi

echo "결과: oauth2-proxy 이메일 allowlist 검증 통과"
