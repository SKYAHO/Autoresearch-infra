# ArgoCD GitOps 운영 전략

이 문서는 Issue #82에서 시작한 ArgoCD 운영 설계·책임 경계를 정리한다. ArgoCD는
이미 설치(#84)됐고 monitoring(#183)·argo-rollouts(#186)를 ArgoCD Application으로
이관해 운영 중이다. 이 문서는 그 책임 경계("Terraform=플랫폼 경계, ArgoCD=앱")와
Terraform→ArgoCD 이관 전략의 단일 기준이다.

## 목적

현재 Kubernetes 리소스는 Terraform admin root 또는 사람이 직접 Helm/kubectl로
적용한다. workload가 늘어나면 "어떤 YAML이 현재 cluster 상태의 기준인가"가
흐려질 수 있다. ArgoCD는 Git 저장소를 desired state의 기준으로 삼아 cluster의 live
state와 비교하고, 차이가 나면 OutOfSync로 표시하거나 sync한다.

## 책임 경계

| 영역 | 관리 도구 | 이유 |
|---|---|---|
| GCP 리소스 | Terraform dev root | VPC, GKE, Cloud SQL, IAM, GCS, BigQuery, Cloud Run |
| Kubernetes platform boundary | Terraform admin root | namespace, 기본 RBAC, Workload Identity annotation, 초기 설치 경계 |
| 애플리케이션 Helm values/YAML | ArgoCD | 반복 배포, drift 확인, rollback, sync 이력 |
| Secret payload | Secret Manager 또는 운영자 주입 | Git과 Terraform state에 평문 저장 금지 |

Terraform은 "ArgoCD가 올라갈 길"을 만들고, ArgoCD는 "애플리케이션을 계속 맞추는
역할"을 맡는다. 같은 리소스를 Terraform과 ArgoCD가 동시에 관리하지 않는다.

## ArgoCD가 관리할 저장소

| 저장소 | ArgoCD 관리 여부 | 범위 |
|---|---|---|
| `SKYAHO/Autoresearch-infra` | 관리 | ArgoCD 설치 기반, AppProject + monitoring·argo-rollouts Application(`deploy/*` umbrella chart, #183/#186) |
| `SKYAHO/Autoresearch-airflow` | 우선 관리 대상 | Airflow Helm values, DAG/image 배포 경계 |
| `SKYAHO/Autoresearch` | 후속 관리 대상 | 앱/collector/batch Kubernetes manifest 또는 Helm chart |

초기에는 Airflow 저장소를 1순위로 연결한다. Airflow는 이미 이 저장소에서
Kubernetes 경계만 제공하고, 실제 chart values와 DAG 구현은
`SKYAHO/Autoresearch-airflow`에 있으므로 GitOps 전환 효과가 크다.

## Sync 정책

| 환경 | 기본 정책 | 설명 |
|---|---|---|
| dev 초기 | manual sync | 사람이 diff를 확인하고 sync한다 |
| dev 안정화 후 | auto-sync 후보 | prune/self-heal은 리소스별로 신중히 켠다 |
| 운영 전환 | Application별 결정 | DB, PVC, Secret 관련 변경은 manual 우선 |

초기 원칙:

- auto-sync는 처음부터 켜지 않는다.
- prune은 orphan 리소스 삭제를 유발하므로 초기에는 끈다.
- self-heal은 사람이 임시 조치한 리소스를 되돌릴 수 있으므로 충분히 검증 후 켠다.
- 배포 자동화보다 drift 가시화를 먼저 얻는다.

## Secret 처리 원칙

ArgoCD가 Git 저장소를 읽는다고 해서 secret payload를 Git에 넣어도 된다는 뜻은
아니다.

금지:

- Kubernetes Secret manifest에 실제 base64 payload 커밋
- repo credential, webhook secret, OAuth secret을 Terraform 변수나 PR 본문에 기록
- service account JSON key 생성과 전달

허용:

- Secret Manager에 payload 저장
- Workload Identity로 workload가 필요한 secret만 읽기
- External Secrets Operator 또는 Secret Manager CSI Driver는 별도 설계 후 도입
- dev에서 운영자가 `kubectl create secret`으로 payload 주입하되 절차는 문서화

초기 ArgoCD repo 연결은 가능하면 public repo 또는 GitHub App/OIDC 계열을 검토한다.
private repo token이 필요하면 Kubernetes Secret payload로 주입하고 Git에 남기지
않는다.

## AppProject 기준

초기에는 `autoresearch-dev` AppProject 하나로 시작한다.

| 항목 | 기준 |
|---|---|
| 허용 source repo | `SKYAHO/Autoresearch-airflow`, 필요 시 `SKYAHO/Autoresearch` |
| 허용 destination cluster | in-cluster dev GKE |
| 허용 namespace | `airflow`, 후속으로 앱 namespace |
| 금지 리소스 | cluster-wide 리소스는 기본 금지, 필요 시 PR로 예외 |

ArgoCD 자체, CRD, ClusterRole처럼 cluster-wide 권한이 큰 리소스는 플랫폼 admin
root 또는 별도 platform AppProject에서 관리한다.

## 점진 배포(Argo Rollouts) 경계 (#87)

상세 결정은
`superpowers/specs/2026-07-13-argo-rollouts-scope-design.md`를 따른다. 요약:

- **적용 대상은 Autoresearch 앱 API(stateless Deployment)뿐**이다. Airflow
  (stateful/chart 소유 분리), batch pod(일회성), 플랫폼 컴포넌트(ArgoCD·
  모니터링·Vault), Cloud Run proxy(자체 traffic split)는 제외한다.
- **Canary만 사용**한다(replica-weight 방식, 트래픽 라우터 없음).
  Blue-Green은 dev 최소 비용 원칙과 충돌해 제외한다.
- **1단계는 수동 promote**다. canary pause에서 운영자가 Grafana로 확인 후
  promote하며, AnalysisTemplate 기반 자동 판단은 안정화 후 2단계로 미룬다.
- **책임 경계**: ArgoCD는 Rollout manifest를 sync만 하고, 전환 실행은
  Rollouts controller, promote/abort는 운영자가 담당한다. controller 설치는
  Terraform admin root(신설)가 맡는다.
- **도입 시점**: controller 설치·샘플 검증은 #88~#90에서 선행하고(샘플은
  검증 후 폐기), 실 서비스 적용은 앱 첫 배포 이슈에서 진행한다.

## Terraform → ArgoCD 이관 (#183 monitoring 파일럿)

플랫폼 스택(helm_release)을 ArgoCD Application으로 이관해 "Terraform=경로,
ArgoCD=앱" 책임 분리를 실제로 구현한다. **monitoring을 첫 파일럿**으로 삼는다.

- **source**: infra repo `deploy/<stack>/` umbrella chart(upstream chart를
  dependency로 감싸 버전 pin + values 관리). infra repo가 public이라 ArgoCD
  자격증명 불필요.
- **책임 분리**: namespace·RBAC 등 플랫폼 경계는 Terraform 유지, chart(앱)는
  ArgoCD Application이 관리. 같은 리소스를 둘이 동시에 관리하지 않는다.
- **무중단 adopt**: `terraform state rm`(destroy 아님)으로 실행 중 release를
  TF 관리에서 떼고, ArgoCD가 인수한다. 최초 sync 전 diff 검토 필수(helm
  managed-by 라벨 차이는 ServerSideApply로 흡수). 롤백은 helm_release import.
- **operator 주입 secret**(grafana-admin/oauth)은 chart 밖이라 ArgoCD가
  관리·prune하지 않는다 — values는 이름만 참조.
- sync는 manual부터(초기 원칙).

**이관 진행 현황**:

| 스택 | 상태 | 비고 |
|---|---|---|
| monitoring (#183) | ✅ 완료 | 첫 파일럿. PVC adopt, kube-system exporter destination, ServerSideApply |
| argo-rollouts (#186) | ✅ 완료 | 무상태 컨트롤러. PVC/webhook/kube-system 불필요, 실행 중 Rollout CR 0개 |
| airflow (#17) | 예정 | 앱 스택. 다음 확장 후보 |
| mlflow (#91~#95) | 설계 완료 | 신규 배포(adopt 아님). `deploy/mlflow` chart + `mlflow-k8s` root, manual sync. 설계 `superpowers/specs/2026-07-17-mlflow-operating-design.md` |
| vault | 후순위 | **stateful secret store라 고위험** — TLS 하드닝(#180) 후에만 |
| argocd 자체 | 보류 | 부트스트랩(설치)은 Terraform 유지가 표준 |

설계 상세: `superpowers/specs/2026-07-14-monitoring-argocd-migration-design.md`,
`superpowers/specs/2026-07-14-argo-rollouts-argocd-migration-design.md`.

> ArgoCD 설치 기반(#83/#84), AppProject/Application(#85), 운영 runbook(#86)은
> 완료됐다. 설치·초기 구성 결정은 `docs/CHANGE_HISTORY.md`와
> [`ARGOCD_OPERATIONS_RUNBOOK.md`](ARGOCD_OPERATIONS_RUNBOOK.md)를 참조한다.
> airflow(#17) 이관은 다음 확장 후보로 남아 있다.

## 용어

| 용어 | 뜻 |
|---|---|
| GitOps | Git 저장소의 선언형 설정을 실제 운영 상태의 기준으로 삼는 운영 방식 |
| Desired state | Git에 선언된 목표 상태 |
| Live state | Kubernetes cluster에 실제 존재하는 현재 상태 |
| OutOfSync | desired state와 live state가 다르다는 ArgoCD 상태 |
| Sync | Git에 있는 desired state를 cluster에 적용하는 작업 |
| Prune | Git에서 사라진 리소스를 cluster에서도 삭제하는 동작 |
| Self-heal | cluster에서 사람이 바꾼 내용을 ArgoCD가 Git 기준으로 되돌리는 동작 |
| AppProject | ArgoCD Application이 접근할 repo, namespace, resource 범위를 제한하는 단위 |
| Application | ArgoCD가 하나의 source repo/path/chart를 하나의 destination에 배포하는 단위 |

## 참고 문서

- [Argo CD 공식 문서](https://argo-cd.readthedocs.io/en/stable/)
- [Argo CD Automated Sync Policy](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)
- [Argo CD Secret Management](https://argo-cd.readthedocs.io/en/stable/operator-manual/secret-management/)
