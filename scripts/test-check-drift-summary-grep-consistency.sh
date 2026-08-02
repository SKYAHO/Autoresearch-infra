#!/bin/sh
# check-drift-summary-grep-consistency.sh가 실제로 불일치를 잡는지 검증한다.
set -eu

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
check="$repo_root/scripts/check-drift-summary-grep-consistency.sh"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fixture="$test_dir/repo"
mkdir -p "$fixture/.github/workflows"
line="          grep -E '^Plan: [0-9]|^No changes\\.' \"\$d/plan.txt\""

printf '%s\n' "$line" > "$fixture/.github/workflows/apply.yml"
printf '%s\n' "$line" >> "$fixture/.github/workflows/apply.yml"
printf '%s\n' "$line" > "$fixture/.github/workflows/terraform-plan.yml"
printf '%s\n' "$line" > "$fixture/.github/workflows/terraform-drift.yml"

if ! DRIFT_SUMMARY_CHECK_ROOT="$fixture" "$check" > "$test_dir/output" 2>&1; then
  echo "FAIL: 4곳이 동일한 정상 fixture가 통과하지 못함" >&2
  cat "$test_dir/output" >&2
  exit 1
fi

# 4곳 중 1곳만 정규식이 밀린 경우.
printf '%s\n' "          grep -E '^Plan: [0-9]|^No changes\\.x' \"\$d/plan.txt\"" \
  > "$fixture/.github/workflows/terraform-drift.yml"
if DRIFT_SUMMARY_CHECK_ROOT="$fixture" "$check" > "$test_dir/output" 2>&1; then
  echo "FAIL: 정규식 불일치를 잡지 못함" >&2
  exit 1
fi

# apply.yml의 두 곳 중 1곳이 통째로 없어진 경우(개수 자체가 4가 아님).
printf '%s\n' "$line" > "$fixture/.github/workflows/terraform-drift.yml"
printf '%s\n' "$line" > "$fixture/.github/workflows/apply.yml"
if DRIFT_SUMMARY_CHECK_ROOT="$fixture" "$check" > "$test_dir/output" 2>&1; then
  echo "FAIL: 발견 개수가 4가 아닌 경우를 잡지 못함" >&2
  exit 1
fi

for step in check-drift-summary-grep-consistency.sh test-check-drift-summary-grep-consistency.sh; do
  if ! grep -Fq "run: scripts/$step" "$repo_root/.github/workflows/lint.yml"; then
    echo "FAIL: scripts/$step가 lint workflow에 연결되지 않음" >&2
    exit 1
  fi
done

echo "PASS: plan 요약 allowlist grep -E 4곳 불일치를 잡음"
