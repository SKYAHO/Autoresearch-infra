# Feast dev/prod 런타임 IAM 경계 설계

> 관련 이슈: #424
> 상태: 구현 승인됨

## 목적

단일 GCP 프로젝트에서 실행되는 Feast apply의 dev와 prod 경로를 독립된 GCS
버킷, GCP 서비스 계정, Kubernetes namespace/KSA, GitHub Actions OIDC 신뢰
관계로 분리한다. dev GitHub Environment에서 시작한 Job은 dev BigQuery
dataset과 dev Feast GCS 버킷만 사용할 수 있고, prod Redis 또는 prod Feast
리소스에 접근할 수 없어야 한다.

Terraform apply 권한과 `terraform/envs` root/state 분리는 이번 변경의 범위가
아니다. 현재 단일 프로젝트·단일 dev root 운영은 유지한다.

## 현재 상태와 문제

- `google_service_account.feast_apply` 하나가 prod/dev dataset 메타데이터,
  공용 registry/staging 버킷, Redis 연결과 TLS CA secret 접근을 함께 가진다.
- registry와 staging은 prod 루트와 `dev/` prefix로만 구분된다. bucket-level
  `objectAdmin`은 prefix 경계가 아니다.
- 기존 GitHub WIF provider는 repository와 workflow ref를 제한하지만 GitHub
  Environment claim을 신뢰 관계에 사용하지 않는다.
- `feast-apply` Kubernetes namespace 하나에서 GHA와 Pod가 동일 GSA를
  사용한다. 환경별 GSA를 도입하면 namespace도 환경별로 나눠 Job 생성 권한이
  다른 환경 KSA를 지정하는 우회 경로를 없애야 한다.

## 결정

### 환경별 GCS 버킷

기존 registry와 staging 버킷은 prod 버킷으로 그대로 유지한다. 기존 prod
registry 객체를 옮기거나 버킷을 교체하지 않는다.

| 용도 | prod | dev |
| --- | --- | --- |
| Registry | `gs://<project>-feast-registry/registry.db` | `gs://<project>-feast-registry-dev/registry.db` |
| Staging | `gs://<project>-feast-staging/` | `gs://<project>-feast-staging-dev/` |

새 dev 버킷은 uniform bucket-level access와 public access prevention을
기존 prod 버킷과 동일하게 적용한다. prod 경로는 불변이므로 rollback은
애플리케이션 GitHub Environment를 기존 prod 좌표로 되돌리는 것이며,
registry 객체 이관은 필요 없다.

### 환경별 Feast apply ID 및 Kubernetes 경계

`autoresearch-dev-feast-apply-dev`와
`autoresearch-dev-feast-apply-prod` GSA를 생성한다. 이번 범위에서는 각
환경의 GHA runner와 해당 GKE Job Pod가 같은 환경 GSA를 공유한다. 이 SA는
다른 환경의 권한을 갖지 않으므로 dev→prod 권한 전이는 발생하지 않는다.

각 환경은 별도의 namespace와 KSA를 사용한다.

| 환경 | namespace / KSA | GSA | 접근 권한 |
| --- | --- | --- | --- |
| dev | `feast-apply-dev` / `feast-apply` | `…-feast-apply-dev` | dev registry/staging, dev dataset metadata, code artifact 읽기 |
| prod | `feast-apply-prod` / `feast-apply` | `…-feast-apply-prod` | prod registry/staging, prod dataset metadata, code artifact 읽기, Redis, Redis CA secret |

namespace별 RoleBinding은 해당 환경 GSA만 Job을 create/get/list/watch/delete
할 수 있게 한다. dev NetworkPolicy에는 Redis PSC 포트를 추가하지 않고,
prod NetworkPolicy에만 허용한다.

GHA runner와 Pod runtime ID를 네 개 SA로 추가 분리하는 하드닝은 후속 과제로
남긴다. 현재 변경은 GHA가 해당 환경의 데이터 권한을 직접 갖는 구조를
유지하지만, 환경 간 권한 분리는 강제한다.

### GitHub Environment를 WIF 신뢰 경계로 연결

기존 `github` WIF provider는 Terraform 및 다른 배포 경로가 사용하므로
변경하지 않는다. 같은 WIF pool에 `github-feast-dev`, `github-feast-prod`
provider를 별도 생성한다.

각 provider는 다음을 함께 제한한다.

- GitHub OIDC `repository`가 `SKYAHO/Autoresearch`이다.
- OIDC `environment`가 각각 `dev` 또는 `prod`이다.
- GSA의 Workload Identity User binding은
  `feast-apply.yml@refs/heads/main` workflow ref만 허용한다.

앱 저장소 workflow의 Feast apply Job은 반드시
`environment: ${{ inputs.environment || 'prod' }}`를 선언해야 한다. 각 GitHub
Environment에는 해당 provider resource name, environment별 Feast apply GSA
email, registry/staging/dataset 좌표를 변수 또는 secret으로 등록한다. prod
Environment에는 required reviewer와 허용 브랜치 정책을 유지한다.

이 저장소는 WIF provider/GSA/output/운영 문서를 소유한다. 앱 저장소의
workflow 파일과 GitHub Environment 변수/secret 실제 등록은 앱 저장소 변경 및
Terraform apply 이후의 운영 단계로 문서화한다.

## 최소 권한 행렬

| 주체 | prod BQ | dev BQ | prod GCS | dev GCS | Redis / CA |
| --- | --- | --- | --- | --- | --- |
| feast-apply-dev | 없음 | metadataViewer | 없음 | objectAdmin + bucket metadata read | 없음 |
| feast-apply-prod | metadataViewer | 없음 | objectAdmin + bucket metadata read | 없음 | dbConnectionUser + secretAccessor |

`roles/container.clusterViewer`는 GKE endpoint와 cluster metadata 확인에만
필요하므로 두 Feast apply GSA에 공통으로 부여한다. 실제 Job 권한은
환경별 namespace RoleBinding에서 제한한다.

## 비범위와 후속 과제

- 일반 GKE app, Airflow batch, raw data lake의 환경 분리는 이번 이슈에서
  변경하지 않는다.
- Terraform env root/state 및 apply SA 분리는 후속 이슈에서 설계한다.
- GHA runner와 GKE runtime을 별도 SA로 나누는 더 강한 배포 경계는 후속
  하드닝 과제다.

## 검증 및 롤백

- Terraform format/validate와 `git diff --check`를 실행한다.
- IAM diff에서 dev GSA의 prod dataset/bucket/Redis/CA binding 부재와 prod
  GSA의 dev dataset/bucket binding 부재를 검토한다.
- apply 후 dev Environment Job의 dev WIF provider 인증 성공과 prod provider
  또는 prod GSA 가장 실패를 확인한다. prod에서도 역방향 실패를 확인한다.
- dev Pod의 Redis 및 CA secret 접근은 403이어야 하며 prod Pod의 Redis 연결은
  성공해야 한다.
- rollback은 app GitHub Environment의 provider/SA/좌표를 기존 공용 값으로
  되돌린 뒤 새 dev IAM binding과 새 dev 버킷을 별도 승인된 Terraform apply로
  제거한다. 기존 prod 버킷과 registry 객체는 변경하지 않는다.
