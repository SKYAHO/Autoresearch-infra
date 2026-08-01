# Kibana / ELK 운영 Runbook (dev)

dev GKE의 ELK 스택(`elastic` namespace, #96~#102) 운영·검색 절차.
설치 구성은 `terraform/admin/elastic-k8s/README.md`, 설계는
`superpowers/specs/2026-07-13-elk-architecture-design.md` 참조. 모든 명령은
#98~#102 검증에서 실행해 확인한 것을 기준으로 한다.

## 접속 (내부 전용)

Kibana는 인터넷에 공개하지 않는다. 접근은 kubectl port-forward만 사용한다.
로그인은 두 가지다(#293).

**(A) Google(Gmail) 접근 통제 + Kibana basic 로그인 — 기본(#325).** 앞단
oauth2-proxy Service(4180)를 로컬 4181로 접속한다(MLflow 로컬 4180과 충돌 방지).
허용 이메일만 proxy를 통과하고, **Kibana `/login`에서 다시 `elastic`(또는 별도
사용자)로 로그인**한다. Kibana anonymous 자동 로그인은 9.2 호환성 문제로 폐기했다
(#323). 로컬 HTTP port-forward라 Kibana secure cookie는 비활성이다. `elastic` 비번은
`autoresearch-es-elastic-user` Secret에서 회수(문서/PR/채팅 미기재).
허용 목록은 `kibana-oauth` Secret의 `authenticated-emails` 키에서 주입되며,
oauth2-proxy는 이 파일만 이메일 접근 제한으로 사용한다.

Terraform apply 전에 Secret 형식과 항목 수만 확인한다(값은 출력하지 않는다). 결과가
실패하면 apply하지 말고 Secret의 `authenticated-emails`를 실제 팀원 이메일 한 줄씩으로
수정한 뒤 다시 확인한다.

```bash
kubectl -n elastic get secret kibana-oauth \
  -o jsonpath='{.data.authenticated-emails}' | base64 -d |
  awk 'BEGIN { ok=1; n=0 } { sub(/\r$/, ""); if ($0 == "" || $0 ~ /^#/) next; if ($0 !~ /^[^[:space:]@]+@[^[:space:]@]+$/) ok=0; n++ } END { if (!ok || n == 0) exit 1; print "authenticated-emails format OK, entries=" n }'
```

허용 목록에서 사용자를 제거할 때는 `authenticated-emails`를 갱신한 뒤
`kibana-oauth-proxy` rollout restart와 완료 확인을 수행한다. oauth2-proxy v7.7.1은
보호된 요청마다 세션 이메일을 allowlist로 재검사하므로, 제거된 사용자는 새 목록이
반영된 pod에 다음 요청을 보낼 때 cookie가 삭제되고 403으로 거부된다. 계정 제거에는
cookie-secret 회전이 필요하지 않다. 전체 사용자의 강제 재로그인이나 cookie 유출 대응은
`elastic-k8s` README의 **전원 세션 무효화** 절차를 따른다.

이 PR의 머지는 Kibana Deployment를 바꾸지 않는다. `elastic-k8s`는 수동 Terraform
apply 경로이고 dev root drift workflow의 감시 대상도 아니므로, apply 전 live pod는
기존 `--email-domain=*` 인가 상태로 남는다. CI 정적 검사는 저장소 설정만 보장하며
클러스터 반영을 증명하지 않는다. operator는 승인된 apply 뒤 `rollout status`와 아래
명령으로 실제 args에 `--email-domain`이 없는지 확인한 후 허용·미허용 계정 smoke test를
수행한다(Secret 값은 출력하지 않는다).

```bash
kubectl -n elastic get deployment kibana-oauth-proxy \
  -o jsonpath='{.spec.template.spec.containers[0].args}'
```

```bash
kubectl -n elastic port-forward svc/kibana-oauth-proxy 4181:4180
# 브라우저: http://localhost:4181 → sign-in → Google 로그인
```

`kibana-oauth` Secret 주입·허용 이메일·redirect URI 절차는
[terraform/admin/elastic-k8s/README.md](../terraform/admin/elastic-k8s/README.md)를
단일 원본으로 한다. client secret은 문서/PR/채팅에 남기지 않는다.

**(B) proxy 장애 시 break-glass.** Kibana 5601 직접 경로는 평상시 차단돼 있다
(#294 — proxy를 단일 접근 경로로 유지). proxy·`kibana-oauth` 장애로 (A)가 불가하면
operator가 `elastic-ingress`에 노드→5601 ingress를 임시로 되살린 뒤
(`terraform/admin/elastic-k8s` 규칙 복원 apply 또는 `kubectl` 패치) `elastic`로 직접
접속하고, 복구 후 되돌린다.

```bash
# 임시 복원 후:
kubectl -n elastic port-forward svc/autoresearch-kb-http 5601:5601
# 브라우저: http://localhost:5601 → /login (#394부터 Kibana 자체 TLS 비활성 — http)
# 주의(#394): break-glass로 elastic-ingress에 노드→5601을 임시 복원하는 경우
# 그 구간은 이제 평문이다 — kubectl port-forward 경로(API server TLS 터널)를
# 우선하고, ingress 복원 방식은 짧게 쓰고 즉시 되돌린다.
kubectl -n elastic get secret autoresearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d; echo   # 비밀번호 회수(문서/PR/채팅 미기재)
```

`elastic` 비밀번호는 ECK operator가 관리하므로 임의 변경하지 않는다.

## data view·저장 검색·대시보드 (#359)

data view(`filebeat-*` + `@timestamp`), 저장 검색 5종(Airflow 에러 / DAG
task 로그 / 앱 에러 / uvicorn 5xx / Filebeat 색인 거부 #365), 대시보드 **Logs Overview**(로그량·
log.level 분포·에러 logger Top 10·최근 에러)가 저장돼 있다. Discover가
비어 보이면 좌측 메뉴 → Dashboards → `Logs Overview` 또는 Discover에서
저장 검색을 연다.

이 객체들의 **유일한 복원 원본**은 저장소
`terraform/admin/elastic-k8s/kibana-saved-objects/logs-overview.ndjson`이다
(saved object가 사는 `.kibana*` 인덱스는 SLM 스냅샷 범위 밖 —
elastic-k8s README 복구 절 참조). **#365부터 자동 import** —
`kibana_saved_objects.tf`(elastic-k8s root)의 Job이
`_import?overwrite=true`(멱등)를 실행한다. 재실행 트리거는 ① ndjson 내용
변경 ② 완전 재구성뿐이므로, **파일이 그대로인 채 UI에서 객체만
삭제·훼손된 경우에는** apply가 No changes로 지나간다 — 복원 강제:

```bash
# break-glass 로컬 apply 경로 — 표준 admin-apply CI는 저장 plan 적용이라 -replace 미지원
terraform -chdir=terraform/admin/elastic-k8s apply \
  -replace=kubernetes_job_v1.kibana_saved_objects_import
```

이 파일이 정본이고 재import 시 UI 상태를 덮어쓰므로, **UI에서 객체를
수정했으면 반드시 export해 이 파일에 덮어써 커밋한다**. Job 결과 확인:
`kubectl -n elastic get jobs -l app.kubernetes.io/name=kibana-so-import`
(부분 실패도 본문 검증으로 Failed 처리). 수동 import(Stack Management →
Saved Objects → Import)는 폴백.

## 로그 검색 (Discover, KQL)

수집 범위는 `airflow`·`autoresearch` namespace 컨테이너 로그 + Filebeat
자기 로그(`elastic` ns의 filebeat 컨테이너만, #365 색인 거부 관측용)다
(#100 — 그 외 시스템·플랫폼 로그는 Cloud Logging에서 본다). Filebeat이 JSON 한 줄 로그를
최상위 필드로 전개하므로(#359 ndjson parser), 구조화 로깅(#352/#147)
전환 후에는 필드 기반 KQL을 쓴다. 전환 전 로그는 `message` 전문 매칭으로
폴백한다(비JSON 라인은 파싱 오류 필드 없이 원문을 보존한다 — #403).

| 목적 | KQL 예시 (구조화 후) | 전환 전 폴백 |
|---|---|---|
| Airflow 에러 | `kubernetes.namespace: "airflow" and log.level: (ERROR or CRITICAL)` | `message: "ERROR"` |
| 특정 DAG task (KPO) | `kubernetes.labels.dag_id: "<dag>" and kubernetes.labels.task_id: "<task>"` — 파드 라벨 기반이라 Airflow 설정과 무관하게 동작(#147 실측). LocalExecutor 인프로세스 태스크 로그는 GCS/웹서버 UI에서 본다 | K8s 라벨 값 제약(63자 초과·특수문자 시 KPO가 잘라내거나 치환)으로 정확 일치가 빗나가면 접두 와일드카드 `kubernetes.labels.dag_id: <앞부분>*` 또는 `kubernetes.pod.name: <task명 기반 접두>*` |
| 앱 에러 로그 | `kubernetes.namespace: "autoresearch" and log.level: ERROR` | `message: "ERROR"` |
| uvicorn 5xx | `log.logger: "uvicorn.access" and message: *500*` — **오탐 포함**(클라이언트 포트 `50xxx` 등도 매칭). 정확한 5xx 판정용 아님, #352 이후 `http.response.status_code >= 500` 필드로 교체 예정 | — |
| 구조화 전환 잔여 확인 | `kubernetes.namespace: ("airflow" or "autoresearch") and message:* and not log.level:*` — 최근 시간 범위에서 namespace·container별 집계. 계약상 `log.level`이 없는 평문 또는 불완전한 구조화 로그 후보 | — |
| 특정 컨테이너 | `kubernetes.container.name: "webserver"` | — |

Filebeat은 #403부터 비JSON 라인에 `error.type: json`·`error.message`를
추가하지 않는다. 따라서 위 잔여 질의가 0건이라는 사실만으로 구조화 전환
완료를 판정하면 안 된다. 먼저 같은 시간 범위에서
`kubernetes.namespace: ("airflow" or "autoresearch")`로 최신 문서가 실제
유입되는지 확인한 뒤, 활성 컨테이너별 잔여 질의를 비교한다. 기준 질의도
0건이면 전환 완료가 아니라 수집 중단 가능성이므로 아래 Beat health와 파드
로그를 확인한다.

위 잔여 질의도 못 보는 손실 경로 — **ES 색인 거부**(매핑 충돌 400,
예: 예약 object 키를 스칼라로 찍은 경우)는 문서 자체가 안 남아 무음이다.
#365부터 Filebeat이 자기 로그(filebeat 컨테이너 한정)를 수집하므로
**저장 검색 `Filebeat 색인 거부 (Cannot index event)`로 상시 관측한다**
(0건 정상 — 반복되면 로그 스키마 예약 키 계약 위반 의심). Filebeat 수집
자체가 죽은 경우의 폴백은 파드 로그 직접 확인:

```bash
kubectl -n elastic logs -l beat.k8s.elastic.co/name=autoresearch --tail 200 \
  | grep -i "Cannot index event"   # 결과 0줄이 정상
```

참고: elasticsearch-exporter 기반 Grafana 관측은 실측 탈락 — v1.9.0
`/metrics` 전수 확인 결과 색인 실패(failed) 계열 메트릭이 존재하지 않는다
(#365 기록).

Kubernetes 이벤트(스케줄 실패, OOMKilled 등)는 컨테이너 stdout이 아니라
API 오브젝트라 ELK 수집 범위 밖이다 — `kubectl get events` 또는
Grafana(kube-state-metrics 지표)로 본다:

```bash
kubectl -n airflow get events --sort-by=.lastTimestamp | tail -20
```

## 상태 확인

```bash
kubectl -n elastic get elasticsearch,kibana,beat   # 전부 HEALTH green 기대
kubectl -n elastic get pods
```

ES API 기준(포트포워드 `svc/autoresearch-es-http 19200:9200` + elastic 인증):

```bash
curl -sk -u "elastic:$PW" https://localhost:19200/_cluster/health   # green
curl -sk -u "elastic:$PW" "https://localhost:19200/_cat/indices/.ds-filebeat-*?h=index,health,docs.count,store.size"
```

## 정기 점검 (주 1회 권장)

| 항목 | 명령/위치 | 기대값 |
|---|---|---|
| cluster health | `_cluster/health` | green (yellow면 replicas/할당 확인) |
| **ILM delete phase 존재** | `_ilm/policy/filebeat` | hot(1d/5gb) + delete(7d) — 없으면 비용 무한 증가(#101). filebeat 재기동이 ConfigMap 기준으로 재적용 |
| ILM 오류 | `_ilm/explain?only_errors=true` (`.ds-filebeat-*`) | 오류 인덱스 0 |
| **SLM 최근 실행** | `_slm/policy/daily-snapshots` | `last_success`가 24h 이내(#102) |
| snapshot 목록 | `_snapshot/gcs_snapshots/_all?verbose=false` | 최신 SUCCESS, 7일 초과분 자동 정리 |
| PVC 사용량 | Grafana PVC 대시보드 또는 `kubectl -n elastic exec autoresearch-es-default-0 -- df -h /usr/share/elasticsearch/data` | 70% 미만(초과 시 증설 검토 #96) |
| Beat 수집 | `kubectl -n elastic get beat` + Discover 최신 문서 | green + 최근 로그 유입 |

## 장애 대응 1차 순서

| 증상 | 확인 | 조치 |
|---|---|---|
| cluster yellow | `_cat/indices?h=index,health,rep` — replicas 1 인덱스 존재? | 신규 템플릿 미적용 인덱스면 replicas 0 소급(README ILM 절). single-node에서 replicas ≥1은 항상 yellow |
| cluster red | `_cat/indices` red 인덱스 확인, pod 로그 | PVC/노드 문제면 pod 재기동 후 로컬 복구 대기. 데이터 손상 시 snapshot restore(README 복구 절차) |
| 로그 유입 중단 | ① Beat health/pod ② filebeat 로그의 output 오류 ③ NetworkPolicy(9200 VIP) | filebeat error/warn 로그 기준 원인 분리(#100 인시던트 참조 — input 오류는 'config check failed'로 나타남) |
| ES pod Pending | events — PVC provisioning(quota) 또는 노드 여유 | SSD quota면 storage class 확인(#98 인시던트), 메모리면 headroom(#105 트리거) |
| ES OOM/재시작 반복 | pod restart count, heap | limit 상향 또는 수집량 점검 |
| snapshot 실패 | `_slm/policy` last_failure, repository `_verify` | 403이면 WI/KSA 이름 규약(#102 리뷰), timeout이면 metadata/googleapis egress 확인 |
| watermark(디스크 압박) | ES 로그의 flood_stage, `df -h` | 오래된 인덱스 수동 삭제 + ILM 동작 확인. flood_stage에서 인덱스 read-only 전환됨(쓰기 재개는 사용량 해소 후) |

## 업그레이드 주의 (ECK/스택)

1. 순서: **operator(chart) 먼저**, ES/Kibana/Beat 버전은 이후 —
   `eck_chart_version` → `elasticsearch_version` (README 버전 고정 기준).
2. ES/Kibana/Beat CR의 kubernetes_manifest 왕복 안정화(`metadata = {}` +
   `computed_fields` 조합)는 현재 ECK 버전의 정규화 동작에 묶인 조건부
   부채다(#99 실측) — **업그레이드 PR 검증에 '연속 plan 2회 No changes'
   재확인을 반드시 포함**한다.
3. single-node라 스택 버전 업그레이드는 재기동(수 분 중단)을 동반한다 —
   filebeat 재전송으로 로그 유실은 없다.

## 폐기 순서 (데이터 유실 방지)

`terraform/admin/elastic-k8s/README.md` 롤백 절 기준. 요약:
**snapshot 확인(#102) → CR 제거 → PVC 수동 정리 → (필요 시에만) CRD 정리**.
CRD를 먼저 지우면 CR 연쇄 삭제로 데이터가 유실된다. ES CR은
`volumeClaimDeletePolicy: DeleteOnScaledownOnly`라 CR 제거만으로는 PVC가
남는다(#98).
