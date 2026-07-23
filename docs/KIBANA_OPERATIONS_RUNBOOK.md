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
# 브라우저: https://localhost:5601 → /login (self-signed 경고는 dev 특성상 허용)
kubectl -n elastic get secret autoresearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d; echo   # 비밀번호 회수(문서/PR/채팅 미기재)
```

`elastic` 비밀번호는 ECK operator가 관리하므로 임의 변경하지 않는다.

## 최초 1회: data view 생성

Discover가 비어 보이면 data view부터 만든다:
좌측 메뉴 → Stack Management → Data views → Create data view →
Index pattern `filebeat-*`, Timestamp field `@timestamp`.

## 로그 검색 (Discover, KQL)

수집 범위는 `airflow`·`autoresearch` namespace 컨테이너 로그다(#100 —
시스템 로그는 Cloud Logging에서 본다).

| 목적 | KQL 예시 |
|---|---|
| Airflow scheduler 로그 | `kubernetes.namespace: "airflow" and kubernetes.container.name: "scheduler"` |
| Airflow DAG/task 실패 | `kubernetes.namespace: "airflow" and (message: "ERROR" or message: "Task failed")` |
| 특정 DAG 실행 pod (KPO) | `kubernetes.namespace: "airflow" and kubernetes.pod.name: <pod-name>*` |
| 앱 에러 로그 | `kubernetes.namespace: "autoresearch" and message: "ERROR"` |
| 특정 컨테이너 | `kubernetes.container.name: "webserver"` |

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
