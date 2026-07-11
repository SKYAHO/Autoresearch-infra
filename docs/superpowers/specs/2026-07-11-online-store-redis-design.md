# Online Store Redis 설계

> Issue: #129 | 작성일: 2026-07-11

## 목적

Feast Feature Store의 Online Store로 사용할 Redis를 dev GCP 프로젝트에
Terraform으로 생성한다. Redis는 기존 dev VPC에만 연결하고, GKE의
`autoresearch` namespace 워크로드만 필요한 egress 경로를 사용하도록
Kubernetes NetworkPolicy를 별도 Terraform state에서 관리한다.

## 현재 상태

- dev GCP 리소스는 `terraform/envs/dev` GCS state에서 관리한다.
- custom VPC와 Private Service Access 연결 및 `192.168.0.0/20` 예약 대역은
  Cloud SQL을 위해 이미 구성되어 있다.
- GKE는 private node와 Calico NetworkPolicy enforcement를 사용한다.
- app GSA와 Workload Identity IAM member는 있지만 `autoresearch` namespace,
  KSA, NetworkPolicy를 소유하는 Kubernetes Terraform root는 없다.
- 앱 저장소의 Feast 0.64.0 설정은 Redis Online Store를 사용하며, 비밀번호와
  SSL connection string을 지원한다. 실제 앱 설정 변경은 앱 저장소 범위다.

## 결정

### 1. GCP Memorystore for Redis 단일 인스턴스

`google_redis_instance`를 사용한다. dev 최소 비용 기준으로 기본값은 Basic
tier, 1 GiB, Redis 7.2다. Cluster나 Standard HA는 현재 dev 트래픽과 학습
환경 목적에 비해 비용이 크므로 사용하지 않는다.

리소스 이름은 공통 prefix를 사용한 `autoresearch-dev-redis`로 한다.

### 2. 기존 Private Service Access 재사용

Redis는 `PRIVATE_SERVICE_ACCESS` 모드로 기존 dev VPC와 기존
`google_service_networking_connection.private_sql` 연결을 재사용한다. 별도
peering과 별도 주소 대역을 추가하지 않아 IP와 state 변경 범위를 줄인다.

기존 Terraform resource address는 state 안정성을 위해 유지한다. 다만
`private_services_cidr` 설명과 운영 문서는 Cloud SQL 전용이 아니라 공유 private
services 대역임을 명확히 한다.

### 3. AUTH와 TLS 활성화

private VPC 경계에만 의존하지 않고 `auth_enabled=true`와
`transit_encryption_mode=SERVER_AUTHENTICATION`을 사용한다. provider가 생성한
AUTH 문자열과 서버 CA bundle은 각각 Secret Manager secret version에 저장한다.

- AUTH 문자열과 CA 본문은 output하지 않는다. CA rotation 기간에는 provider가
  반환하는 모든 인증서를 하나의 PEM bundle로 저장한다.
- app GSA에는 두 secret 리소스에 대한 `roles/secretmanager.secretAccessor`만
  부여한다.
- secret payload는 Terraform state에 들어가므로 기존 GCS backend IAM으로
  보호한다.
- host와 port, secret ID만 output한다.

TLS 사용 시 Redis endpoint port는 provider가 반환하는 값을 사용한다. 현재
Memorystore TLS endpoint는 6378이지만 dev root에서 숫자를 하드코딩하지 않는다.

### 4. Kubernetes 경계는 별도 admin state

`terraform/admin/autoresearch-k8s` root를 추가한다. 이 root는 다음을 관리한다.

- `autoresearch` namespace
- app GSA annotation이 붙은 `autoresearch-app` KSA
- namespace 전체 pod에 적용되는 egress NetworkPolicy

egress 정책은 Redis만 추가하고 기존 필수 통신을 끊지 않도록 다음을 함께
허용한다.

- 같은 namespace pod 간 통신
- kube-dns UDP/TCP 53
- GKE services CIDR의 DNS VIP
- private services CIDR의 Cloud SQL 5432와 Redis TLS port 6378
- GKE metadata server의 Workload Identity TCP 80, 987, 988
- 외부 API와 Google APIs의 HTTPS 443

NetworkPolicy root의 `redis_port` 기본값은 6378로 두되 dev root output과 실제
plan/apply 전에 일치 여부를 확인한다. Kubernetes API 접근과 state 경계를 dev
root와 분리하는 기존 admin root 패턴을 따른다.

namespace가 live cluster에 이미 존재하면 최초 apply 전에 import한다. 존재하지
않으면 Terraform이 생성한다. apply는 운영자 네트워크와 명시적 사용자 승인 후에만
수행한다.

### 5. 앱 설정은 후속 작업

이 저장소는 Redis endpoint와 Secret Manager secret을 제공한다. Feast
`feature_store.yaml`의 password/SSL connection string 구성, Secret을 pod에
주입하는 배포 설정과 smoke test client는 `SKYAHO/Autoresearch` 후속 작업으로
분리한다.

## 보안·비용·롤백

- public endpoint와 `0.0.0.0/0` Redis ingress를 만들지 않는다.
- Redis 접근 IAM은 필요하지 않으며 AUTH secret 접근만 app GSA에 resource-level로
  부여한다.
- Basic 1 GiB는 HA가 없으므로 장애·maintenance 중 Online Store가 중단될 수 있다.
- dev에서는 `redis_deletion_protection=false`를 기본값으로 두며 PR과 plan에서
  명시한다.
- 롤백 시 앱의 Redis 사용을 먼저 중지한 뒤 admin NetworkPolicy 규칙과 Redis
  리소스를 순서대로 제거한다. 실제 삭제는 별도 승인과 plan 확인 후 수행한다.

## 검증

- dev root와 admin root 각각 `fmt -check`, `init -backend=false`, `validate`
- 실제 인증 환경에서 dev plan의 add/change/delete/replace 확인
- admin plan에서 namespace 존재 시 import 필요 여부 확인
- apply 후 GKE pod에서 TLS CA와 AUTH를 사용한 `PING`/`PONG` smoke test
- public IP 부재, Secret/IAM 최소 범위, 예상 비용 확인
