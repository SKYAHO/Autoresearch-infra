# 운영형 ELK 아키텍처 설계 (#96)

> 작성: 2026-07-13
> 전제: 실제 리소스 생성은 후속 이슈(#97~#103). 이 문서는 아키텍처·정책 결정만.
> 관련: `docs/OBSERVABILITY_STRATEGY.md`(#77 — metric 측 전략)

## 설계 결정 요약

| 항목 | 결정 | 근거 |
|---|---|---|
| 설치 방식 | **ECK operator 확정** (`eck-operator` Helm chart 버전 pin) | Elastic 공식 Kubernetes 표준. ES/Kibana를 CR로 선언 관리(버전 업그레이드·TLS·secret 자동화). 커뮤니티 ES chart는 유지보수 종료 |
| root 구조 | admin root `elastic-k8s` 신설 (별도 state) | argocd/vault/rollouts root와 동일 패턴. operator는 helm_release, ES/Kibana CR은 `kubernetes_manifest` |
| namespace | `elastic` | operator + ES + Kibana + Beat 동일 namespace (초기 최소) |
| ES 구성 | **single-node** (master+data 겸용), heap 1GB / 컨테이너 memory request 2Gi·limit 3Gi, PVC 30Gi | dev 최소 비용. 실측: dev-default 노드 여유 메모리 ~8.8GB로 수용 가능 — **신규 node pool 불필요** |
| Kibana | 1 replica, request 1Gi | ClusterIP + port-forward 전용 |
| 수집기 | Filebeat (ECK `Beat` CR, DaemonSet) | 초기 수집 범위는 아래 표 |
| 보안 | ECK 기본값 유지 — ES TLS + `elastic` 사용자 인증 활성 | Vault와 달리 **처음부터 TLS** (ECK가 self-signed 인증서를 자동 발급·회전하므로 추가 비용 없음) |
| retention | ILM 7일 후 삭제 | Prometheus 7일과 정합(OBSERVABILITY_STRATEGY) |
| 백업 | GCS snapshot repository, 일 1회, 7일 보관 | 전용 bucket + 전용 GSA/WI(키 없음) |

## Cloud Logging과 역할 분리 (완료 조건)

| 구분 | Cloud Logging | ELK |
|---|---|---|
| 주 사용처 | GCP 기본 안전망 — GKE 시스템/audit 로그, managed 서비스 로그, 기본 30일 보관 | 앱·Airflow 로그의 **검색/분석/대시보드** (Kibana 쿼리, 구조화 필드 탐색) |
| 관리 주체 | GCP 서비스 (기본 sink 유지) | Kubernetes(ECK) — 운영자가 스키마·보관·백업 제어 |
| 비용 관리 | ingest 사용량 (현재 기본 sink 유지, 축소는 비용 이슈 발생 시 별도 검토) | PVC·ILM retention·수집 범위 관리 |
| 대체 관계 | **서로 대체하지 않음** — Cloud Monitoring/Prometheus 병행 구조(#77)와 동일한 원칙 | |

수집 중복은 의도된 것이다: Cloud Logging은 건드리지 않는 안전망으로 두고,
ELK 수집 범위만 좁게 통제한다.

## 로그 수집 범위 (완료 조건, #100 입력값)

| 대상 | 수집 | 이유 |
|---|---|---|
| `airflow` ns 컨테이너 로그 (scheduler/webserver/batch) | **초기 수집** | DAG/배치 장애 분석이 ELK 도입의 1차 목적 |
| `autoresearch` ns (앱 API — 배포 시) | **초기 수집** | 앱 로그 검색 |
| `kube-system`, GKE 시스템 로그 | 제외 | Cloud Logging이 이미 커버 |
| 플랫폼 ns (argocd/monitoring/vault/elastic/argo-rollouts) | 제외 (초기) | 필요 시 namespace 단위로 추가 — Filebeat autodiscover의 namespace allowlist 방식 |

## Kibana 접근 (완료 조건)

ArgoCD/Grafana/Vault와 동일 원칙: **ClusterIP + `kubectl port-forward`만**,
LB/Ingress 금지. `elastic` 사용자 초기 비밀번호는 operator가 생성하는
Secret에서 회수하고(절차는 #103 runbook), 채팅/Git/문서에 남기지 않는다.

## 비용·보관·백업 정책 (완료 조건)

| 항목 | 초기값 | 비고 |
|---|---|---|
| ES PVC | 30Gi (pd-balanced) | ~$3/월. disk watermark 고려해 70% 사용 시 증설 검토 |
| ILM | hot 7일 → delete | rollover 1일 또는 5GB 단위 |
| snapshot | GCS 전용 bucket, 일 1회, 7일 보관 | bucket lifecycle로 오래된 snapshot 정리. GSA는 bucket 단위 `roles/storage.objectAdmin`만 |
| node 비용 | 추가 없음 | 기존 dev-default 노드 여유 내 (실측 ~8.8GB free). 운영 전환 시 전용 node pool은 #105에서 결정 |
| 합계 | 월 $5 미만 | PVC + snapshot bucket 소량 |

## 네트워크 경계 (후속 이슈 공통 입력값)

deny-by-default NetworkPolicy에 누적 교훈 반영(#116/#122/#126/#138 —
rollouts root와 같은 방식):

- ingress: 같은 ns + kube-system + 노드 대역 → Kibana 5601(port-forward)
- egress: 같은 ns(ES 9200/9300), services CIDR 53/443, kube-system 53,
  master CIDR 443(webhook/operator), **snapshot용 199.36.153.8/30:443**
  (GCS — private googleapis VIP #138), Filebeat→ES는 같은 ns로 커버
- Filebeat DaemonSet은 hostPath(/var/log/containers) read 필요 — PSS
  baseline과의 충돌 여부를 #97에서 확인(privileged 불필요, hostPath read만)

## 후속 이슈 입력값 (완료 조건)

| 이슈 | 입력값 |
|---|---|
| #97 ECK operator 설치 | admin root `elastic-k8s`, chart `eck-operator` 버전 pin, namespace `elastic`, NetworkPolicy 위 기준, CRD keep 정책(rollouts와 동일 주의) |
| #98 ES 최소 클러스터 | `Elasticsearch` CR single-node, heap 1G/mem 2-3Gi, PVC 30Gi, TLS/auth 기본 유지. CR은 kubernetes_manifest — CRD 부트스트랩 순서 주의(argocd 선례: operator 먼저 targeted apply) |
| #99 Kibana 접근 | `Kibana` CR 1 replica, ClusterIP, port-forward 5601, elastic 비밀번호 회수 절차 |
| #100 로그 수집 | `Beat` CR(Filebeat DaemonSet), namespace allowlist: airflow·autoresearch |
| #101 ILM/retention | hot 7일 delete 정책, index template |
| #102 snapshot | GCS bucket(dev root) + GSA/WI(키 없음), repository-gcs, 일 1회 SLM |
| #103 Kibana runbook | 접속, 비밀번호 회수/변경, 검색 기본, 장애 대응(cluster health/heap/watermark), 폐기 순서 |

## 운영 전 확인 질문

- Airflow 로그는 이미 GCS(`airflow-logs` bucket)에도 남는다 — task 로그는
  GCS, 컨테이너 stdout은 ELK로 역할이 갈리는데 팀이 이 구분을 수용하는가?
- 앱 로그를 구조화(JSON)로 남기도록 앱 저장소에 요청할 것인가? (Kibana
  활용도가 크게 달라짐)
- 운영 전환 시 ES를 3-node로 확장할 것인가, managed(Elastic Cloud)로 갈
  것인가 — #105 node pool 전략과 함께 재검토
