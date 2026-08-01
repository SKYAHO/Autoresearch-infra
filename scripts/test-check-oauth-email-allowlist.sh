#!/bin/sh
# check-oauth-email-allowlist.sh가 grep 실행 오류를 성공으로 오인하지 않는지 검증한다.
set -eu

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mkdir "$test_dir/bin"

printf '%s\n' '#!/bin/sh' \
  'case " $* " in' \
  '  *" -c "*) echo "simulated grep error" >&2; exit 2 ;;' \
  'esac' \
  'exec /usr/bin/grep "$@"' > "$test_dir/bin/grep"
chmod +x "$test_dir/bin/grep"

if PATH="$test_dir/bin:$PATH" "$repo_root/scripts/check-oauth-email-allowlist.sh" \
  > "$test_dir/output" 2>&1; then
  echo "FAIL: grep -c 오류가 allowlist 검사 성공으로 처리됨" >&2
  exit 1
fi

if /usr/bin/grep -q 'OK  MLflow: authenticated-emails-file 유지' "$test_dir/output"; then
  echo "FAIL: grep -c 오류에서 성공 메시지를 출력함" >&2
  exit 1
fi

echo "PASS: grep -c 오류는 allowlist 검사 실패로 처리됨"
