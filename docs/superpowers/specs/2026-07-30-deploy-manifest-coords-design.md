# deploy manifest 프로젝트 좌표 변수화 검토 (#441)

> Status: 결정 대기 | Created: 2026-07-30

## 문제

`deploy/serving`·`deploy/mlflow` plain 매니페스트에 프로젝트 좌표(AR 이미지
경로, 프로젝트 id env, GCS 버킷 URL)가 7곳 산재한다. 이전(#404)에서 수기
치환이 필요했고(#407), "이미지 복사 전 경로 교체 → 무한 ImagePullBackOff"
순서 함정도 실측됐다. staging/prod 분리 시 같은 치환이 환경 수만큼 반복된다.

## 안 A — kustomize overlay 도입

- base(공통 manifest) + overlay(환경별 image/env/버킷 patch). ArgoCD는
  kustomize를 네이티브 지원 — Application source path만 overlay로 변경.
- 장점: 좌표 변경 diff가 overlay 1곳으로 수렴, 환경 추가가 overlay 복제.
- 단점: 지금은 dev 단일 환경 — 파일 수·간접 참조가 늘고, 이미지 digest 승격
  플로우(앱 repo가 deployment.yaml의 digest를 직접 승격하는 현행 계약)를
  overlay 구조에 맞춰 바꿔야 한다(앱 repo 조정 동반).

## 안 B — 현행 유지, 순서 함정만 런북으로 방어 (권고)

- MIGRATION_RUNBOOK(#437)이 "이미지 복사 → digest 대조 → 경로 교체" 순서를
  이미 명문화. 이전류 이벤트에서의 수기 치환은 grep 전수(옛 좌표 0건 검증)로
  충분히 안전함이 #404에서 실증됨.
- 근거: ① 환경이 1개인 동안 overlay는 구조 비용만 지불(YAGNI — #407 리뷰
  판단과 동일) ② digest 승격 계약(앱 repo→deployment.yaml 직접 수정)이
  단순함을 유지 ③ staging/prod 분리가 실제 착수될 때 module 추출과 함께
  kustomize화하면 한 번에 정리된다.

## 결정

- **권고: 안 B(보류) — staging/prod 분리 착수를 트리거로 안 A 재론.**
  이 spec이 그 시점의 출발 문서가 되도록 안 A의 구조 스케치를 남겨둔다.
