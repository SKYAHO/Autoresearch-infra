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
# 두 경우를 각각 확인해야 구분이 실제로 성립함을 보장한다 — 한쪽만 보면
# 어느 분기도 도달 불가한 구현(else 없는 if 뒤에서 $?를 읽는 실수 등)에서도 통과한다.
SIMULATE_GREP_ERROR=mapping PATH="$test_dir/bin:$PATH" \
  "$repo_root/scripts/check-oauth-email-allowlist.sh" > "$test_dir/output" 2>&1 || true
if ! "$real_grep" -q '매핑 검사 실행 실패' "$test_dir/output"; then
  echo "FAIL: 매핑 grep 오류를 '검사 실행 실패'로 보고하지 않음" >&2
  exit 1
fi
if "$real_grep" -q 'authenticated-emails Secret 매핑 누락' "$test_dir/output"; then
  echo "FAIL: grep 실행 오류를 '매핑 누락'으로 잘못 보고함" >&2
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

# 실제 매핑 누락은 "매핑 누락"으로 보고되어야 한다. 위 grep 오류 케이스와 함께
# 봐야 두 분기가 모두 도달 가능함이 증명된다.
cp "$fixture/deploy/mlflow/oauth2-proxy.yaml" "$test_dir/mlflow-proxy.yaml.orig"
"$real_grep" -v 'key: authenticated-emails' "$test_dir/mlflow-proxy.yaml.orig" \
  > "$fixture/deploy/mlflow/oauth2-proxy.yaml"
if OAUTH_ALLOWLIST_CHECK_ROOT="$fixture" \
  "$repo_root/scripts/check-oauth-email-allowlist.sh" > "$test_dir/output" 2>&1; then
  echo "FAIL: authenticated-emails 매핑 누락을 잡지 못함" >&2
  exit 1
fi
if ! "$real_grep" -q 'MLflow: authenticated-emails Secret 매핑 누락' "$test_dir/output"; then
  echo "FAIL: 실제 매핑 누락을 '매핑 누락'으로 보고하지 않음" >&2
  cat "$test_dir/output" >&2
  exit 1
fi
cp "$test_dir/mlflow-proxy.yaml.orig" "$fixture/deploy/mlflow/oauth2-proxy.yaml"

# 등록되지 않은 새 oauth2-proxy 대상이 allowlist를 아예 안 넣은 경우.
# 대상별 검사는 두 파일만 보므로, 자동 발견 검사가 이를 잡아야 한다.
mkdir -p "$fixture/deploy/newsvc"
cat > "$fixture/deploy/newsvc/oauth2-proxy.yaml" <<'NEWSVC'
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: oauth2-proxy
          image: quay.io/oauth2-proxy/oauth2-proxy:v7.7.1
          args:
            - --provider=google
NEWSVC
if OAUTH_ALLOWLIST_CHECK_ROOT="$fixture" \
  "$repo_root/scripts/check-oauth-email-allowlist.sh" > "$test_dir/output" 2>&1; then
  echo "FAIL: allowlist 없는 미등록 oauth2-proxy 대상을 잡지 못함" >&2
  exit 1
fi
if ! "$real_grep" -q 'authenticated-emails-file이 없음' "$test_dir/output"; then
  echo "FAIL: 미등록 대상 누락을 자동 발견 사유로 보고하지 않음" >&2
  cat "$test_dir/output" >&2
  exit 1
fi
rm -rf "$fixture/deploy/newsvc"

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
