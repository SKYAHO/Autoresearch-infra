# dev 환경 좌표 카탈로그 설계

> 이슈: #491
> 상태: 구현 전 설계
> 작성일: 2026-08-02

## 1. 목적과 범위

`SKYAHO/Autoresearch-infra`, `SKYAHO/Autoresearch`,
`SKYAHO/Autoresearch-airflow`가 소비하는 dev 환경의 프로젝트·리전·zone·네트워크·저장소
좌표를 한 정본에서 관리한다. 현재 dev 환경 하나를 다른 GCP 프로젝트 또는 리전으로
이전할 때, Terraform root·GitHub Actions·배포 매니페스트·운영 문서가 서로 다른 값을
가리키는 문제를 방지한다.

이번 범위는 세 저장소의 **dev 환경 단일 좌표**다. 카탈로그 형식은 후속 staging/prod
추가가 가능하도록 설계하지만, 다중 환경 동시 배포·승격 정책·prod 리소스 생성은 이번
작업에 포함하지 않는다.

## 2. 배경과 문제

2026-07 프로젝트 이전에서 다음과 같은 정본/사본 불일치가 실제로 발생했다.

- Terraform output과 배포 매니페스트의 `loadBalancerIP` 리터럴이 달라 내부 DNS 접속이
  실패했다.
- Secret Manager의 정본을 갱신해도 Kubernetes Secret 사본과 소비 워크로드가 갱신되지
  않아 이전 프로젝트의 OAuth 자격 증명을 계속 사용했다.
- Terraform backend bucket, admin root state prefix, GitHub Actions OIDC/WIF 좌표와
  운영 명령이 여러 파일에 흩어져 이전 순서와 검증 범위가 불명확했다.

프로젝트 ID와 리전은 GCP에서 안전하게 추론할 수 있는 값이 아니라 운영자가 의도적으로
선택해야 하는 입력이다. 반대로 프로젝트 번호, 기본 Compute Engine 서비스 계정, 현재
프로젝트 메타데이터는 GCP 조회로 파생할 수 있다. 두 종류를 구분하지 않으면 자동화가
잘못된 프로젝트를 대상으로 실행될 위험이 있다.

## 3. 설계 결정

### 3.1 환경 카탈로그를 비밀이 아닌 좌표의 정본으로 둔다

infra 저장소에 `config/environments/dev/environment.yaml`을 신설한다. 다음 값만 둔다.

- 환경 이름, GCP project ID, region, 기본 zone suffix와 필요 시 명시 zone 목록
- 이름 prefix, VPC·PSA·PSC·GKE secondary range 등 CIDR
- Artifact Registry, GKE cluster, namespace, BigQuery dataset, GCS bucket, Cloud DNS
  domain처럼 세 저장소가 공유하는 비밀이 아닌 논리 좌표
- Terraform state bucket 이름과 dev/admin 각 root의 state prefix

시크릿 값, OAuth client ID/secret, service account key, Terraform state, 실제 tfvars,
private IP 주소, 실행 중인 리소스의 가변 endpoint는 카탈로그에 넣지 않는다. endpoint와
예약 IP는 Terraform output 또는 GCP API 조회가 정본이다.

카탈로그에는 스키마 버전과 `environment: dev`를 포함한다. 검증 스크립트는 필수 키,
문자열 형식, CIDR 중복, `region`과 zone의 일치, resource-name 제약을 fail-closed로
검사한다.

### 3.2 Terraform 입력과 backend 초기화를 분리한다

Terraform backend 블록은 `var.*`, local, data source를 참조할 수 없다. 따라서
카탈로그를 직접 backend에 넣거나 backend bucket을 Terraform output으로 역참조하지
않는다.

`scripts/terraform-env` 래퍼를 두어 카탈로그에서 root별 backend 인수를 생성하고,
동일 카탈로그를 Terraform의 비밀 없는 var-file로 전달한다. 생성 backend 파일은
`generated/`에만 두고 `.gitignore`에 포함한다. CI와 로컬 모두 다음과 같이 같은
래퍼를 사용한다.

