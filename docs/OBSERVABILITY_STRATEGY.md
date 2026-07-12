# 운영 모니터링 전략

이 문서는 Issue #77 기준 Prometheus + Grafana 운영 모니터링 설계를 정리한다.
현재 dev 인프라에는 아직 Prometheus/Grafana가 설치되어 있지 않다. Issue #78에서
`monitoring` namespace와 Helm values 기준을 준비하고, 실제 chart 설치와 운영 구성은
#79~#81에서 진행한다.

## 목적

GKE 위에 Airflow, 애플리케이션 배치, 이후 MLflow/ArgoCD/ELK가 올라가면
장애 원인을 빠르게 좁힐 수 있는 지표 기반 관측 체계가 필요하다. 첫 단계에서는
GKE 내부 workload 상태를 직접 볼 수 있는 Prometheus + Grafana를 구성하고,
Cloud Monitoring은 GCP managed resource의 기본 관측 수단으로 유지한다.

## 현재 상태

| 영역 | 현재 구성 |
|---|---|
| GKE 기본 관측 | GKE cluster의 Cloud Operations logging/monitoring 기본 연동 |
| Monitoring 설치 기반 | `monitoring` namespace와 `kube-prometheus-stack` values 준비 |
| Kubernetes 지표 전용 스택 | 미설치 |
| Grafana UI | 미설치 |
| Alerting | 미구성 |
| 외부 공개 endpoint | 없음 |

현재 Cloud Logging/Monitoring은 GKE와 GCP 리소스의 기본 로그/지표를 제공한다.
Prometheus/Grafana는 이를 대체하지 않고, Kubernetes application metric과 운영
dashboard를 다루는 별도 계층으로 둔다.

## 설계 결정

| 항목 | 결정 |
|---|---|
| 설치 방식 | `kube-prometheus-stack` Helm chart 우선 |
| namespace | `monitoring` |
| Grafana 접근 | 외부 공개 금지. 초기에는 Bastion 터널 또는 `kubectl port-forward` 기준 |
| Prometheus 보관 기간 | dev 기본 7일 |
| Prometheus 저장소 | PVC 사용. 초기 30Gi 기준, 사용량 확인 후 조정 |
| 고가용성 | dev에서는 단일 replica. 운영 전환 전 HA 재검토 |
| remote write | 초기 미사용. 장기 보관 요구가 생기면 별도 검토 |
| Alertmanager | 설치는 허용하되, 알림 채널 연동은 별도 이슈에서 결정 |
| Cloud Monitoring 관계 | GCP managed metric baseline 유지, Kubernetes/app 상세 dashboard는 Grafana 사용 |

`kube-prometheus-stack`은 Prometheus Operator, Prometheus, Alertmanager,
Grafana, kube-state-metrics, node-exporter, 기본 Kubernetes dashboard/rule을
한 번에 구성할 수 있어 첫 운영 모니터링 기반으로 적합하다.

## 모니터링 대상

| 대상 | 봐야 하는 지표 | 이유 |
|---|---|---|
| GKE node | CPU, memory, disk, network, node condition | node 압박과 scheduling 실패 원인 확인 |
| Pod/container | restart count, CPU/memory, OOMKilled, pending 상태 | Airflow task와 앱 배치 장애 확인 |
| PVC | 사용량, 남은 용량, inode, mount 상태 | Prometheus, Airflow log, 향후 MLflow artifact 연동 안정성 확인 |
| Airflow | scheduler/worker/webserver pod 상태, DAG 처리 지연, task 실패율 | Airflow 저장소가 별도이므로 infra 측 운영 관측 기준 제공 |
| Autoresearch app/batch | batch pod 성공/실패, API 호출 latency, custom metric 후보 | YouTube 수집과 feature pipeline 운영 확인 |
| ArgoCD/Argo Rollouts | sync status, rollout 상태, controller error | GitOps 도입 후 배포 상태 확인 |
| MLflow | tracking server pod 상태, DB 연결, artifact 접근 오류 | 모델 실험/등록 경로 안정성 확인 |
| ELK | Elasticsearch cluster health, JVM heap, disk watermark, Kibana 상태 | 로그 플랫폼 도입 후 자체 상태 감시 |

