# 운영 workload별 node pool 전략 (#105)

> 작성: 2026-07-13 | 성격: 검토(정리) — node pool 변경은 후속 이슈
> 입력: #104 autoscaling 검토(scale-down 점착성, Spot 후보), #96 ES headroom
> 실측: pod 분포·taint 조회 (2026-07-13)

## 실측 — 현재 배치와 발견된 문제

| pool | 머신 | 상주 워크로드 (실측) |
|---|---|---|
| dev-default | e2-standard-4 (16G) | ES, Kibana, Grafana, ArgoCD 4, Vault, Rollouts, kube-state-metrics 등 플랫폼 전부 |
| airflow-dev | e2-standard-2 (8G) | Airflow core 4 + **Prometheus 본체(30Gi PVC)** ← 문제 |

**발견**: 두 pool 모두 **taint가 없어** 스케줄러가 플랫폼 pod를 airflow
노드로 보낼 수 있고, 실제로 Prometheus(stateful, RWO PVC)가 작은 airflow
노드에 앉아 메모리 압박(실측 58%)에 기여하고 있다. RWO PVC 특성상 한 번
앉으면 재기동 없이는 안 움직인다(#104 점착성).

## workload별 배치 기준 (완료 조건 ①)

| 워크로드 | 배치 기준 | 수단 |
|---|---|---|
| Airflow core (scheduler/webserver/postgres) | airflow-dev 전용 | Helm values nodeSelector (앱 저장소) — 현행 유지 |
| KPO batch pod | airflow-dev → 장기적으로 **Spot pool** | KPO pod template (앱 저장소). #104 결론 |
| 플랫폼 stateful (ES, Prometheus, Grafana, Vault) | **dev-default 고정** | nodeSelector — ES/Kibana는 적용됨(#98/#99), **Prometheus/Grafana/Vault는 미적용 → 후속 조치 대상** |
| 플랫폼 stateless (ArgoCD, Rollouts, ECK operator) | dev-default 선호, 고정 불필요 | 스케줄러 임의 — 재배치 무해(stateless) |
| DaemonSet (filebeat, node-exporter) | 모든 노드 | 고정 대상 아님. 전용 pool에 taint 도입 시 **toleration 추가 필수** 주의 |
| MLflow (미도입) | tracking server는 소형 stateless + 외부 DB | 전용 pool **불필요** — 도입 시 dev-default |

원칙: **stateful은 명시 고정, stateless는 자유** — 점착성이 있는 것만
통제하면 나머지는 스케줄러가 잘한다.

## 전용 node pool 필요 여부 (완료 조건 ②)

| 후보 | 결론 | 트리거/근거 |
|---|---|---|
| monitoring 전용 | **불필요** | 요구량 합계 ~2G — dev-default 여유 내. 격리가 비용을 정당화 못 함 |
| elasticsearch 전용 | **지금 불필요, 트리거 정의** | dev-default headroom < 3Gi(#96/#98) 또는 ES heap 증설·multi-node 전환 시 → e2-highmem 계열 전용 pool + taint |
| mlflow 전용 | **불필요** | 위 표 참조 |
| argocd/rollouts 전용 | **불필요** | 경량 stateless — controller류는 격리 이득 없음 |
| **batch Spot pool** | **유일한 신규 pool 후보 (후속 이슈)** | KPO는 재시도 내성 → Spot 60-90% 절감(#104). taint(`workload=batch-spot:NoSchedule`) + KPO toleration으로 batch만 수용 |

## taint/toleration/nodeSelector 기준 (완료 조건 ③ 일부)

1. **현재 2-pool 체제**: taint 없이 **nodeSelector만으로 충분** — 단
   방향이 한쪽뿐이라(플랫폼→dev-default 고정) airflow 노드 보호가 안 된다.
   Airflow core에도 nodeSelector가 걸려 있으므로 남는 구멍은 "고정 안 된
   플랫폼 stateful"뿐 → 아래 후속 조치로 해소.
2. **전용 pool을 만드는 시점부터는 taint 필수**: nodeSelector는 "우리
   pod를 그 pool로"만 보장하고 "남의 pod가 못 들어오게"는 taint만 한다.
   Spot pool은 특히 필수(일반 워크로드가 Spot에 앉으면 안 됨).
3. taint 도입 시 DaemonSet(filebeat/node-exporter) toleration을 같은
   변경에서 처리 — 빠뜨리면 새 pool의 로그/지표 수집이 조용히 빠진다.

## 비용·운영 복잡도 (완료 조건 ③)

- pool 1개 추가 = 최소 1노드 상시 비용(+월 $55~110) + 업그레이드/보안
  설정 관리 대상 1개 증가. **"격리가 그 비용을 정당화할 때만"**이 기준.
- Spot pool은 예외적으로 비용을 **줄이는** pool — 단 KPO 외 워크로드
  유입 차단(taint)과 중단 내성 확인이 전제.

## 후속 조치 (별도 이슈)

1. ~~Prometheus/Grafana/Vault dev-default nodeSelector~~ — **완료(#170)**
2. ~~batch Spot pool 신설~~ — **infra 측 완료(#173)**. KPO
   toleration/nodeSelector 전환은 Autoresearch-airflow 저장소 이슈로 이관
3. ES 전용 pool은 트리거 발생 시(§전용 pool 표)
