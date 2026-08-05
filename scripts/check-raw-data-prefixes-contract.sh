#!/bin/sh
# #522 raw_data_prefixes 값 회귀 검증. terraform validate/plan은 CEL 조건을
# 파싱하지 않으므로, trailing slash 유실이나 alias 값 불일치가 생겨도 plan diff의
# 문자열 한 글자 차이로만 드러난다. slash가 빠지면 IAM 조건이 인접 prefix까지
# 조용히 덮는다(예: action_log_quarantine이 action_logs_raw 조건에 걸림).
set -eu

script_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
repo_root="${RAW_DATA_PREFIXES_CHECK_ROOT:-$script_root}"
locals_file="$repo_root/terraform/envs/dev/locals.tf"
airflow_file="$repo_root/terraform/envs/dev/airflow.tf"

FAIL=0

get_value() {
  grep -E "^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"[^\"]*\"" "$locals_file" \
    | sed -E 's/^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/'
}

check_trailing_slash() {
  key="$1"
  val="$(get_value "$key")"
  if [ -z "$val" ]; then
    echo "ERR raw_data_prefixes: $key 값을 찾지 못함"
    FAIL=1
    return
  fi
  case "$val" in
    */) echo "OK  raw_data_prefixes: $key trailing slash 유지 ($val)" ;;
    *)
      echo "ERR raw_data_prefixes: $key에 trailing slash 없음 ($val) — IAM prefix 조건이 인접 prefix까지 덮을 수 있음"
      FAIL=1
      ;;
  esac
}

check_alias_pair() {
  key_a="$1"
  key_b="$2"
  val_a="$(get_value "$key_a")"
  val_b="$(get_value "$key_b")"
  if [ -z "$val_a" ] || [ -z "$val_b" ]; then
    echo "ERR raw_data_prefixes: $key_a 또는 $key_b 값을 찾지 못함"
    FAIL=1
    return
  fi
  if [ "$val_a" != "$val_b" ]; then
    echo "ERR raw_data_prefixes: $key_a($val_a) != $key_b($val_b) — alias 쌍이 어긋남"
    FAIL=1
  else
    echo "OK  raw_data_prefixes: $key_a == $key_b ($val_a)"
  fi
}

check_trailing_slash action_logs_raw
check_trailing_slash action_logs
check_trailing_slash publish_staging_raw
check_alias_pair action_logs_raw action_logs
check_alias_pair youtube_raw youtube_trending_kr
check_alias_pair users_raw virtual_users
check_alias_pair personas_raw personas_raw_snapshots

# publish_staging_raw는 다른 alias와 달리 pin할 근거가 있는 cross-repo 데이터
# 계약이다 — 앱 저장소(`Autoresearch`)의 PUBLISH_STAGING_PREFIX와 값이 어긋나면
# 이 IAM 조건이 앱이 실제로 쓰는 경로를 커버하지 못해 #522가 그대로 재현된다.
expected_publish_staging_raw="_publish_staging/"
actual_publish_staging_raw="$(get_value publish_staging_raw)"
if [ "$actual_publish_staging_raw" = "$expected_publish_staging_raw" ]; then
  echo "OK  raw_data_prefixes: publish_staging_raw가 앱 저장소 계약값과 일치 ($expected_publish_staging_raw)"
else
  echo "ERR raw_data_prefixes: publish_staging_raw($actual_publish_staging_raw) != 앱 저장소 계약값($expected_publish_staging_raw)"
  FAIL=1
fi

# #522: staging cleanup IAM 조건의 expression이 action_logs_raw(최종 committed
# 데이터 prefix)로 되돌아가면, 앱이 실제로 staging 객체를 쓰는
# publish_staging_raw 삭제 권한이 없어져 원자적 게시가 다시 실패한다. 주석에도
# 같은 문자열이 등장하므로(위 근본 원인 설명), 파일 전체가 아니라 expression
# 라인에만 앵커해 주석만 있고 실제 참조가 없는 경우를 공허하게 통과시키지 않는다.
if grep -qE '^[[:space:]]*expression[[:space:]]*=.*local\.raw_data_prefixes\.publish_staging_raw' "$airflow_file"; then
  echo "OK  airflow.tf: staging cleanup 조건의 expression이 publish_staging_raw를 참조"
else
  echo "ERR airflow.tf: staging cleanup 조건의 expression이 publish_staging_raw를 참조하지 않음"
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo "결과: raw_data_prefixes 계약 검증 실패"
  exit 1
fi

echo "결과: raw_data_prefixes 계약 검증 통과"
