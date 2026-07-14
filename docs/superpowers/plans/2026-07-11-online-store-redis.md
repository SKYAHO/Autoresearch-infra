# Online Store Redis Cluster 구현 계획

> Issue: #129 | 설계: `../specs/2026-07-11-online-store-redis-design.md`

## 작업 순서

1. 기존 Basic 단일 Redis 변수·resource·AUTH secret을 제거한다.
2. dev root에 Redis Cluster 전용 PSC subnet과 Service Connection Policy를 추가한다.
3. `google_redis_cluster`를 nano primary shard 2개, replica 0개, GKE와 같은
   single zone, IAM 인증/TLS로 정의한다.
4. app GSA에 cluster 한정 `roles/redis.dbConnectionUser` 조건부 binding을 추가하고
   managed CA bundle만 Secret Manager에 저장한다.
5. discovery endpoint/port, PSC CIDR, CA secret ID output과 tfvars example을 갱신한다.
6. `terraform/admin/autoresearch-k8s` NetworkPolicy를 Cloud SQL PSA와 Redis PSC
   egress로 분리하고 TCP 6379 및 11000-13047을 허용한다.
7. Redis Cluster 구조·API·비용·hash tag/MGET 검증·장애 복구·롤백을 README와
   운영 문서에 반영한다.
8. dev/admin root의 fmt와 validate, `git diff --check`, 보안 diff를 검증한다.

## 검증 체크리스트

- [x] `google_redis_instance`와 static AUTH secret 참조가 제거됨
- [x] `google_redis_cluster`가 서울 리전 nano primary shard 2개, replica 0개와
  `SINGLE_ZONE`으로 정의됨
- [x] 전용 PSC `/29` subnet과 `gcp-memorystore-redis` policy가 정의됨
- [x] IAM 인증과 TLS가 활성화되고 app GSA 연결 권한이 cluster 하나로 제한됨
- [x] IAM token은 state/output/Secret Manager에 저장되지 않고 CA bundle만 저장됨
- [x] NetworkPolicy가 Redis PSC 6379와 node port 11000-13047을 허용함
- [x] Cloud SQL PSA 5432와 Redis PSC egress가 분리됨
- [x] hash tag, `MGET`, `CROSSSLOT` 검증 절차와 앱 저장소 책임이 문서화됨
- [x] dev root `fmt -check`와 `validate` 통과
- [x] autoresearch-k8s root `fmt -check`와 `validate` 통과
- [x] `git diff --check` 통과
- [x] state, tfvars 실값, key, token, secret이 diff에 없음
- [x] 실제 `apply`/`destroy`를 수행하지 않음

2026-07-13에 원격 state를 변경하지 않는 `-refresh=false` targeted plan으로 Redis
범위를 확인한 결과 `7 add / 0 change / 0 destroy`였고, admin root 전체 plan은
`3 add / 0 change / 0 destroy`였다. dev full plan은 현재
`redis.googleapis.com`과 `serviceconsumermanagement.googleapis.com`이 비활성이고
로컬 실값 tfvars가 없으므로 PR의 OIDC/WIF Terraform Plan check에서 다시 확인한다.
기존 단일 Redis 구현은 apply되지 않았으므로 state migration은 현재 범위에
포함하지 않는다.
