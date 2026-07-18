# MLflow GKE 운영 구조 설계

> 관련 이슈: `SKYAHO/Autoresearch-infra#91`, `SKYAHO/Autoresearch#95`
> 대상 환경: dev
> 상태: 설계 기준. 2026-07-18 실제 구현(#92~#95, #232)과 대조·정정함.
> 확정 as-built는 `docs/MLFLOW_OPERATIONS_RUNBOOK.md`와
> `docs/CHANGE_HISTORY.md`가 기준이며, 설계와 달라진 지점은 15절에 정리한다.

## 1. 목표

MLflow Tracking Server를 기존 dev GKE에 배치하고, Cloud SQL PostgreSQL에
실험 metadata를, 전용 GCS bucket에 artifact를 저장한다. GCP 인증에는
Workload Identity를 사용하며 서비스 계정 key JSON은 사용하지 않는다.

이번 이슈는 구조와 보안 경계를 결정한다. 실제 GCP 리소스, Kubernetes
리소스, image 발행과 배포는 후속 이슈에서 리뷰 가능한 크기로 나눈다.

## 2. 저장소와 이슈 경계

### `SKYAHO/Autoresearch`

- `deploy/mlflow/Dockerfile`과 runtime dependency
- GAR image build/push와 immutable digest 산출
- `deploy/mlflow/kubernetes/`의 Deployment와 Service
- Python MLflow client, training CLI, smoke test
- `MLFLOW_TRACKING_URI` 주입 계약

### `SKYAHO/Autoresearch-infra`

- MLflow 전용 GCS bucket과 bucket IAM
- 기존 Cloud SQL instance 내부의 MLflow database/user
- Secret Manager와 비밀번호 생성 정책
- MLflow 전용 GSA/KSA와 Workload Identity binding
- 기존 `terraform/admin/autoresearch-k8s` Kubernetes 공통 경계
- caller Namespace에 따른 NetworkPolicy 변경
- Terraform outputs와 운영 runbook

애플리케이션 Deployment와 Service는 Infra 저장소에 중복 정의하지 않는다.
새 Kubernetes Terraform root도 만들지 않는다. (두 항목 모두 구현에서 변경됨 →
15절: Deployment는 인프라 저장소 `deploy/mlflow/`에 두고, admin root
`terraform/admin/mlflow-k8s`를 신설했다.)

| 작업 | 이슈 |
| --- | --- |
| 운영 구조 설계 | Infra #91 |
| Artifact bucket, MLflow GSA와 bucket IAM | Infra #92 |
| Cloud SQL DB/user/secret | Infra #93 |
| MLflow KSA, KSA annotation, WI binding과 NetworkPolicy | Infra #94 |
| Deployment/Service 및 통합 | Autoresearch #95 |
| 운영 runbook | Infra #95 |

## 3. 기존 리소스 재사용

- Namespace: `autoresearch`
- Kubernetes boundary: `terraform/admin/autoresearch-k8s`
- GKE cluster와 일반 node pool `dev-default`
- Private IP 전용 PostgreSQL 15 Cloud SQL instance
- Artifact Registry repository `autoresearch-dev-docker`
- Workload Identity pool과 GKE metadata server
- `autoresearch` egress NetworkPolicy의 같은 Namespace, DNS, Cloud SQL
  5432, metadata server, HTTPS 규칙
- Secret Manager의 `random_password` 저장 패턴
- bucket-level IAM과 public access prevention 패턴

공통 `autoresearch-app` GSA/KSA는 재사용하지 않는다. MLflow의 artifact
변경 권한과 장애 영향을 기존 application workload에서 분리한다.

## 4. 전체 흐름

```text
Airflow 또는 training Pod
  -> http://mlflow.autoresearch.svc.cluster.local:5000
  -> MLflow Tracking Server (autoresearch/mlflow KSA)
       -> Cloud SQL private IP:5432 (DB username/password)
       -> GCS artifact bucket (Workload Identity/ADC)

승인된 운영자 또는 배포 주체
  -> Secret Manager에서 DB password 조회
  -> autoresearch/mlflow-db Kubernetes Secret 생성·회전
```

`--serve-artifacts`를 사용하므로 client는 GCS에 직접 접근하지 않는다.
Airflow와 training workload에는 MLflow artifact bucket IAM을 추가하지 않는다.

## 5. Kubernetes 배치와 노출

- 기존 `autoresearch` Namespace를 사용한다.
- Service는 `ClusterIP`, port/targetPort는 모두 `5000`이다.
- 외부 Ingress는 만들지 않는다.
- UI는 `kubectl port-forward service/mlflow 5000:5000`으로 접근한다.
- MVP replica는 `1`이다. migration과 동시 실행 특성을 검증하기 전에는
  수평 확장하지 않는다.
- Spot pool에는 배치하지 않고 일반 dev node pool에 고정한다.

dev manifest의 node selector는 다음 값이다.

```yaml
cloud.google.com/gke-nodepool: dev-default
```

`dev-default`는 dev GKE 전용 값이다. 다른 환경을 추가할 때는 Helm/Kustomize
value 또는 환경 overlay로 주입하고 해당 환경의 일반 node pool 이름으로
바꿔야 한다. Infra #94에서는 검증 가능한 Terraform output 추가를 검토한다.

## 6. GSA/KSA와 Workload Identity

- GSA: Infra #92에서 artifact bucket과 함께 만드는 MLflow 전용 계정
- KSA: `autoresearch` Namespace의 `mlflow`
- KSA annotation: `iam.gke.io/gcp-service-account`
- Infra #94에서 GSA에 해당 KSA principal만
  `roles/iam.workloadIdentityUser`로 binding한다.
- Pod에는 `GOOGLE_APPLICATION_CREDENTIALS`를 설정하거나 key JSON을
  mount하지 않는다.

설계 시점 기준은 Private IP 직접 연결(DB username/password)만 쓰므로 MLflow
GSA에 `roles/cloudsql.client`와 `roles/secretmanager.secretAccessor`를 주지
않는 것이었다. 실제 구현(#92~#94)에서 MLflow GSA에 부여된 role은 다음과 같다.

- artifact bucket resource-level `roles/storage.objectAdmin` +
  `roles/storage.legacyBucketReader` (#204: objectAdmin에 `storage.buckets.get`
  부재 보완)
- project-level `roles/cloudsql.client`
- MLflow DB password secret resource-level `roles/secretmanager.secretAccessor`

OAuth2-proxy client secret(#232)에는 GSA 접근권을 주지 않고 operator가 주입한다.
현재 런타임 경로는 여전히 Private IP 직접 연결 + operator가 주입한 K8s Secret
`mlflow-db` 읽기이므로 `cloudsql.client`와 DB secret `secretAccessor`는 이 경로에
필수가 아니다 — 최소권한 축소 후속 검토 대상이다(→15절, 13절 위험표).

## 7. GCS Artifact Store

- MLflow 전용 bucket을 만든다.
- Uniform Bucket-Level Access와 Public Access Prevention을 적용한다.
- `force_destroy = false`, `prevent_destroy = true`를 기본으로 한다.
- dev 비용과 rollback 필요성을 고려하여 versioning/lifecycle은 Infra #92
  plan에서 최종 확인한다.
- Infra #92에서 MLflow GSA를 bucket과 함께 생성한 뒤 bucket IAM을 부여한다.
  따라서 #92 PR은 아직 존재하지 않는 #94 리소스를 참조하지 않는다.

MVP에서는 MLflow GSA에 bucket 범위의 `roles/storage.objectAdmin`을 사용한다.
이는 업로드, 조회, 덮어쓰기와 삭제를 지원하기 위한 실용적인 초기 권한이며
최종 최소 권한이라고 단정하지 않는다. smoke test와 실제 운영 동작에서 필요한
operation을 확인한 뒤 더 좁은 권한으로 축소 가능한지 후속 검토한다. 프로젝트
수준 Storage Admin은 허용하지 않는다.

## 8. PostgreSQL Backend Store

기존 Cloud SQL PostgreSQL 15 instance를 재사용하고 MLflow 전용 database와
user를 만든다. Airflow 또는 application database와 table을 섞지 않는다.

MVP 비밀번호는 URI 예약문자 문제를 피하기 위해 충분히 긴 URL-safe 값으로
생성한다.

- `random_password` 길이: 최소 32자
- 영문 대·소문자와 숫자 사용
- `special = false`

Backend Store 접속 정보는 Kubernetes Secret `mlflow-db`에 `POSTGRES_HOST`/
`POSTGRES_USER`/`POSTGRES_DB`/`POSTGRES_PASSWORD` 분해 key로 보관하고(완성 URI를
단일 key로 넣지 않는다), container 시작 시 이 값들로 URI를 조립한다(11절). Git,
manifest와 명령 로그에는 값을 기록하지 않는다.

MVP는 기존 Private IP에 직접 연결한다. PostgreSQL SSL 사용, `sslmode`, client
certificate 배포 여부는 Infra #93 구현과 실제 연결 검증에서 현재 Cloud SQL
설정을 확인한 뒤 확정한다. 검증 없이 `sslmode=require`를 강제하지 않는다.
Private VPC 내부의 비암호화 연결을 MVP에서 수용하게 되면 그 한계를 #93 PR과
runbook에 명시한다. 운영 수준의 전송 암호화 또는 인증서 관리 요구가 생기면
Cloud SQL Auth Proxy/Connector 전환을 검토한다.

## 9. Secret 전달 경계

Secret Manager가 password의 원본 저장소다. MVP에서는 승인된 운영자 또는
배포 주체가 값을 읽고 Kubernetes Secret을 생성한다. MLflow Pod는 Kubernetes
Secret만 읽는다.

Secret payload를 가진 `kubernetes_secret_v1`을 Terraform으로 만들지 않는다.
동일 password가 Kubernetes Terraform state에도 추가되는 것을 방지하기 위해서다.
현재 TLS가 활성화되지 않은 학습용 Vault에도 실제 DB password를 저장하지 않는다.

Runbook의 주입 절차는 다음 보안 계약을 지켜야 한다.

- `umask 077`을 먼저 적용한다.
- Secret Manager 값을 mode 600 임시 env file 또는 표준 입력으로 전달한다.
- `kubectl --from-env-file`과 client-side dry-run을 사용한다.
- password를 `--from-literal` 인수에 직접 쓰지 않는다.
- stdout, shell trace, CI log에 secret 값을 출력하지 않는다.
- 성공·실패와 관계없이 임시 file을 즉시 삭제한다.

```bash
umask 077
tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

# POSTGRES_* 값을 stdout에 표시하지 않고 "$tmp_file"에 기록한다.
chmod 600 "$tmp_file"
kubectl -n autoresearch create secret generic mlflow-db \
  --from-env-file="$tmp_file" \
  --dry-run=client \
  -o yaml | kubectl apply -f -
```

실제 조회·기록 명령은 Infra #95 runbook에서 승인된 운영 주체와 도구를 확정한
뒤 제공한다.

## 10. NetworkPolicy와 caller 확인 게이트

Infra #94 구현 전에 실제 MLflow client Pod의 Namespace를 배포 설정에서
확인한다. DAG가 실행되는 위치만 보고 추정하지 않는다.

- caller가 `autoresearch` Namespace이면 기존 같은-Namespace egress 규칙을
  재사용하고 불필요한 Airflow egress 변경을 하지 않는다.
- caller가 `airflow` Namespace의 Scheduler/Worker/KPO Pod이면 Airflow
  egress에 다음 두 규칙을 함께 추가한다.
  1. `cluster_services_cidr`의 TCP 5000: 현재 Calico pre-DNAT Service VIP 평가
  2. `autoresearch` Namespace의 MLflow Pod selector TCP 5000: post-DNAT 또는
     향후 dataplane 변화 대비

MLflow Pod label 계약은 다음과 같다.

```yaml
app.kubernetes.io/name: mlflow
app.kubernetes.io/component: tracking-server
```

실제 caller가 두 Namespace에 모두 존재하면 필요한 양쪽 경로만 허용한다.

## 11. Image와 실행 계약

- base/runtime은 `SKYAHO/Autoresearch#94` 결과를 그대로 사용한다.
- MLflow는 `v2.22.1`을 유지한다.
- build tag는 `sha-<40-character-git-sha>`다.
- Deployment는 `<GAR_IMAGE>@sha256:<digest>`를 사용한다.
- container 시작 시 package를 설치하지 않는다.

설계 시점에는 완성 `MLFLOW_BACKEND_STORE_URI`를 `$(VAR)` 치환으로 넘기는 exec
형식을 기준으로 삼았으나, 실제 구현은 Secret을 `POSTGRES_*` 분해 key로 주입하는
방식(8·9절)에 맞춰 container 시작 시 `sh -c`로 URI를 조립한다. `exec`로 mlflow를
PID 1로 실행해 signal 처리를 유지하고, `--workers 2`와 메모리 튜닝은 #229 OOM
대응을 반영한다.

```yaml
command:
  - /bin/sh
  - -c
  - |
    set -eu
    exec mlflow server \
      --host 0.0.0.0 --port 5000 --workers 2 \
      --backend-store-uri \
      "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:5432/${POSTGRES_DB}" \
      --serve-artifacts \
      --artifacts-destination "${MLFLOW_ARTIFACT_DESTINATION}"
```

`POSTGRES_*`와 `MLFLOW_ARTIFACT_DESTINATION`은 Secret/env로 주입하고 URI는 위와
같이 조립하므로 완성 URI를 Secret 단일 key나 manifest에 남기지 않는다. 이는 설계
초안의 "`$(VAR)`만 사용, `sh -c` 미사용" 기준을 구현에서 바꾼 지점이다(→15절).

## 12. Probe와 통합 검증 분리

실제 `v2.22.1` 파생 image에서 endpoint와 장애 동작을 확인한 뒤 probe를
확정한다. `/health`는 우선 검증 후보이지 DB와 GCS 통합 상태의 증거가 아니다.

- `startupProbe`: server 초기화와 DB migration 시간을 허용한다.
- `readinessProbe`: HTTP process가 요청을 받을 준비가 됐는지 확인한다.
- `livenessProbe`: 장기간 응답하지 않는 process만 재시작한다.
- 일시적인 DB/GCS 장애가 liveness restart loop를 만들지 않게 한다.

PostgreSQL metadata 기록과 GCS upload/download는 probe가 아니라 기존
`scripts/mlflow_smoke_test.py`로 검증한다.

## 13. 주요 위험과 후속 전환 조건

| 위험 | MVP 대응 | 후속 전환 조건 |
| --- | --- | --- |
| 수동 secret 주입 오류 | 제한된 운영자, 임시 file 보호, runbook | ESO/CSI 도입과 TLS/권한 설계 완료 |
| DB 연결 암호화 미확정 | #93에서 실제 설정·연결 검증 | 운영 암호화 요구 시 Proxy/Connector |
| GCS IAM 과다 가능성 | 전용 bucket으로 범위 제한 | 실제 operation 확인 후 role 축소 |
| 잘못된 node pool 배치 | dev selector와 replica 1 | 환경 overlay 도입 시 value화 |
| 불필요한 Airflow egress | caller Namespace 사전 확인 | caller 변경 시 정책 재검토 |
| 단일 replica 장애 | dev MVP로 수용 | migration/동시성 검증 후 HA 설계 |

## 14. 완료 기준

- 저장소와 이슈별 책임이 중복 없이 정의됐다.
- GSA/KSA, bucket IAM, DB와 Secret 주체가 명확하다.
- caller Namespace에 따른 NetworkPolicy 판단 기준이 있다.
- image, node placement, probe와 smoke test 계약이 정의됐다.
- 후속 #92~#95가 이 문서를 기준으로 독립 구현될 수 있다.

## 15. 구현 반영 차이 (2026-07-18)

이 문서는 구현 전 설계 기준이라 실제 배포와 아래 지점이 다르다. 확정 as-built는
`docs/MLFLOW_OPERATIONS_RUNBOOK.md`와 `docs/CHANGE_HISTORY.md`가 기준이다.

| 항목 | 설계(본문) | 실제 구현 |
| --- | --- | --- |
| Namespace | 기존 `autoresearch`(3·5절) | MLflow 전용 `mlflow` 신설 |
| K8s root | 새 root 안 만듦(2절) | 신규 `terraform/admin/mlflow-k8s` |
| Deploy 위치 | 앱 repo `deploy/mlflow/kubernetes/`(2절) | 인프라 repo `deploy/mlflow/` |
| 배포 방식 | 미확정 | ArgoCD Application(manual sync), 이미지 GAR 빌드 |
| Backend URI | 완성 URI 단일 key + `$(VAR)` | `POSTGRES_*` 분해 + `sh -c` 조립(8·11절) |
| GSA IAM | cloudsql.client·secretAccessor 미부여 | 둘 다 부여(6절). 런타임 불필요 — 축소 검토 |
| UI 인증 | 없음(port-forward만) | 앞단 OAuth2-proxy(Google + 허용 이메일, #232) |

운영 중 확인된 교훈(참고): gunicorn 기본 worker가 512Mi를 초과해 OOM →
1Gi/`--workers 2`/startupProbe(#229). 앱팀이 수동 생성한 artifact 버킷을 발견해
`terraform import`로 adopt(#226).