## 접근과 보안

Grafana는 dev에서도 인터넷에 공개하지 않는다. 기본 접근 방식은 아래 순서를 따른다.

1. 관리자 또는 팀원이 GKE 권한을 가진 상태에서 `kubectl port-forward`로 접속한다.
2. VPC 내부 접근이 필요한 UI 형태로 확장되면 Bastion 터널을 사용한다.
3. 여러 명이 상시 접근해야 하면 내부 LoadBalancer와 private DNS를 #80에서 검토한다.

보안 원칙:

- Grafana admin password, OAuth client secret, datasource credential은 Git에 쓰지 않는다.
- password와 secret payload는 Secret Manager 또는 Kubernetes Secret로 주입한다.
- Grafana UI는 public LoadBalancer, public Ingress, unauthenticated endpoint로 열지 않는다.
- service account JSON key를 발급하지 않는다. Workload Identity 또는 IAM 기반 인증을 우선한다.
- dashboard에는 secret 값, token, 개인 이메일이 그대로 노출되지 않게 한다.

## 보관 기간과 비용 기준

dev의 첫 기준은 "짧게 보관하고 빨리 관측한다"이다.

| 항목 | 초기값 | 운영 기준 |
|---|---|---|
| Prometheus retention time | 7일 | 장애 분석에 충분한 최소 기간 |
| Prometheus PVC | 30Gi | 70% 이상 사용 시 증설 검토, 85% 이상 즉시 대응 |
| scrape interval | chart 기본값 우선 | 비용/부하가 크면 namespace 또는 job 단위로 조정 |
| Grafana PVC | chart 기본값 또는 10Gi 이하 | dashboard/config 보존 목적 |
| remote write | disabled | 장기 보관 비용과 보안 검토 전까지 사용하지 않음 |

Prometheus는 metric cardinality가 높아지면 저장소와 CPU 비용이 빠르게 증가한다.
label에 사용자 ID, raw URL, request id처럼 값 종류가 계속 늘어나는 데이터를 넣지
않는다.

## Cloud Monitoring과 역할 분리

| 구분 | Cloud Monitoring | Prometheus/Grafana |
|---|---|---|
| 주 사용처 | GCP managed resource 기본 지표, GKE 기본 연동 | Kubernetes/app/custom metric dashboard |
| 관리 주체 | GCP 서비스 | Kubernetes Helm release |
| 장점 | GCP 콘솔 통합, 기본 metric 자동 수집 | ServiceMonitor/PodMonitor 기반 세밀한 workload 관측 |
| 비용 관리 | Cloud Logging/Monitoring 사용량 관리 | retention, PVC, scrape target/cardinality 관리 |
| 대체 관계 | 대체하지 않음 | Cloud Monitoring을 완전히 대체하지 않음 |

이 설계에서는 두 체계를 병행한다. Cloud Monitoring은 GCP 프로젝트와 managed
서비스의 기본 안전망으로 두고, Prometheus/Grafana는 Kubernetes 운영자가 직접
보는 dashboard와 application metric 기준으로 사용한다.

## 후속 이슈 입력값

| 이슈 | 입력값 |
|---|---|
| #78 monitoring namespace 및 Helm 설치 기반 | namespace `monitoring`, chart source, values 파일 위치, CRD 관리/삭제 원칙 |
| #79 Prometheus + Grafana 최소 설치 | `kube-prometheus-stack`, retention 7일, Prometheus PVC 30Gi, Grafana 비공개 |
| #80 Grafana 내부 접근 구성 | 기본은 port-forward/Bastion, 필요 시 internal LoadBalancer + private DNS |
| #81 Grafana 운영 runbook | 접속 절차, dashboard 확인, PVC 증설, chart upgrade, rollback |

