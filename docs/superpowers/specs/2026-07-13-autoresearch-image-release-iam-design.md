# Autoresearch 앱 이미지 release IAM 설계

> 작성: 2026-07-13
> 상태: 구현 완료 (apply 전)
> 관련: Issue #157, Autoresearch PR #130, 기존 Airflow GAR push #121

## 목적

`SKYAHO/Autoresearch`의 애플리케이션 이미지를 GitHub Actions에서 빌드해
기존 dev Artifact Registry에 push할 수 있도록 keyless 인증 경로를 만든다.
Airflow 배포 신원과 앱 배포 신원을 분리하고, 저장소·대상 GAR 범위를 모두
최소화한다.

## 범위

포함:

- Autoresearch 저장소 전용 Google service account
- GitHub OIDC/WIF를 통한 해당 SA 가장
- 기존 `autoresearch-dev-docker` repository 쓰기 권한
- bootstrap WIF 허용 저장소 운영 절차와 dev output

제외:

- Autoresearch 저장소의 이미지 build/release workflow 구현
- 새 Artifact Registry 생성 또는 이미지 보존 정책 변경
- Terraform apply, GitHub variable/secret 등록
- Airflow DAG와 KubernetesPodOperator 변경

## 현재 상태와 문제

Autoresearch-airflow에는 #121에서 전용 `gar_pusher` SA가 마련됐지만,
Autoresearch 앱 저장소에는 WIF로 가장할 수 있는 배포 신원이 없다. 기존 SA에
Autoresearch principalSet을 추가하면 두 저장소가 하나의 배포 신원을 공유해
감사와 롤백 경계가 흐려진다.

## 결정

저장소별 service account를 유지한다.

```text
SKYAHO/Autoresearch GitHub OIDC token
  -> WIF provider attribute_condition(허용 저장소 목록)
  -> application_pusher SA principalSet(Autoresearch만)
  -> autoresearch-dev-docker repository writer
```

| 항목 | 결정 | 근거 |
|---|---|---|
| SA | `autoresearch-dev-app-pusher` 신규 | Airflow 배포 신원과 감사·폐기 경계 분리 |
| WIF 주체 | `attribute.repository/SKYAHO/Autoresearch` | 조직/브랜치 전체가 아닌 저장소 단위 제한 |
| GAR 권한 | 기존 repository의 `roles/artifactregistry.writer` | 프로젝트 수준 권한 불필요 |
| 인증 | GitHub OIDC/WIF | 장기 service account key 제거 |
| output | `github_actions_app_pusher_service_account_email` | 후속 Autoresearch workflow의 `GAR_PUSHER_SA` 입력 |

provider의 저장소 허용 조건과 SA의 principalSet 바인딩은 서로 다른 경계다.
Autoresearch가 provider에서 토큰을 받아도 `terraform-ci`나 Airflow pusher SA는
가장할 수 없다.

## Terraform 변경

dev root에 다음 세 리소스를 추가한다.

1. `google_service_account.application_pusher`
2. `google_service_account_iam_member.application_pusher_wi`
3. `google_artifact_registry_repository_iam_member.application_pusher_ar_writer`

기존 Airflow 리소스 이름과 바인딩은 수정하지 않는다. bootstrap root의 실제
허용 목록은 비커밋 로컬 `terraform.tfvars`로 운영하므로 코드 default를 넓히지
않고 runbook의 필수 운영 값만 세 저장소로 갱신한다.

## 적용 순서

1. bootstrap 로컬 tfvars의 `allowed_github_repositories`에
   `SKYAHO/Autoresearch`가 포함됐는지 확인한다.
2. bootstrap plan/apply로 WIF provider 조건을 갱신한다.
3. dev root plan에서 `3 to add, 0 to change, 0 to destroy`를 확인하고 apply한다.
4. dev output을 회수해 Autoresearch 저장소의 `GAR_PUSHER_SA`에 등록한다.
5. 후속 release workflow에서 immutable tag와 digest push를 검증한다.

이번 구현 PR에서는 2~3단계의 apply와 4~5단계 외부 설정을 수행하지 않는다.

## 영향

- IAM: 앱 저장소 전용 SA 가장과 기존 GAR repository writer가 추가된다.
- 비용: service account와 IAM binding 자체의 직접 비용은 없다. 이미지 저장·전송
  비용은 후속 release에서 발생한다.
- 리전: 새 리소스 저장 위치를 만들지 않고 기존 `asia-northeast3` GAR를 사용한다.
- 기존 동작: Airflow pusher, Cloud Build, GKE reader 권한은 변경하지 않는다.

## 롤백

1. Autoresearch release workflow를 비활성화한다.
2. dev root에서 application pusher의 GAR IAM, WI IAM, SA를 제거한다.
3. bootstrap 허용 목록에서 `SKYAHO/Autoresearch`를 제거해 적용한다.

순서를 반대로 하면 동작 중인 workflow가 부분 인증 실패를 일으킬 수 있다.

## 완료 기준

- fmt, init(`-backend=false`), validate, `git diff --check` 통과
- Terraform diff가 앱 전용 리소스 3개 추가이고 기존 Airflow 리소스 변경이 없음
- 문서에 bootstrap 적용 순서, 비용·리전·IAM·롤백 영향이 기록됨
- 후속 Autoresearch release가 사용할 output이 노출됨
