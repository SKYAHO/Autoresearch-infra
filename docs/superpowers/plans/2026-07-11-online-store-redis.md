# Online Store Redis 구현 계획

> Issue: #129 | 설계: `../specs/2026-07-11-online-store-redis-design.md`

## 작업 순서

1. `terraform/envs/dev`에 Redis 변수, local, API 목록과 `redis.tf`를 추가한다.
2. Redis AUTH 문자열과 TLS CA용 Secret Manager secret/version 및 app GSA
   resource-level IAM을 추가한다.
3. host, port, secret ID output과 `terraform.tfvars.example`을 갱신한다.
4. `terraform/admin/autoresearch-k8s` 별도 root에 namespace, KSA, egress
   NetworkPolicy를 추가한다.
5. Terraform 구조·API·비용·적용 순서·롤백을 README와 운영 문서에 반영한다.
6. dev/admin root의 fmt와 validate, `git diff --check`, 보안 diff를 검증한다.

## 검증 체크리스트

- [x] Redis가 Basic 1 GiB, Redis 7.2, 서울 리전에 생성되도록 정의됨
- [x] 기존 dev VPC와 Private Service Access만 사용함
- [x] AUTH와 TLS가 활성화됨
- [x] AUTH/CA payload가 output과 문서에 노출되지 않음
- [x] app GSA가 Redis secret 두 개에만 accessor를 가짐
- [x] NetworkPolicy가 Redis와 기존 필수 egress를 최소 포트로 허용함
- [x] dev root `fmt -check`와 `validate` 통과
- [x] autoresearch-k8s root `fmt -check`와 `validate` 통과
- [x] `git diff --check` 통과
- [x] state, tfvars 실값, key, secret이 diff에 없음
- [x] 실제 `apply`/`destroy`를 수행하지 않음

실제 dev plan은 로컬 `terraform/envs/dev/terraform.tfvars`가 없어 실행하지
않았다. PR의 OIDC/WIF Terraform Plan check에서 remote state와 repository
variables를 사용해 add/change/delete/replace를 확인한다.
