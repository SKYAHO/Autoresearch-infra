#!/bin/sh
# #478 claude-review 14차 지적: dev/admin root plan 요약 추출에 쓰는
# grep -E allowlist 정규식이 apply.yml(dev root 스텝 + admin root
# 스텝) / terraform-plan.yml / terraform-drift.yml 총 4곳에 문자열로
# 복제돼 있다. 하나만 갱신되고 나머지가 밀려도 CI는 통과하고, 승인
# 게이트나 drift 이슈 요약에서만 조용히 리소스 주소가 빠지는 형태로
# 드러난다. 4곳이 완전히 동일한 정규식 문자열을 쓰는지 여기서 강제한다.
set -eu

script_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
repo_root="${DRIFT_SUMMARY_CHECK_ROOT:-$script_root}"
if ! cd "$repo_root"; then
  echo "ERR 검사 root에 접근할 수 없음 ($repo_root)" >&2
  exit 1
fi

# 대상 4곳 모두 "No changes"를 포함하는 grep -E 호출이라, 다른 grep -E
# 사용(예: apply.yml의 'Apply complete' 마스킹)과 구분된다.
patterns="$(grep -RhoE "grep -E '[^']*No changes[^']*'" \
  .github/workflows/apply.yml \
  .github/workflows/terraform-plan.yml \
  .github/workflows/terraform-drift.yml 2>/dev/null || true)"

count="$(printf '%s\n' "$patterns" | grep -c . || true)"
if [ "$count" -ne 4 ]; then
  echo "ERR plan 요약 allowlist grep -E 발견 개수가 4가 아님 ($count) — apply.yml 2곳(dev root/admin root) + terraform-plan.yml + terraform-drift.yml 총 4곳이어야 함"
  exit 1
fi

unique_count="$(printf '%s\n' "$patterns" | sort -u | grep -c . || true)"
if [ "$unique_count" -ne 1 ]; then
  echo "ERR plan 요약 allowlist grep -E 정규식이 4곳에서 서로 다름 — 아래 목록을 동일하게 맞출 것"
  printf '%s\n' "$patterns" | sort -u
  exit 1
fi

echo "결과: plan 요약 allowlist grep -E 정규식 4곳 일치 확인"
