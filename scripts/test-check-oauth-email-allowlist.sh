#!/bin/sh
# check-oauth-email-allowlist.sh가 grep 실행 오류를 성공으로 오인하지 않는지 검증한다.
set -eu

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
real_grep="$(command -v grep)"
test -n "$real_grep" || { echo "FAIL: grep 명령을 찾을 수 없음" >&2; exit 1; }
export REAL_GREP="$real_grep"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir "$test_dir/bin"

printf '%s\n' '#!/bin/sh' \
  'case " $* " in' \
  '  *" -c "*) test "${SIMULATE_GREP_ERROR:-}" = count && { echo "simulated grep error" >&2; exit 2; } ;;' \
  '  *envFrom:*) test "${SIMULATE_GREP_ERROR:-}" = env-from && { echo "simulated grep error" >&2; exit 2; } ;;' \
  '  *authenticated-emails*) test "${SIMULATE_GREP_ERROR:-}" = mapping && { echo "simulated grep error" >&2; exit 2; } ;;' \
  'esac' \
  'exec "$REAL_GREP" "$@"' > "$test_dir/bin/grep"
chmod +x "$test_dir/bin/grep"

assert_grep_error_fails() {
  mode="$1"
  success_message="$2"
  if SIMULATE_GREP_ERROR="$mode" PATH="$test_dir/bin:$PATH" \
    "$repo_root/scripts/check-oauth-email-allowlist.sh" > "$test_dir/output" 2>&1; then
    echo "FAIL: grep 오류가 allowlist 검사 성공으로 처리됨 ($mode)" >&2
    exit 1
  fi
  if "$real_grep" -q "$success_message" "$test_dir/output"; then
    echo "FAIL: grep 오류에서 성공 메시지를 출력함 ($mode)" >&2
    exit 1
  fi
}

assert_grep_error_fails count 'OK  MLflow: authenticated-emails-file 유지'
assert_grep_error_fails env-from 'OK  MLflow: 명시적 Secret key 주입만 사용'
assert_grep_error_fails mapping 'OK  MLflow: authenticated-emails Secret 매핑 유지'

# 매핑 검사는 실패 원인을 "누락"과 "검사 실행 실패"로 구분해 보고해야 한다.
SIMULATE_GREP_ERROR=mapping PATH="$test_dir/bin:$PATH" \
  "$repo_root/scripts/check-oauth-email-allowlist.sh" > "$test_dir/output" 2>&1 || true
if ! "$real_grep" -q '매핑 검사 실행 실패' "$test_dir/output"; then
  echo "FAIL: 매핑 grep 오류를 '누락'과 구분해 보고하지 않음" >&2
  exit 1
fi

for step in check-oauth-email-allowlist.sh test-check-oauth-email-allowlist.sh; do
  if ! "$real_grep" -Fq "run: scripts/$step" "$repo_root/.github/workflows/lint.yml"; then
    echo "FAIL: scripts/$step가 lint workflow에 연결되지 않음" >&2
    exit 1
  fi
done

fixture="$test_dir/repo"
mkdir -p "$fixture/deploy/mlflow" "$fixture/terraform/admin/elastic-k8s"
cp "$repo_root/deploy/mlflow/oauth2-proxy.yaml" "$fixture/deploy/mlflow/"
cp "$repo_root/terraform/admin/elastic-k8s/oauth2_proxy.tf" \
  "$fixture/terraform/admin/elastic-k8s/"

printf '%s\n' '            - --email-domain=*' \
  >> "$fixture/deploy/mlflow/oauth2-proxy.yaml"
if OAUTH_ALLOWLIST_CHECK_ROOT="$fixture" \
  "$repo_root/scripts/check-oauth-email-allowlist.sh" > "$test_dir/output" 2>&1; then
  echo "FAIL: --email-domain 재도입을 잡지 못함" >&2
  exit 1
fi

sed -i.bak '$d' "$fixture/deploy/mlflow/oauth2-proxy.yaml"
rm "$fixture/deploy/mlflow/oauth2-proxy.yaml.bak"
cp "$fixture/terraform/admin/elastic-k8s/oauth2_proxy.tf" "$test_dir/oauth2_proxy.tf.orig"
printf '%s\n' '            dynamic "env_from" {' '              content {}' '            }' \
  >> "$fixture/terraform/admin/elastic-k8s/oauth2_proxy.tf"
if OAUTH_ALLOWLIST_CHECK_ROOT="$fixture" \
  "$repo_root/scripts/check-oauth-email-allowlist.sh" > "$test_dir/output" 2>&1; then
  echo "FAIL: dynamic env_from을 잡지 못함" >&2
  exit 1
fi
cp "$test_dir/oauth2_proxy.tf.orig" "$fixture/terraform/admin/elastic-k8s/oauth2_proxy.tf"

# CLI 플래그가 아닌 표기로 같은 우회가 재도입되는 경우. 두 scan root 모두 이미
# Helm values를 담고 있어 이 표기가 자연스럽게 들어올 수 있다.
assert_scan_rejects() {
  target="$1"
  content="$2"
  description="$3"
  mkdir -p "$(dirname -- "$fixture/$target")"
  printf '%s\n' "$content" > "$fixture/$target"
  if OAUTH_ALLOWLIST_CHECK_ROOT="$fixture" \
    "$repo_root/scripts/check-oauth-email-allowlist.sh" > "$test_dir/output" 2>&1; then
    echo "FAIL: $description을 잡지 못함" >&2
    exit 1
  fi
  rm "$fixture/$target"
}

assert_scan_rejects 'deploy/oauth2-proxy/values.yaml' \
  'extraArgs:
  email-domain: "*"' \
  'Helm extraArgs의 email-domain 키 표기'
assert_scan_rejects 'terraform/admin/elastic-k8s/helm-values/oauth2-proxy.yaml' \
  'config:
  configFile: |
    email_domains = ["*"]' \
  'config file의 email_domains 키 표기'

# 정상 상태로 되돌린 fixture는 다시 통과해야 한다(위 케이스가 항진 실패가 아님을 증명).
if ! OAUTH_ALLOWLIST_CHECK_ROOT="$fixture" \
  "$repo_root/scripts/check-oauth-email-allowlist.sh" > "$test_dir/output" 2>&1; then
  echo "FAIL: 정상 fixture가 통과하지 못함" >&2
  cat "$test_dir/output" >&2
  exit 1
fi

echo "PASS: grep 오류·domain 표기 우회는 allowlist 검사 실패로 처리됨"