```text
scripts/terraform-env --environment dev --root terraform/envs/dev init
scripts/terraform-env --environment dev --root terraform/admin/autoresearch-k8s plan
```

각 root의 provider project/region/zone과 resource 이름은 카탈로그에서 전달된 변수와
locals만 사용한다. root 사이에 필요한 값은 리터럴 복제가 아니라 명시 output 또는
같은 카탈로그 키로 연결한다. state를 읽어야 하는 경우에는 래퍼가 동일 카탈로그의
backend 좌표를 사용해 `terraform_remote_state`를 초기화한다.

### 3.3 명시 입력과 GCP 파생값을 구분한다

다음은 카탈로그의 명시 입력으로 유지한다.

- project ID, region, zone 선택, CIDR, 이름 prefix, 환경 이름
- state bucket과 root state prefix
- 비용·가용성·용량 정책에 해당하는 machine type, node pool, 삭제 보호 설정

다음은 provider 인증 뒤 Terraform data source로 조회한다.

- project number와 project metadata
- 기본 Compute Engine service account 같은 Google 관리 식별자
- 예약 IP, Cloud SQL private IP, Redis discovery endpoint, GKE endpoint처럼
  Terraform이 생성하거나 GCP가 부여하는 결과값

region에서 임의의 사용 가능 zone을 자동 선택하지 않는다. 공급 가능 zone은 시간에 따라
달라질 수 있고, 선택 결과가 바뀌면 zonal resource 교체나 비용 변화를 유발한다. 기본
zone은 `region`과 suffix로 결정하거나 카탈로그에서 명시하고, 검증 단계에서 해당
region에 속하는지만 확인한다.

### 3.4 app·Airflow 소비자는 infra의 신뢰된 카탈로그만 읽는다

Autoresearch와 Autoresearch-airflow의 CI는 infra 저장소의 보호된 `main`에서
`config/environments/dev/environment.yaml`을 읽는다. PR 헤드나 사용자 입력으로
카탈로그 ref를 바꾸지 않는다. 파싱 전에 스키마 버전과 환경 이름을 검증한다.

각 저장소의 GitHub Environment에는 OIDC/WIF 인증에 필요한 최소 bootstrap anchor만
남긴다. 이는 GCP API 또는 카탈로그를 읽기 전에 인증에 필요하므로 다른 저장소의
카탈로그로 완전히 대체할 수 없다. workflow는 인증 직후 다음을 대조해 불일치하면
실패한다.

- 카탈로그의 project ID와 GitHub Environment의 인증 대상 project ID
- 카탈로그로 조립한 WIF provider/서비스 계정 프로젝트 번호와 실제 인증 주체
- 카탈로그의 Artifact Registry·GKE 좌표와 배포 대상

이 예외를 제외한 이미지 URI, GCS bucket, BigQuery dataset, cluster·namespace, 내부
domain은 카탈로그 또는 infra Terraform output에서만 조립한다. YAML 매니페스트의
프로젝트 ID·리전·IP 리터럴은 제거하고, Helm values·Kustomize·CI 환경 변수 중 하나의
명시된 렌더 경로로 주입한다.

### 3.5 이전은 값 변경이 아니라 승인된 전환 절차다

카탈로그에서 project ID 또는 region 한 줄을 변경해도 기존 리소스가 자동 이동하지
않는다. 이러한 변경은 새 프로젝트/리전에 리소스를 만들고, 데이터·이미지·시크릿
사본·소비자를 순서대로 전환하는 migration으로 취급한다.

1. 새 프로젝트 bootstrap과 API·quota·WIF를 준비하고, 새 카탈로그를 별도 PR에서
   정적 검증한다.
2. 새 backend와 dev root를 초기화해 plan을 검토한다. 기존 state와 프로젝트는 보존한다.
3. infra root를 적용한 뒤 이미지·데이터·운영자 주입 시크릿을 복사하고 값 대신 해시·
   프로젝트 번호 프리픽스·output 대조로 확인한다.
