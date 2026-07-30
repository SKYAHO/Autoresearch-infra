# 첫 apply 닭-달걀 해소 검토 — apply SA의 bootstrap 이관 여부 (#440)

> Status: 결정 대기 | Created: 2026-07-30

## 문제

apply 전용 SA 2종(dev-apply·admin-apply)과 workflow_ref WI 바인딩·프로젝트
IAM을 dev root 자신이 만든다. 새 프로젝트/재구축에서는 "apply SA를 만들 apply"가
CI로 불가능한 순환이 생겨, 최강 권한의 로컬 break-glass apply가 강제된다
(#404 실측 — plan 잡은 CI SA로 성공, apply 잡만 init 실패).

## 안 A — apply SA를 bootstrap root로 이관

- 이관 대상: `google_service_account` 2종 + `_wi` 바인딩 2종 + 프로젝트 IAM
  (dev-apply: 프로젝트 최강 role 셋, admin-apply: container.admin 등)
- 장점: 재구축 시 break-glass가 bootstrap 1회(원래도 로컬)로 수렴 —
  dev root부터는 처음부터 CI로 감.
- 단점: bootstrap(local state root)이 프로젝트 최강 SA·IAM까지 소유 —
  local state 유실 시 최강 자격 리소스가 orphan, bootstrap의 권한 표면이
  "state 버킷+WIF+읽기 SA"에서 "사실상 프로젝트 전권"으로 비대해짐.
  bootstrap 변경 리뷰가 최강 권한 리뷰가 된다.
- 이관 자체는 `removed`+`import`(또는 `terraform state mv` 성격의 교차 이동)로
  무중단 가능하나, 두 state에 걸친 이동이라 절차 실수 시 SA 재생성(=CI 단절).
  복구 경로(안 A 채택 시에만 유효): SA를 같은 account_id로 재생성하면 unique
  ID가 바뀌어 기존 project IAM binding이 `deleted:serviceAccount:…?uid=`로
  사문화된다 — 잔재 binding 제거 + 재바인딩(dev root re-apply)까지가 복구이며,
  이관 plan에는 이 단계를 사전 리허설 항목으로 넣는다.

## 안 B — 현행 유지 + break-glass를 1급 절차로 명문화 (권고)

- dev 첫 apply의 로컬 break-glass를 결함이 아니라 **의도된 절차**로 취급:
  MIGRATION_RUNBOOK(#437 — PR #443로 추가 중, 머지 전까지의 요약은 docs/CHANGE_HISTORY.md 2026-07-29~30 항목) Phase 2에 실측 절차가 기록됨.
- 근거(리뷰 반영 — 회계 정정): 안 A의 이득은 "횟수 2→1"이 아니라 **폭발
  반경 축소**가 정확하다 — 안 A 잔여 로컬 apply는 bootstrap(저권한 10여
  리소스)뿐이고, 안 B 잔여는 bootstrap + **dev root 전량(최강 권한)** 1회다.
  그럼에도 안 B를 권고하는 이유: ① 그 최강 로컬 apply는 희소 이벤트이고
  #404에서 "CI plan과 리소스 목록 diff 대조 후 apply"로 통제 가능함이 실증됨
  ② 안 A의 비용은 상시적 — local-state root가 프로젝트 최강 SA·IAM을 소유해
  bootstrap 변경 리뷰가 항상 최강 권한 리뷰가 되고, local state 유실 시 최강
  자격 리소스가 orphan ③ 최강 자격의 사용 경로를 CI env 게이트 뒤에 고정한
  #341 설계 의도와 정합.

## 결정

- **권고: 안 B(현행 유지).** 채택 시 이 spec을 결정 기록으로 두고 #440을
  닫는다. 안 A를 택하면 이관 plan(교차 state 이동 절차 포함)을 이 문서에
  이어서 작성한다.
