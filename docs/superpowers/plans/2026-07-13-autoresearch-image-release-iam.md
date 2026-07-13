# Autoresearch 앱 이미지 release IAM 구현 계획

> 설계: `docs/superpowers/specs/2026-07-13-autoresearch-image-release-iam-design.md`
> Issue: #157

## 1. 작업 경계 확인

1. root와 `Autoresearch-infra`의 AGENTS 지침을 확인한다.
2. `main`과 `origin/main`의 동기화 및 clean 상태를 확인한다.
3. 이슈 #157에서 `feat/157-autoresearch-gar-pusher` 브랜치를 생성한다.

## 2. Terraform 구현

1. `terraform/envs/dev/github_actions.tf`에 앱 전용 SA를 추가한다.
2. `SKYAHO/Autoresearch` principalSet에만 WI 가장 권한을 부여한다.
3. 기존 dev GAR repository에만 writer 권한을 부여한다.
4. `outputs.tf`에 후속 release workflow용 SA email output을 추가한다.
5. 기존 Airflow pusher 리소스와 이름은 변경하지 않는다.

## 3. 운영 문서 갱신

1. `TERRAFORM_BOOTSTRAP.md`에 세 저장소 허용 목록과 적용 순서를 기록한다.
2. `TERRAFORM_DEV.md`에 저장소별 SA/출력/IAM 경계를 기록한다.
3. `INFRASTRUCTURE_SUMMARY.md`에 OIDC/WIF 이미지 push 흐름을 반영한다.
4. `CHANGE_HISTORY.md`에 비용·리전·롤백을 포함한 변경 이력을 남긴다.

## 4. 검증

1. `terraform -chdir=terraform/envs/dev fmt -check -recursive`
2. `terraform -chdir=terraform/envs/dev init -backend=false`
3. `terraform -chdir=terraform/envs/dev validate`
4. 자격 증명과 실제 tfvars가 있을 때만 plan을 실행하고, 없으면 PR CI plan으로
   `3 to add, 0 to change, 0 to destroy`를 확인한다.
5. `git diff --check`와 전체 diff로 secret/state/tfvars 및 기존 Airflow 변경이
   없는지 확인한다.

## 5. 전달

1. 변경 파일만 명시적으로 stage하고 단일 논리 커밋을 만든다.
2. 원격 브랜치에 push하고 Draft PR을 생성한다.
3. PR에 IAM 최소 권한, 비용 없음, 기존 서울 리전 사용, 롤백 순서와
   Terraform apply 미실행을 명시한다.
4. merge와 사용자 승인 후 bootstrap → dev root 순서로 별도 apply한다.