4. app·Airflow의 카탈로그 소비 CI를 새 좌표로 전환하고, 내부 DNS·GKE·GCS·BigQuery
   smoke test를 수행한다.
5. 소비자가 새 환경을 확인한 뒤에만 이전 프로젝트 정리 여부를 별도 승인으로 결정한다.

롤백은 이전 카탈로그 버전과 bootstrap anchor를 되돌린 뒤, 소비자 배포를 이전
프로젝트로 재전환하는 방식이다. 이전 state, 데이터, 시크릿 payload와 이미지가 남아
있을 때만 가능하므로 정리 작업은 migration PR의 범위 밖으로 분리한다.

## 4. 구현 작업 분해

변경은 구조 리팩터링과 실제 리소스 전환을 분리한다.

1. infra에 카탈로그 스키마·검증기·Terraform 래퍼·backend 생성 계약을 추가한다.
2. infra의 bootstrap, dev root, 모든 admin root에서 하드코딩 좌표를 카탈로그 입력과
   GCP data source로 치환한다. 리소스 주소와 이름은 이 단계에서 변경하지 않는다.
3. infra deploy manifest와 GitHub Actions에서 동일 카탈로그를 소비하고, 좌표 불일치
   검사를 추가한다.
4. app 저장소와 Airflow 저장소의 workflow·배포 설정·문서를 각각 별도 이슈/PR로
   전환한다. 세 저장소는 독립 리뷰·병합을 유지한다.
5. 실제 새 프로젝트 또는 리전 전환은 별도 migration issue와 승인된 apply 창에서만
   수행한다.

## 5. 보안과 운영 통제

- 카탈로그 PR은 `terraform`, `gcp`, `security`, `ci-cd` 관점의 리뷰를 받는다.
- CI는 최소 권한 OIDC/WIF를 유지한다. project-wide Owner/Editor 권한이나 SA key를
  추가하지 않는다.
- 외부 URL로 카탈로그를 내려받지 않고 GitHub Actions checkout으로 보호된 infra
  repository의 `main`만 읽는다.
- workflow shell에는 PR 제목·comment·카탈로그의 임의 문자열을 그대로 보간하지 않고,
  허용된 key와 형식 검증을 거친 값만 전달한다.
- public IP, LoadBalancer, broad egress, DNS 외부 노출은 이 작업으로 추가하지 않는다.
- CI/PR 로그에는 plan 원문, secret, endpoint의 민감 값, state 내용을 게시하지 않는다.

## 6. 검증 기준

- 카탈로그 스키마 검증과 Terraform wrapper 단위 테스트가 실패 입력을 차단한다.
- 모든 infra root는 카탈로그 기반으로 `fmt`, `init -backend=false`, `validate`를
  통과한다.
- app·Airflow workflow는 카탈로그 project ID와 bootstrap anchor가 다를 때 배포 전에
  실패한다는 음성 테스트를 가진다.
- 기존 dev 카탈로그에서 plan이 의도하지 않은 destroy/replace를 만들지 않음을 확인한다.
- migration rehearsal은 실제 apply 없이 새 backend 초기화·인증·좌표 대조·읽기 전용
  API 조회까지 수행한다.
- 각 PR에는 IAM, 비용, 리전, 롤백, 카탈로그 버전 영향과 실행한 검증을 기록한다.

## 7. 완료 정의

- 세 저장소의 dev 좌표 정본, 파생값, bootstrap anchor, 시크릿의 소유 경계가 문서화된다.
- 비밀이 아닌 dev 좌표는 하나의 카탈로그에서만 수정하며, 소비자는 이를 검증 후 사용한다.
- 프로젝트/리전 변경이 실제 리소스 이전을 자동 실행하지 않고, 별도 승인된 migration
  절차와 롤백 경로를 요구한다.
- 실제 tfvars, state, secret 값, service account key는 어느 저장소에도 추가되지 않는다.
