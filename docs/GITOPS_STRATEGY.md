# ArgoCD GitOps 운영 전략

이 문서는 Issue #82 기준 ArgoCD 도입 전 운영 설계를 정리한다. 실제 ArgoCD 설치와
Application 생성은 후속 이슈에서 진행한다.

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
| `SKYAHO/Autoresearch-infra` | 제한적 | ArgoCD 설치 기반, AppProject/Application 샘플 |
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

## 후속 이슈 입력값

| 이슈 | 입력값 |
|---|---|
| #83 argocd namespace 및 설치 기반 | `terraform/admin/argocd-k8s`, namespace `argocd`, values 위치 |
| #84 ArgoCD 최소 설치 및 내부 접근 | 외부 공개 금지, port-forward 또는 internal 접근 |
| #85 AppProject/Application 샘플 | `autoresearch-dev` AppProject, Airflow Application manual sync |
| #86 ArgoCD 운영 runbook | sync, rollback, drift 확인, secret 주입 절차 |

## 운영 전 확인 질문

- ArgoCD가 `SKYAHO/Autoresearch-airflow`를 읽을 때 public 접근으로 충분한가?
- Airflow values의 어느 경로를 ArgoCD Application source로 삼을 것인가?
- Airflow image tag 업데이트는 Git commit으로 할 것인가, CI가 values를 갱신할 것인가?
- auto-sync를 켜기 전 어떤 dashboard와 alert로 실패를 볼 것인가?
- secret payload 주입은 수동, External Secrets, CSI Driver 중 무엇으로 갈 것인가?

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
