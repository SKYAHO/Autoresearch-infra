# GKE autoscaling 전략 검토 (#104)

> 작성: 2026-07-13 | 성격: 검토(EXP) — 설치/변경 없음
> 실측 기준: `gcloud container node-pools list` + `gke.tf` (2026-07-13)

## 1. 현재 설정과 한계 (완료 조건 ①)

| pool | 머신 | autoscaling (실측) | 성격 |
|---|---|---|---|
| dev-default | e2-standard-4 (4vCPU/16G) | **CA 활성, min 1 / max 2** | 플랫폼·앱 pool. 현재 1노드에 ES/Kibana/모니터링/ArgoCD/Vault/Rollouts 집적 |
| airflow-dev | e2-standard-2 (2vCPU/8G) | CA 블록 있으나 **min 1 / max 1 = 사실상 고정** | Airflow 전용. 확장은 quota/limit range로 통제 |
| NAP / VPA | — | **비활성** | — |

한계:

- **scale-down 점착성**: dev-default가 2노드로 늘어난 뒤에는 PVC(RWO)를
  가진 stateful pod(ES/Prometheus/Grafana/Vault)가 노드에 눌러앉아
  CA가 노드를 줄이지 못할 가능성이 높다 — 즉 max로 늘어난 비용이
  잘 되돌아오지 않는 구조. 확장이 "일시 부하" 대응이라기보다
  "반영구 증설"에 가깝다는 점을 인지하고 운영해야 한다.
- **단일 zone**: CA가 늘려도 같은 zone — 노드 장애 도메인 분산 효과 없음
  (zonal 클러스터 전제, multi-zone은 별도 작업).
- **airflow-dev 고정(min=max=1)**: KPO 배치 폭주 시 Pending으로 표출된다.
  이는 의도된 통제(비용 상한)이며, resource quota(#32)가 1차 방어다.
- 머신 타입 고정: pod 하나가 e2-standard-4를 넘는 요구를 가지면 CA로도
  해결 불가(타입 변경 = pool 교체, 노드 재생성 #116 교훈).

## 2. GKE Cluster Autoscaler (완료 조건 ②)

- **이미 사용 중이고, dev에서는 이것으로 충분하다.** 기능 자체는 무료이며
  비용은 늘어난 노드분만 과금 — min/max가 곧 비용 가드레일이다.
- 유지 권장 설정: dev-default min 1 / max 2 (현행). max 2인 이유:
  e2-standard-4 1대 추가 ≈ **월 ~$110**(서울, on-demand)이 dev 예산에서
  수용 가능한 상한이기 때문.

## 3. Node Auto Provisioning (완료 조건 ②)

**dev 도입 보류.** NAP는 pod 요구에 맞춰 GCP가 새 pool(머신 타입 포함)을
자동 생성한다:

- 장점: 워크로드 프로필이 다양할 때 pool 설계 부담 제거
- 보류 이유: ① 우리 워크로드 프로필은 2종(플랫폼/airflow)으로 고정되어
  있어 자동 pool 설계의 이득이 없음 ② 생성되는 pool의 머신 타입을 GCP가
  정해 **비용 예측성이 떨어짐** ③ 노드 SA/보안 설정 기본값이 pool별
  명시 관리(현행 IaC 원칙)보다 통제가 약함
- 재검토 트리거: 운영 전환 후 워크로드 프로필이 3종 이상으로 다양해질 때

## 4. Karpenter (완료 조건 ②)

**비권장 확정.** 근거:

- Karpenter는 AWS에서 탄생한 프로젝트로, **GKE 공식 지원이 없다**
  (GCP provider는 커뮤니티 초기 단계 — 운영 신뢰성 검증 부족).
- Karpenter가 잘하는 것(빠른 node 프로비저닝, bin-packing, 다양한 인스턴스
  선택)은 GKE에서 CA + NAP가 네이티브로 제공하는 영역과 겹친다.
- 도입 시 얻는 것 없이 비표준 경로의 관리 오버헤드(컨트롤러 운영, IAM,
  업그레이드 추적)만 추가된다. **GKE에서는 네이티브 기능이 정답**이며,
  Karpenter는 EKS로 이전하는 경우에만 재검토한다.

## 5. 비용 영향과 권장안 (완료 조건 ③)

| 안 | 월 비용 영향 | 판단 |
|---|---|---|
| 현행 유지 (dev-default CA 1~2, airflow 고정 1) | +0 (확장 시에만 +~$110) | **권장** — 현재 여유(실측 headroom ~8GB)로 충분 |
| airflow-dev max 상향 (1→2) | 확장 시 +~$55 (e2-standard-2) | 보류 — KPO Pending이 반복 관측될 때만 |
| NAP 활성화 | 예측 불가 | 보류 (3절) |
| Karpenter | 관리 비용만 증가 | 비권장 (4절) |
| batch용 Spot pool 신설 | KPO 비용 ~60-90% 절감 가능 | **후속 실험 후보** — KPO는 재시도 내성이 있어 Spot 적합. #105 node pool 전략에서 함께 설계 |

운영 트리거 (#105 연계):

- dev-default에서 pod Pending 또는 ES headroom 3Gi 미만(#96 기준) →
  CA가 max 2로 자동 대응하는지 관측, 반복되면 전용 pool 분리(#105)
- airflow-dev에서 KPO Pending 반복 → max 상향 또는 Spot pool 검토
- scale-down 미발생으로 2노드 고착 → stateful pod 재배치 계획과 함께
  수동 정리(§1 점착성)

## 결론

dev에서는 **현행(CA min1/max2 + airflow 고정) 유지**가 비용·안정성 균형점.
NAP는 보류, Karpenter는 비권장. 다음 실질 개선은 autoscaling이 아니라
**#105(node pool 전략 — Spot batch pool, ES 전용 pool 트리거)** 쪽에 있다.
