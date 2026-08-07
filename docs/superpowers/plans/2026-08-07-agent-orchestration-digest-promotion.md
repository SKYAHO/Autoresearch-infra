# Agent Orchestration Digest Promotion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 검증된 release digest를 infra main에 안전하게 자동 반영한다.

**Architecture:** infra의 Ruby script가 허용된 manifest 참조만 바꾸고, Autoresearch release workflow가 제한된 GitHub App token으로 그 script를 실행·commit·push한다.

**Tech Stack:** GitHub Actions, GitHub App token, Ruby/Psych, Git.

## Global Constraints

- API 7개·UI 1개 참조만 수정한다.
- immutable digest 외 입력은 거부한다.
- secret 값은 기록하지 않는다.

### Task 1: Infra 승격 계약

- [x] Ruby self-test를 먼저 작성해 잘못된 repository·부분 API digest·허용 범위 밖 변경을 실패시킨다.
- [x] manifest를 갱신하는 Ruby script와 CI를 추가한다.
- [x] runbook과 변경 이력을 갱신한다.

### Task 2: Release 호출 경계

- [ ] Autoresearch release workflow에서 검증된 API·UI output을 수집한다.
- [ ] GitHub App token으로 infra checkout·script 실행·변경 시 commit/push를 수행한다.
- [ ] concurrency, 최소 permissions, secret 등록·rollback runbook을 문서화한다.
