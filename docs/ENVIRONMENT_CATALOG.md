# dev 환경 좌표 카탈로그

`config/environments/dev/environment.yaml`은 AutoResearch dev 환경의 비밀이 아닌 프로젝트·리전·zone·GKE·CIDR·Terraform state 좌표 정본입니다.

## 사용 방법

```bash
scripts/terraform-env --environment dev --root terraform/envs/dev init -backend=false -input=false
scripts/terraform-env --environment dev --root terraform/envs/dev validate
scripts/terraform-env --environment dev --root terraform/envs/dev init -reconfigure
```

래퍼는 카탈로그를 검증하고 root별 gitignored 입력·backend 파일을 생성합니다. bootstrap root는 state bucket 생성 전 실행되므로 backend 없이 카탈로그 var-file만 사용합니다.

다른 저장소의 CI는 검증된 필드만 읽을 수 있습니다.

```bash
ruby scripts/environment_catalog.rb \
  --catalog config/environments/dev/environment.yaml \
  --field gcp.project_id
```

필드 경로가 없거나 카탈로그가 유효하지 않으면 값을 출력하지 않고 실패합니다.

## GitHub 변수와의 관계

카탈로그가 생성하는 `.environment.auto.tfvars.json`은 Terraform 변수 우선순위상
`TF_VAR_` 환경변수보다 **강합니다**. 따라서 카탈로그가 공급하는 좌표를 workflow의
`TF_VAR_`로 중복 정의하면, GitHub 변수를 바꿔도 조용히 무시되어 "바꿨는데 반영이
안 되는" 상태가 됩니다. 이를 막기 위해 카탈로그 소유 좌표(project/region/zone,
이름 prefix, GKE cluster, 각종 CIDR)의 `TF_VAR_` 선언은 workflow에서 제거했습니다.

workflow에 남아 있는 `TF_VAR_`는 카탈로그가 공급하지 않는 값뿐입니다 —
`labels`, `master_authorized_networks`, 각 allowlist 이메일(secret), ArgoCD·Agent
Orchestration 배포 입력 등. 새 좌표를 카탈로그에 추가할 때는 대응하는 `TF_VAR_`
선언도 함께 제거해야 이중 정본이 생기지 않습니다.

`GCP_PROJECT_ID`만은 bootstrap anchor로 남아 있으며(WIF 인증은 카탈로그를 읽기
전에 필요), 각 workflow가 인증 **전에** 카탈로그와 대조해 불일치 시 실패합니다.
`PLAN_PREFIX`도 카탈로그 `state.bucket`에서 파생해 하드코딩을 없앴습니다.

## 정본 경계

- 카탈로그: project ID, region, zone, 이름 prefix, GKE cluster, CIDR, state bucket/prefix
- GCP/Terraform 조회: project number, 예약 IP, Cloud SQL private IP, Redis/GKE endpoint
- Secret Manager/GitHub Secrets: 비밀번호, OAuth, API key, service account key
- GitHub Environment bootstrap anchor: WIF provider와 CI/apply 서비스 계정. 인증 전에 필요하므로 별도 유지하며 후속 CI에서 project ID와 fail-closed 대조한다.

## 세 저장소 소비자 계약

`SKYAHO/Autoresearch`와 `SKYAHO/Autoresearch-airflow`는 별도 이슈·브랜치·PR에서 보호된 infra `main`의 카탈로그를 checkout해 사용한다. project ID, Artifact Registry, GCS, BigQuery, GKE 좌표가 bootstrap anchor와 다르면 배포 전에 실패해야 하며 카탈로그 ref는 PR 입력으로 받지 않는다.

## 이전과 롤백

카탈로그 값 변경은 리소스 이동이 아니다. 새 프로젝트 bootstrap → state 초기화·plan 검토 → infra 적용 → 이미지·데이터·시크릿 복사 → app → Airflow → e2e 검증 순서로 별도 migration issue에서 실행한다. apply, DNS 전환, 이전 프로젝트 삭제는 명시 승인이 필요하다. 롤백은 이전 카탈로그·bootstrap anchor·소비자 배포를 되돌리며, 이전 state·데이터·시크릿·이미지를 삭제하기 전에만 가능하다.
