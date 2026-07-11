# 아키텍처 개요

> Last Updated: 2026-07-08

dev 환경 인프라의 전체 그림과 설계 결정을 담은 문서입니다. 상세 구성은
`docs/TERRAFORM_DEV.md`, 파일별 책임은 `agent-project-reference.md`를
참고합니다.

## 시스템 맥락

이 저장소는 AutoResearch(YouTube 트렌딩 데이터 기반 CTR 모델링
프로젝트)의 GCP 인프라를 관리합니다. 일반 애플리케이션 코드는
`SKYAHO/Autoresearch`, Airflow DAG/Helm/image 코드는
`SKYAHO/Autoresearch-airflow`에 있으며, 이 저장소는 해당 워크로드가 실행될
기반(네트워크, 저장소, 데이터베이스, 클러스터, 시크릿)과 검증·배포
자동화를 제공합니다.

```
GitHub (PR) ──▶ GitHub Actions (lint / Terraform plan / Claude review)
                          │ OIDC/WIF
                          ▼
GCP project (dev, asia-northeast3)
├── VPC (custom) ── subnet 10.10.0.0/20 (Private Google Access)
│   ├── firewall: IAP SSH (ssh-iap 태그)
│   ├── Cloud Router + Cloud NAT (egress)
│   ├── bastion host ── IAP 터널 종단, 외부 IP 없음 (#47)
│   ├── Cloud DNS private zone dev.autoresearch.internal (#48)
│   └── private services range 192.168.0.0/20 (service networking peering)
├── GKE dev cluster ── 앱 워크로드 실행
│   ├── 컨트롤 플레인 DNS 엔드포인트 ── IAM 기반 kubectl 접속 (#45)
│   └── Airflow internal ILB (`airflow_ilb_ip` output) ── VPC 내부 전용 UI (#48)
├── Cloud SQL (PostgreSQL 15, private IP only) ◀── GKE에서 접속
├── Memorystore for Redis (Feast Online Store, private PSA, AUTH/TLS) ◀── GKE에서 접속 (#129, apply 대기)
├── Artifact Registry (autoresearch-dev-docker) ◀── 이미지 push/pull
├── GCS / BigQuery ── raw data, analytics, Feast offline store
├── Cloud Run proxy ── 내부 호출용 인증 gate 후보
└── Secret Manager ── DB 비밀번호와 API key metadata/IAM
```

## 주요 설계 결정

### 네트워크: private 우선
- Cloud SQL은 `ipv4_enabled=false`(private IP only)로 두고 service
  networking peering으로 연결합니다.
- Redis는 같은 Private Service Access 연결을 재사용하고 AUTH/TLS를 켭니다.
- 외부 egress는 Cloud NAT, 관리용 SSH는 IAP 경유입니다.
- subnet은 Private Google Access를 켜서 Google API 접근을 내부
  경로로 처리합니다.

### 인증: OIDC/WIF 우선
- GitHub Actions의 GCP 인증은 service account key 파일 대신 OIDC 기반
  Workload Identity Federation을 사용합니다.

### 비용: dev 최소 기준
- Cloud SQL `db-f1-micro` ZONAL, GKE 최소 구성 등 dev 리소스는 최소
  비용으로 시작하고, 운영 전환 시 조정 항목을 문서에 남깁니다.
- dev에서는 `deletion_protection=false`를 허용하되 PR에 명시합니다.

### 시크릿: 생성-저장 분리
- DB 비밀번호는 `random_password`로 생성해 SQL user에 주입하고, 앱
  소비용으로 Secret Manager에 저장합니다. 값은 output·로그로 노출하지
  않습니다.

### API: 수동 활성화
- `google_project_service`를 사용하지 않고 필요한 API(compute,
  artifactregistry, sqladmin, servicenetworking, container 등)를 수동
  활성화합니다. 목록은 `docs/TERRAFORM_DEV.md`에 유지합니다.

## 현재와 계획

| 항목 | 현재 (main) | 계획 |
|---|---|---|
| Terraform state | GCS remote backend | 환경별 backend/prefix 분리 유지 |
| CI 검증 | `lint` + Terraform plan OIDC/WIF + Claude review | apply 자동화 검토 |
| 환경 | dev 단일 | staging/prod 분리, `modules/` 추출 |
| 배포 | 수동 | GitHub Actions 기반 apply 파이프라인 검토 |

## 데이터 흐름 (앱 관점)

애플리케이션 데이터 흐름에서 이 인프라가 맡는 위치:

- **GCS (데이터 레이크):** YouTube raw, user raw, action log raw,
  persona raw, Airflow DAG/log, Feast registry/staging bucket.
- **Cloud SQL (PostgreSQL):** 운영성 데이터(페르소나, 가상 유저 상태)
  저장소. GKE 워크로드가 private IP로 접속.
- **Redis:** Feast Online Store. GKE 앱 pod가 private TLS endpoint로 접속하며
  AUTH token과 CA는 Secret Manager에서 가져옵니다(#129, apply 대기).
- **Artifact Registry:** 앱 컨테이너 이미지 저장.
- **BigQuery:** `autoresearch_dev_analytics`, `feast_offline_store`.
- **GKE/Airflow:** Airflow는 `airflow` namespace 경계와 namespace-scoped
  RBAC로 설치 경로를 제공하며, 팀원 로컬 접근은
  `docs/TEAM_OPERATIONS_RUNBOOK.md`를 따른다.

## 변경 영향 체크리스트

아키텍처에 영향을 주는 변경 시 확인합니다:

- [ ] 네트워크 경계(private/public, peering, firewall)가 바뀌는가
- [ ] 다른 리소스가 소비하는 output이 바뀌는가
- [ ] 앱 저장소(`SKYAHO/Autoresearch`) 또는 Airflow 저장소(`SKYAHO/Autoresearch-airflow`)의 배포·접속 설정에 영향이 있는가
- [ ] `docs/TERRAFORM_DEV.md`와 이 문서의 갱신이 필요한가
