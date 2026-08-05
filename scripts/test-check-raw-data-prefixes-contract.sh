#!/bin/sh
# check-raw-data-prefixes-contract.sh가 trailing slash 유실·alias 불일치·IAM 조건
# 회귀를 실제로 잡는지 검증한다.
set -eu

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

fixture="$test_dir/repo"
mkdir -p "$fixture/terraform/envs/dev"
cp "$repo_root/terraform/envs/dev/locals.tf" "$fixture/terraform/envs/dev/"
cp "$repo_root/terraform/envs/dev/airflow.tf" "$fixture/terraform/envs/dev/"

run_check() {
  RAW_DATA_PREFIXES_CHECK_ROOT="$fixture" \
    "$repo_root/scripts/check-raw-data-prefixes-contract.sh" > "$test_dir/output" 2>&1
}

if ! run_check; then
  echo "FAIL: 정상 fixture가 통과하지 못함" >&2
  cat "$test_dir/output" >&2
  exit 1
fi

sed -E -i.bak \
  's#(^[[:space:]]*action_logs_raw[[:space:]]*=[[:space:]]*")([^"]*)/"#\1\2"#' \
  "$fixture/terraform/envs/dev/locals.tf"
if run_check; then
  echo "FAIL: action_logs_raw trailing slash 유실을 잡지 못함" >&2
  exit 1
fi
mv "$fixture/terraform/envs/dev/locals.tf.bak" "$fixture/terraform/envs/dev/locals.tf"

sed -E -i.bak \
  's#(^[[:space:]]*action_logs[[:space:]]*=[[:space:]]*")data_lake/action_log/"#\1data_lake/action_log_v2/"#' \
  "$fixture/terraform/envs/dev/locals.tf"
if run_check; then
  echo "FAIL: action_logs/action_logs_raw alias 불일치를 잡지 못함" >&2
  exit 1
fi
mv "$fixture/terraform/envs/dev/locals.tf.bak" "$fixture/terraform/envs/dev/locals.tf"

sed -i.bak \
  's#local\.raw_data_prefixes\.publish_staging_raw#local.raw_data_prefixes.action_logs_raw#' \
  "$fixture/terraform/envs/dev/airflow.tf"
if run_check; then
  echo "FAIL: staging cleanup 조건의 publish_staging_raw 참조 유실을 잡지 못함" >&2
  exit 1
fi
mv "$fixture/terraform/envs/dev/airflow.tf.bak" "$fixture/terraform/envs/dev/airflow.tf"

# 위 회귀 케이스들이 항진 실패가 아님을 원복 후 재확인한다.
if ! run_check; then
  echo "FAIL: 회귀 원복 후 fixture가 다시 통과하지 못함" >&2
  cat "$test_dir/output" >&2
  exit 1
fi

for step in check-raw-data-prefixes-contract.sh test-check-raw-data-prefixes-contract.sh; do
  if ! grep -Fq "run: scripts/$step" "$repo_root/.github/workflows/lint.yml"; then
    echo "FAIL: scripts/$step가 lint workflow에 연결되지 않음" >&2
    exit 1
  fi
done

echo "PASS: raw_data_prefixes trailing slash·alias 값·staging IAM 참조 회귀는 검사 실패로 처리됨"
