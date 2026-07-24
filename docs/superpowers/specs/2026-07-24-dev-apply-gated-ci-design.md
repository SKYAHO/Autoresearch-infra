# dev root 승인 게이트 CI apply 설계 (#341)

## 배경·목적

admin root 8개는 admin-apply(#307/#312)로 코드-라이브 정합이 강제되지만 **dev
root(`terraform/envs/dev`)만 로컬 수동 apply에 의존**한다. 실증(#306): #300/#301·
#297/#299가 머지 후 며칠 미적용되어 drift 알림이 매일 발화했고 로컬 수동 apply로
해소했다. dev root apply를 승인 게이트 CI로 이관해 "머지≠적용" 갭을 닫는다.

## 결정 1 — admin-apply 편입이 아니라 별도 workflow

`admin-apply.yml`의 `ROOTS`에 dev root를 추가하지 않고 **`dev-apply.yml`을 신설**한다.

- dev root apply SA는 프로젝트 IAM·SA까지 관리해(아래 role 열거) admin-apply SA
  (`container.admin`+`compute.viewer`)와 권한 격차가 크다. 같은 workflow/SA에 섞으면
  admin root 일상 apply까지 최강 권한으로 돈다.
- 분리 시 최강 SA의 사용 경로가 **dev-apply.yml@main 단일 경로**로 고정된다
  (#314에서 gke-team-access를 제외한 것과 같은 원리 — 단 dev root는 escalation을
  감수하고 게이트로 통제하는 쪽을 택한다. 차이: gke-team-access는 사람 IAM이라 변경
  빈도가 낮아 로컬 break-glass로 충분하지만, dev root는 변경 빈도가 높아 게이트
  CI의 정합 강제 이득이 크다).

## 결정 2 — apply SA 권한: editor가 아니라 role 열거

리소스 타입 전수 스캔(`grep -rhoE '^resource "[a-z0-9_]+"'`) 기준 19개 role을
열거한다. owner/editor 단일 부여보다 크기가 명시돼 리뷰·감사 대상이 된다.

| Role | 근거 리소스 |
| --- | --- |
| compute.networkAdmin | network/subnetwork/router/NAT/route/firewall/address/global_address |
| compute.instanceAdmin.v1 | bastion `google_compute_instance` |
| compute.viewer | GKE data source의 IGM 조회(#310 실증) |
| container.clusterAdmin | cluster/node_pool — dev root엔 K8s object가 없어 `container.admin` 불요 |
| iam.serviceAccountAdmin | `google_service_account` 15 + SA IAM 14 |
| iam.serviceAccountUser | bastion·Cloud Run에 SA attach(actAs) |
| resourcemanager.projectIamAdmin | `google_project_iam_member` 21 |
| iam.roleAdmin | `google_project_iam_custom_role` |
| storage.admin | bucket 8 + bucket IAM 33 + tfstate 읽기/쓰기 |
| bigquery.admin | dataset/table/connection/dataset IAM |
| cloudsql.admin | instance/database/user |
| redis.admin | `google_redis_cluster` |
| secretmanager.admin | secret/version/secret IAM |
| artifactregistry.admin | repository + repo IAM |
| dns.admin | managed_zone/record_set |
| cloudkms.admin | key_ring/crypto_key/key IAM |
| run.admin | Cloud Run v2 service + service IAM |
| servicenetworking.networksAdmin | PSA peering(`google_service_networking_connection`) |
| networkconnectivity.consumerNetworkAdmin | Redis PSC `service_connection_policy` |

부족분은 admin-apply 전례(#310 compute.viewer)처럼 **403-driven으로 실측 보완**하고
spec에 반영한다.

## 결정 3 — 보안 통제(3중) + access-affecting 변경의 사람 판단

apply SA는 projectIamAdmin 포함 사실상 프로젝트 최강 자격증명이다. 통제:

1. 전용 SA(`autoresearch-dev-dev-apply`) — 다른 용도 사용 금지
2. WIF `dev-apply.yml@refs/heads/main` workflow_ref 제한 — 임의 브랜치/워크플로우 가장 차단
3. GitHub Environment `dev-apply` required reviewer 승인 게이트

추가로 #306 교훈(요약의 "in-place"가 MAN 접근 회수를 숨김): 승인자는 plan 요약
(리소스 주소·action)에서 `google_container_cluster`·IAM 계열 in-place가 보이면
Actions 로그의 상세 diff를 확인 후 승인한다. **drift 자동 해소와 접근 변경의 사람
판단을 게이트 한 곳에서 동시에 충족**한다.

## 결정 4 — 변수 단일 원천·로컬 break-glass 격하

- TF_VAR 주입은 terraform-plan.yml과 동일한 GitHub Vars 재사용(project_id,
  dev_subnet_cidr, labels, private_services_cidr, gke_master/pods/services cidr,
  MASTER_AUTHORIZED_NETWORKS). 신규 Secret 불요 — dev root엔 삭제-위험 allowlist가
  없다(MAN `[]`이 정상 상태, 접속 기본 경로는 DNS 엔드포인트 #45).
- 로컬 tfvars apply는 break-glass로 격하 — tfvars 함정(#253/#266/#273/#306) 원천 차단.

## workflow 구조

admin-apply와 동일 패턴(#211 마스킹·요약만 STEP_SUMMARY·plan은 private GCS
`gs://autoresearch-dev-tfstate/dev-apply-plans/`·concurrency 단일):
`workflow_dispatch` → plan job(요약 게시, plan 업로드) → `environment: dev-apply`
승인 → apply job(GCS plan 다운로드 → apply → 정리).

## 선행 순서

CI apply는 `terraform import`를 수행하지 않는다. #331(retrain 풀 main 편입)은
import가 선행돼야 하므로 **#331을 로컬 break-glass로 먼저 매듭**한 뒤 dev-apply를
가동한다.

## 검증·롤백

- 검증: fmt/validate → SA IaC apply → Environment 설정 → 첫 run(plan 요약 확인 →
  승인 → apply) → 연속 plan `No changes` → drift run green 유지.
- 롤백: workflow 파일 삭제 + SA/IAM 리소스 제거 apply(로컬 break-glass 경로는 그대로
  남아 있어 운영 중단 없음).
