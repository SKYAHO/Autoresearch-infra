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

## 안 B — 현행 유지 + break-glass를 1급 절차로 명문화 (권고)

- dev 첫 apply의 로컬 break-glass를 결함이 아니라 **의도된 절차**로 취급:
  MIGRATION_RUNBOOK(#437) Phase 2에 이미 실측 절차가 기록됨.
- 근거: ① 재구축은 드문 이벤트(이번이 최초)고, 그때조차 로컬 apply는
  bootstrap 때문에 어차피 1회 필요하다 — 안 A의 이득은 "로컬 apply 2회→1회"
  뿐. ② 반면 비용은 상시적(최강 SA의 local-state 관리, 리뷰 경계 붕괴).
  ③ 최강 자격의 사용 경로를 CI env 게이트 뒤에 고정한 #341 설계 의도와도
  안 B가 정합.

## 결정

- **권고: 안 B(현행 유지).** 채택 시 이 spec을 결정 기록으로 두고 #440을
  닫는다. 안 A를 택하면 이관 plan(교차 state 이동 절차 포함)을 이 문서에
  이어서 작성한다.