Private GKE cluster에서 Prometheus Operator admission webhook을 사용할 때는 control
plane이 webhook pod로 접근 가능한지 확인해야 한다. 접근이 막히면 webhook용
firewall 또는 chart option 조정이 필요하다.

Prometheus Operator CRD는 chart 제거 시 자동으로 정리되지 않을 수 있다. 따라서
#78에서는 CRD upgrade와 uninstall 절차를 runbook에 남기는 것을 완료 조건에 포함한다.

## 운영 전 확인 질문

- Grafana 로그인은 dev에서 local admin으로 시작할지, Google OAuth를 바로 붙일지?
- Airflow 저장소에서 어떤 metric endpoint 또는 StatsD exporter를 제공할지?
- 앱 저장소에서 custom metric을 직접 노출할지, batch 결과를 로그/BigQuery만으로 볼지?
- Alertmanager 알림 채널은 Slack, email, GitHub issue 중 무엇을 사용할지?
- 운영 전환 시 7일 retention이 충분한지, 장기 보관을 Google Managed Service
  for Prometheus 또는 remote write로 넘길지?

## 용어

| 용어 | 뜻 |
|---|---|
| Prometheus | metric을 주기적으로 수집하고 저장하는 time series database |
| Grafana | Prometheus 같은 datasource의 metric을 dashboard로 보여주는 UI |
| kube-prometheus-stack | Prometheus Operator, Prometheus, Alertmanager, Grafana와 기본 rule/dashboard를 묶은 Helm chart |
| Prometheus Operator | Kubernetes CRD로 Prometheus, ServiceMonitor, PodMonitor를 관리하는 controller |
| ServiceMonitor | 특정 Kubernetes Service를 Prometheus scrape target으로 등록하는 CRD |
| PodMonitor | Service 없이 Pod를 Prometheus scrape target으로 등록하는 CRD |
| node-exporter | node의 CPU, memory, disk 같은 OS 지표를 노출하는 exporter |
| kube-state-metrics | Deployment, Pod, PVC 같은 Kubernetes object 상태를 metric으로 노출하는 component |
| retention | Prometheus가 metric을 보관하는 기간 또는 용량 |
| PVC | PersistentVolumeClaim. Pod가 재시작되어도 유지되는 Kubernetes storage 요청 |
| cardinality | metric label 조합의 개수. 너무 높으면 Prometheus 저장소와 CPU 비용이 증가 |
| remote write | Prometheus가 수집한 metric을 외부 장기 저장소로 보내는 기능 |
| Alertmanager | Prometheus alert rule 결과를 묶고 알림 채널로 전송하는 component |

## 로그 플랫폼(ELK) 전략 (#96)

로그 측 상세 설계는
`superpowers/specs/2026-07-13-elk-architecture-design.md`를 따른다. 요약:

- **ECK operator 확정** — admin root `elastic-k8s`(신설)에서 operator를
  helm_release로, ES/Kibana는 CR로 관리한다.
- **Cloud Logging과 병행** — Cloud Logging은 기본 안전망(시스템/audit),
  ELK는 앱·Airflow 로그 검색/분석. Cloud Monitoring/Prometheus 분리와 동일
  원칙이며 서로 대체하지 않는다.
- **수집 범위는 좁게** — 초기 `airflow`·`autoresearch` namespace 컨테이너
  로그만. 시스템 로그는 제외.
- **dev 최소 구성** — single-node ES(heap 1G, PVC 30Gi), 신규 node pool
  없음(실측 여유 기준). Kibana는 ClusterIP + port-forward 전용.
- **보관/백업** — ILM 7일 삭제(Prometheus retention과 정합), GCS snapshot
  일 1회·7일 보관.

## 참고 문서

- [kube-prometheus-stack 공식 chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator 소개](https://prometheus-operator.dev/docs/getting-started/introduction/)
- [Grafana Kubernetes 설치 문서](https://grafana.com/docs/grafana/latest/setup-grafana/installation/kubernetes/)
- [Google Managed Service for Prometheus](https://docs.cloud.google.com/stackdriver/docs/managed-prometheus)
