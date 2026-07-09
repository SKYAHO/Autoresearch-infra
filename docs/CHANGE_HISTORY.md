# 인프라 변경 이력 요약

완료된 설계 spec과 구현 plan의 핵심 결정만 보존한다. 현재 운영 절차는
`TEAM_OPERATIONS_RUNBOOK.md`와 `TERRAFORM_DEV.md`를 우선한다.

## 2026-07-03: dev GKE 클러스터

- Issue #5, PR #14에서 dev GKE Standard zonal 클러스터를 구성했다.
- private nodes, VPC-native alias IP, 별도 node service account, Artifact
  Registry reader, logging/monitoring writer 권한을 적용했다.
- app Workload Identity는 `autoresearch/autoresearch-app` KSA와
  `autoresearch-dev-app` GSA 매핑으로 시작했다.

## 2026-07-06: GitHub Actions Terraform plan + OIDC

- Issue #6, PR #15에서 GitHub Actions PR plan을 구성했다.
- service account key 대신 GitHub OIDC + Workload Identity Federation을 사용한다.
- CI SA는 dev plan에 필요한 viewer/state 접근 중심으로 운영한다.
- bootstrap root는 state bucket, WIF pool/provider, CI SA를 1회성으로 관리한다.

## 2026-07-07: dev proxy Cloud Run

- Issue #27, PR #30에서 `autoresearch-dev-proxy` Cloud Run 서비스를 정의했다.
- min instances 0, internal ingress, invoker IAM 기반으로 시작했다.
- 이미지 재배포는 `:latest` 재사용이 아니라 새 tag 또는 digest로 `proxy_image`를
  바꾸고 apply하는 방식을 표준으로 삼았다.
- Issue #73, PR #74에서 Airflow batch GSA
  `autoresearch-dev-airflow-batch@ar-infra-501607.iam.gserviceaccount.com`에
  `autoresearch-dev-proxy` 서비스 단위 `roles/run.invoker`를 부여했다.

## 2026-07-08: Airflow 운영 경계

- Issue #32 계열에서 Airflow용 GCP 리소스와 Kubernetes 경계를 분리했다.
- dev root는 Airflow GSA, Cloud SQL metadata DB, DAG/log bucket, Secret Manager,
  BigQuery/GCS IAM을 관리한다.
- `terraform/admin/airflow-k8s`는 namespace, KSA, RBAC, quota, limit range,
  network policy를 별도 state로 관리한다.
- Airflow batch workload는 전용 GSA
  `autoresearch-dev-airflow-batch@ar-infra-501607.iam.gserviceaccount.com`로
  분리했다.

## 2026-07-08: Bastion host

- Issue #47, PR #50에서 외부 IP 없는 IAP 전용 bastion을 도입했다.
- 목적은 Airflow UI 등 VPC 내부 서비스 접속 터널이다.
- kubectl은 Bastion이 아니라 GKE DNS endpoint를 기본 경로로 사용한다.
- 미사용 시 `bastion_enabled=false`로 제거할 수 있다.

## 2026-07-08: Airflow 내부 DNS와 ILB

- Issue #48, PR #51에서 Airflow UI용 내부 IP와 private DNS zone을 구성했다.
- `airflow.dev.autoresearch.internal`은 VPC 내부에서만 해석된다.
- UI 접속 기본 경로는 Bastion `-L 8080` 포트 포워딩 후
  `http://localhost:8080`이다.
- Google OAuth redirect URI 제약으로 `.internal` 직접 로그인은 사용하지 않는다.

## 2026-07-08: GKE DNS endpoint

- Issue #45, PR #46에서 GKE DNS 기반 control plane endpoint를 기본 접근 경로로
  정리했다.
- 팀원 IP 등록 없이 `roles/container.viewer`의 `container.clusters.connect`로
  kubeconfig를 받을 수 있다.
- `master_authorized_networks`는 IP endpoint 예비 경로로만 남긴다.

## 2026-07-08: GKE worker node sizing

- dev 기본 node pool은 `e2-standard-4`, Airflow node pool은 `e2-standard-2`로
  정리했다.
- GKE control plane은 관리형이므로 사용자가 마스터 노드 CPU/RAM을 직접 지정하지
  않는다.

## 2026-07-08: dev state drift cleanup

- Issue #39에서 dev state에 남아 있던 legacy node pool, legacy Airflow batch WI
  binding, 불필요한 Cloud Build 기본 compute SA 권한, 추가 master authorized
  network CIDR을 정리했다.
- 유지 근거가 없는 리소스는 state만 숨기지 않고 실제 리소스까지 정리한다는 원칙을
  확인했다.

## 2026-07-09: 문서 구조 정리

- Issue #71에서 팀원 접근 runbook, Terraform 운영 문서, 변경 이력을 분리했다.
- 완료된 spec/plan 상세 문서는 이 파일의 요약 이력으로 압축했다.
