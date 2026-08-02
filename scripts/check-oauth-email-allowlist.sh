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
discovery_fail_marker="$(mktemp)"
rm -f "$discovery_fail_marker"
trap 'rm -f "$discovery_fail_marker"' EXIT

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

  # $?는 반드시 else 절 첫 명령으로 읽는다. else 없는 if 복합 명령의 종료 상태는
  # 조건이 거짓일 때 0이라, fi 다음에서 읽으면 grep의 1/2와 무관하게 항상 0이 된다.
  for pattern in "$key_pattern" "$path_pattern"; do
    if grep -Eq "$pattern" "$file"; then
      continue
    else
      grep_status=$?
      if [ "$grep_status" -eq 1 ]; then
        echo "ERR $label: authenticated-emails Secret 매핑 누락"
      else
        echo "ERR $label: authenticated-emails 매핑 검사 실행 실패 (grep exit=$grep_status)"
      fi
      FAIL=1
      return
    fi
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
# 등록하고, k8s/·charts/ 등 새 경로면 이 scan root도 확장해야 한다. 등록을 잊는
# 경우는 아래 자동 발견 검사가 잡는다.
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
  echo "ERR 위 경로에 email-domain 계열 설정이 있음 — oauth2-proxy 설정이면 제거하고, oauth2-proxy와 무관한 email_domain 키라면 이 스캔의 제외 조건(--exclude 또는 경로 한정)을 명시적으로 추가할 것"
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

# 위 대상별 검사는 등록된 2개 파일만 본다. 새 서비스가 --email-domain도
# --authenticated-emails-file도 넣지 않으면 어떤 검사에도 걸리지 않는다.
#
# 그 상태의 실제 동작은 fail-open이 아니라 **fail-closed**다. v7.7.1
# newValidatorImpl은 domains가 비면 도메인 판정이 false, usersFile이 비면
# UserMap이 빈 맵이라 파일 판정도 false, allowAll도 false이므로 모든 이메일이
# 거부된다. 따라서 이 검사가 막는 것은 "무방비 노출"이 아니라 ① 전원 차단으로
# 서비스가 죽는 배포와 ② 그 증상을 --email-domain=*로 "고쳐" #488을 되살리는
# 흔한 대응이다. 모든 oauth2-proxy 대상이 allowlist를 명시하도록 강제해 두 경로를
# 함께 막는다. 대상별 상세 검사(매핑·envFrom)를 대체하지는 않는다.
#
# Terraform은 이미지 기본값(variables.tf)과 args(oauth2_proxy.tf)가 다른 파일에
# 있으므로 파일 단위가 아니라 디렉터리 단위로 판정한다.
# 이미지 표기는 upstream quay·GAR 미러·digest 고정을 모두 포괄하도록
# `oauth2-proxy` 뒤에 태그(:) 또는 digest(@)가 오는 형태로 잡는다.
#
# 알려진 한계 두 가지(둘 다 의도적 trade-off):
#  - 판정 단위가 디렉터리다. Terraform은 이미지 기본값(variables.tf)과
#    args(oauth2_proxy.tf)가 다른 파일이라 파일 단위로는 오탐이 난다. 대신 한
#    디렉터리에 oauth2-proxy 매니페스트가 둘 이상이고 그중 하나에만 flag가 있으면
#    통과한다. 새 대상은 여전히 check_target에 명시 등록하는 것이 정본이다.
#  - 이미지 참조 방식이 또 바뀌면(예: Helm chart의 repository/tag 분리 표기)
#    이 패턴도 함께 갱신해야 한다. 발견 0건이면 아래에서 실패시켜 침묵을 막는다.
discovered_dirs="$(grep -RIlE --exclude='*.md' --exclude-dir='.terraform' \
  -- '(^|[^[:alnum:]_-])oauth2-proxy[:@]' deploy terraform 2>/dev/null \
  | while IFS= read -r f; do dirname -- "$f"; done | sort -u || true)"
if [ -n "$discovered_dirs" ]; then
  printf '%s\n' "$discovered_dirs" | while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    if grep -REq --exclude='*.md' --exclude-dir='.terraform' \
      -- '--authenticated-emails-file=' "$dir"; then
      echo "OK  자동 발견: $dir — authenticated-emails-file 지정됨"
    else
      grep_status=$?
      if [ "$grep_status" -eq 1 ]; then
        echo "ERR 자동 발견: $dir — oauth2-proxy 대상인데 authenticated-emails-file이 없음"
      else
        echo "ERR 자동 발견: $dir — 검사 실행 실패 (grep exit=$grep_status)"
      fi
      # subshell(파이프)이라 FAIL 대입이 부모로 전파되지 않는다. 마커 파일로 알린다.
      : > "$discovery_fail_marker"
    fi
  done
  if [ -f "$discovery_fail_marker" ]; then
    FAIL=1
  fi
else
  echo "ERR oauth2-proxy 이미지를 참조하는 파일을 찾지 못함 — scan root 또는 이미지 표기를 확인"
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "결과: oauth2-proxy 이메일 allowlist 검증 실패"
  exit 1
fi

echo "결과: oauth2-proxy 이메일 allowlist 검증 통과"
