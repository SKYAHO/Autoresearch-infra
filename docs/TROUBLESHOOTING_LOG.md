# 트러블슈팅 로그 (날짜별)

실제 겪은 장애·삽질을 **날짜 내림차순**으로 모은 역검색 인덱스다. 각 항목의
정본은 링크된 runbook 절·이슈·CHANGE_HISTORY 항목이며, 여기서는 증상 →
원인 → 조치만 한 줄로 남긴다. 새 사건을 겪으면 **해결한 PR과 같은 PR에서
이 표에 한 줄 추가**한다(runbook 장애 대응 절 갱신과 병행).

## 2026-07-27

| 증상 | 원인 | 조치 |
|---|---|---|
| Prometheus 타깃 `airflow-statsd` down — `context deadline exceeded` | airflow ns ingress deny-by-default가 monitoring ns scrape 차단 | NetworkPolicy에 monitoring→9102 규칙 추가(#358 fix, PR #375). ServiceMonitor 등록돼도 이 증상이면 NetworkPolicy부터 |
| filebeat이 **신규 파드만** 수집 안 함(기존 파드는 정상 — 무증상에 가까움) | autodiscover가 재기동 후 신규 파드 이벤트를 놓치는 간헐 결함 | `kubectl -n elastic rollout restart daemonset/autoresearch-beat-filebeat`로 회복(#365 검증 중 실측). 신규 파드 로그가 안 보이면 의심 |
| airflow scheduler OOMKilled(limit 1536Mi) → 배포 워크플로 `kubectl exec` 137 연쇄 실패 | LocalExecutor가 12h 태스크를 scheduler 프로세스에서 실행, 종반 메모리 스파이크 | 파드 자가 회복 확인 후 배포 재실행. 재발 방지는 airflow#158(limit 상향 or KPO 이관) |
| CI가 만든 tfplan을 로컬 `terraform show`가 못 읽음 | CI(1.13.5)와 로컬(1.15.7) 버전 불일치 — plan 파일은 버전 간 호환 안 됨 | CI와 같은 버전 바이너리로 show. 절차는 메모리/CHANGE_HISTORY의 admin-apply 운전 절차 참조 |
| Kibana saved object import 500 (`Cannot read properties of undefined`) | lens 객체에 `typeMigrationVersion` 미기재 → 고대 버전 마이그레이션이 legacy 스키마 가정 | 객체에 `typeMigrationVersion` 스탬프 후 import(#359 실측). export본에는 자동 포함 |
| Airflow에 `[logging] json_format` 설정이 안 먹음 | 존재하지 않는 설정 — `json_format`은 Elasticsearch 태스크 핸들러 전용, GCS 핸들러와 배타 | task 로그는 GCS 원격 로깅으로, dag 필터는 KPO 파드 라벨(`kubernetes.labels.dag_id`)로 대체(airflow#147) |

## 2026-07-26

| 증상 | 원인 | 조치 |
|---|---|---|
| ArgoCD sync가 방금 머지한 커밋이 아니라 **직전 커밋**을 배포 | repo 폴링 캐시(기본 3분) — sync 시 캐시된 revision 사용 | `argocd.argoproj.io/refresh=hard` annotate 후 sync(#355 실측). 머지 직후 sync는 항상 hard refresh 선행 |
| 저장 검색을 API로 고쳤는데 열면 옛 쿼리로 나옴 | Kibana 9 saved search의 `tabs[0].attributes`가 별도 존재 — 루트만 PUT하면 탭이 구버전 유지 | attributes 전체(tabs 포함) PUT 후 재export(#369 리뷰 실측) |

## 2026-07-24

| 증상 | 원인 | 조치 |
|---|---|---|
| feast-apply CI 403 지속 | `FEAST_APPLY_SA` secret 미등록(WIF 가장 경로 단절) | secret 등록(#334/#335). CHANGE_HISTORY 07-24 참조 |
| dev root drift #306 — 의도 않은 plan diff | gitignored 로컬 tfvars의 example placeholder가 유입(4번째 재발) | tfvars.example placeholder 비움(#339/#340). 표준 경로는 CI apply라 차단, break-glass 로컬 apply 전 실 tfvars grep 필수 |
| E2 노드 증설 실패 (정확 일자 미기록 — retrain 풀 도입 시점, #316) | 리전 `E2_CPUS` quota 8 소진 | retrain 풀을 N2 계열로 선택(#316). 스케일 판단 대시보드의 "quota-blocked" 분기가 이 경로 탐지 |

## 2026-07-23

| 증상 | 원인 | 조치 |
|---|---|---|
| Kibana Google 로그인 후 "Oops! Something went wrong" | Kibana 9.2에서 `elasticsearch_anonymous_user` 자동 로그인 불안정(keystore 비번 미병합) | anonymous 폐기, oauth2-proxy + elastic basic 로그인으로 후퇴(#325/#326). 상세: `KIBANA_OPERATIONS_RUNBOOK`·elastic-k8s README |
| Google OAuth `redirect_uri_mismatch` | secret에 **다른 서비스(MLflow)의 client-id**가 주입돼 있었음 | 올바른 client 재주입. 노출된 secret은 즉시 revoke·로테이션(#329) |
| oauth2-proxy 기동 실패 — cookie-secret 길이 오류 | base64 인코딩 44자 파일(개행 포함)을 주입 — 요구는 정확히 32바이트 | `openssl rand -hex 16`으로 생성(runbook 반영) |
| admin-apply CI plan 단계 실패 반복 | ①에러가 파일 리다이렉트에 숨음 ②SA에 `compute.viewer` 부재 403 ③`private_services_cidr` 필수 var 미주입 | 마스킹된 에러 표면화(#309), 권한 추가(#310), var 주입(#318). gke-team-access는 403으로 CI 제외(#314) |

## 2026-07-18

| 증상 | 원인 | 조치 |
|---|---|---|
| Airflow scheduler crash-loop | airflow-k8s `private_services_cidr` 오설정 → Cloud SQL 접속 불가 | 값 정정·하드닝(#253/#254/#260). "Waiting for host: …5432" 로그가 이 계열 신호 |

## 2026-07-20

| 증상 | 원인 | 조치 |
|---|---|---|
| Feast materialize가 Redis Cluster 일부 키만 실패 | discovery 6379만 열고 data node 포트(11000-13047) 미개방 — Cluster 클라이언트는 노드 직결 | egress에 두 대역 모두 허용(#263/#264). NetworkPolicy 변경은 plan JSON으로 규칙 수 대조 |

## 2026-07-17

| 증상 | 원인 | 조치 |
|---|---|---|
| MLflow 파드 재시작 반복(OOM) | gunicorn workers에 512Mi 부족 | 1Gi + workers 2 + startupProbe(#95 runbook). 이후 유사 증상은 `AutoResearch / MLflow` 대시보드 메모리 패널로 관측 |

## 2026-07-16

세션 단위 상세 기록: [TROUBLESHOOTING_2026-07-16-session.md](TROUBLESHOOTING_2026-07-16-session.md)

## 2026-07-15

| 증상 | 원인 | 조치 |
|---|---|---|
| feast materialize GCS/BQ 403 | `objectAdmin`/`jobUser`만으로 부족 — `storage.buckets.get`·`bigquery.readsessions` 필요 | `legacyBucketReader`+`readSessionUser` 추가(#204/#205) |

## ~2026-07-14 (초기 구축기 — CHANGE_HISTORY 해당 일자 참조)

| 증상 | 원인 | 조치 |
|---|---|---|
| ES PVC 프로비저닝 실패 | 리전 `SSD_TOTAL_GB` quota 초과(기본 `standard-rwo`=pd-balanced) | `standard`(HDD)로 지정(#98). Prometheus/Grafana PVC도 동일 원칙 |
| Filebeat 기동 실패 "Auto discover config check failed" | Filebeat 9.x에서 container/log input 제거 — 구버전 예제 사용 | `filestream` + container parser 체계로 작성(#100). 이후 ndjson도 같은 체계(#359) |
