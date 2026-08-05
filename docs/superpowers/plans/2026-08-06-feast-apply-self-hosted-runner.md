# feast apply 셀프 호스티드 러너 이관 + 운영 배포 러너 분리 구현 계획

> 설계: `docs/superpowers/specs/2026-08-06-feast-apply-self-hosted-runner-design.md`
> 관련 이슈: #541

## Task 1 — `actions-runner-k8s`에 Redis PSC 변수 추가

`terraform/admin/actions-runner-k8s/variables.tf`에 `redis_psc_subnet_cidr`,
`redis_discovery_port`, `redis_node_port_start`, `redis_node_port_end`를
`terraform/admin/autoresearch-k8s/variables.tf`(203~243행)와 동일한 validation
조건으로 추가한다. `.environment.auto.tfvars.json`과
`terraform.tfvars.example`에도 값/플레이스홀더를 추가한다.

**완료 조건**: `terraform -chdir=terraform/admin/actions-runner-k8s validate`
통과, 새 변수 4개가 `autoresearch-k8s`와 값이 일치(같은 Redis 인스턴스를
가리키므로 값이 달라지면 사고).

## Task 2 — feast-apply 러너 KSA 2개 + NetworkPolicy 라벨 스코프

`terraform/admin/actions-runner-k8s/main.tf`에 추가:

- `kubernetes_service_account_v1.feast_apply_runner`(`for_each`로 dev/prod
  2개, `automount_service_account_token = false`, annotation은
  `terraform/envs/dev`의 `feast_apply_dev`/`feast_apply_prod` GSA 이메일 —
  이 root가 이미 `google_service_account`를 참조 가능한지 확인, 안 되면
  변수로 전달).
- 기존 `kubernetes_network_policy_v1.actions_runner_egress`를
  `pod_selector.match_labels = { "actions.github.com/scale-set-name" = "actions-runner-poc" }`로
  좁힌다(현재 `pod_selector {}`로 namespace 전체 선택 — 실측 후 실제 라벨
  키/값으로 교정).
- 신규 `kubernetes_network_policy_v1.feast_apply_runner_egress`(`for_each`
  dev/prod): DNS(x2)·GKE metadata·WI metadata·PGA·GitHub `0.0.0.0/0:443`
  예외는 두 environment 공통, K8s API 규칙은 포함하지 않는다(`feast apply`가
  호출하지 않음 — PoC 전용 규칙과 구분). prod만 Redis PSC 블록(discovery +
  data node 포트, `feast_apply.tf` 160~183행과 동일 구조)을 조건부로 추가
  (`each.key == "prod" ? [...] : []` 패턴, dynamic block).

**완료 조건**: `terraform -chdir=terraform/admin/actions-runner-k8s fmt -check
-recursive`, `validate` 통과. `plan` 결과에서 기존 `actions-runner-poc`
스케일셋 관련 리소스가 예기치 않게 재생성(replace)되지 않는지 확인(라벨
추가는 NetworkPolicy in-place 업데이트여야 한다).

## Task 3 — ArgoCD Application 2개 (feast-apply-dev/prod 스케일셋)

`deploy/actions-runner-scale-set-feast-dev/`, `-feast-prod/`를
`deploy/actions-runner-scale-set/`(기존 PoC용) 복제로 만든다. 각
`values.yaml`에서 `runnerScaleSetName`, `template.spec.serviceAccountName`
(Task 2의 새 KSA)를 environment별로 바꾸고, **`githubConfigUrl`은 PoC와
다르게 앱 저장소(`https://github.com/SKYAHO/Autoresearch`)를 가리킨다** —
`feast-apply.yml`이 그 저장소에 있으므로 러너가 그 저장소 job을 받으려면
그 저장소 스코프로 등록해야 한다.

`terraform/admin/argocd-k8s/main.tf`에 `kubernetes_manifest.application_*`
2개 추가(기존 `application_monitoring`/scale-set Application 패턴 그대로:
`releaseName` 명시 고정, `syncPolicy.automated = {prune=false,
selfHeal=false}`, retry 백오프, `syncOptions =
["ServerSideApply=true","CreateNamespace=false"]`). 컨트롤러 Application에
대한 `depends_on`(sync-wave)도 기존 scale-set Application과 동일하게 건다.
`variables.tf`에 두 Application용 `target_revision` 변수(기존
`actions_runner_scale_set_target_revision`과 동일 패턴)를 추가한다.

**선행 조건(수동, 런북에 추가)**: GitHub App 설치 범위를
`docs/runbooks/2026-08-05-actions-runner-github-app-secret.md`에 따라
`SKYAHO/Autoresearch`(앱 저장소)까지 확장해야 한다 — 같은 계정 소유라 기존
Installation의 "Repository access"에 추가하기만 하면 되고, Installation
ID·Secret 값은 그대로다. 이 단계 전에는 feast-dev/prod 스케일셋이 앱
저장소의 job을 전혀 받지 못한다(리스너는 뜨지만 job이 배정되지 않음).

**완료 조건**: `terraform -chdir=terraform/admin/argocd-k8s validate` 통과.
CI apply(`scope: admin`) 실행 후 ArgoCD UI에서 두 Application이
`Synced`/`Healthy`, 컨트롤러가 각 스케일셋의 리스너 Pod를 기동하는지 확인.

## Task 4 — apply.yml `ADMIN_ROOTS` 순서 확인 (변경 불필요 가능성 높음)

`terraform/admin/actions-runner-k8s`가 이미 `ADMIN_ROOTS`에 있으므로(113~120행)
신규 root 추가는 없다. 이 태스크는 확인만 한다 — plan 파일에서 Task 1~2의
변경이 이 root의 기존 apply 경로로 정상 처리되는지 확인.

**완료 조건**: 없음(리뷰 확인용, 코드 변경 없으면 스킵 가능).

## Task 5 — 검증 워크플로우로 GCS/BigQuery/Redis 접근 증명

`.github/workflows/actions-runner-poc.yml`을 참고해 임시 검증 워크플로우
스텝(또는 기존 PoC 워크플로우에 `workflow_dispatch` 입력으로 environment
분기 추가)을 만들어:

- `feast-apply-dev` 러너에서 `gcloud storage ls gs://<registry 버킷>` 성공
  (WI로 `feast_apply_dev` GSA 신원 확인).
- `feast-apply-prod` 러너에서 Redis Cluster PSC로 `redis-cli -h <discovery
  endpoint> -p <port> --tls PING` 성공(또는 동등한 in-cluster 호출).
- 음성 대조군: `feast-apply-dev` 러너에서 같은 Redis PING 시도 시 timeout
  (Task 2의 라벨 스코프 NetworkPolicy가 실제로 분리됐음을 증명).

이 워크플로우는 영구 자산으로 남길지, PoC처럼 1회성 검증 후 제거할지 이슈
본문에서 결정한다(제거 쪽을 기본으로 — #533의 `actions-runner-poc.yml`과
중복되는 목적이면 그 워크플로우를 확장해 재사용하는 편이 낫다).

**완료 조건**: 위 3개 시나리오(dev 성공/prod 성공/dev-Redis 실패) 모두
관측·기록.

## Task 6 — 운영 배포 러너 분리 결정 문서화 (6단계)

`docs/TERRAFORM_DEV.md`에 짧은 섹션 추가: "Terraform apply/운영 배포
워크플로우는 self-hosted 러너 라벨을 쓰지 않는다 — dev-apply/admin-apply SA는
프로젝트 전역에 가까운 권한이라 feast-apply 러너 풀과 신뢰 경계를 공유하면
안 된다." `apply.yml` 상단 주석에도 한 줄 추가.

**완료 조건**: 문서 갱신, `git diff --check` 통과. 새 Terraform/워크플로우
변경 없음(문서만).

## Task 7 — 앱 저장소 좌표 문서화 (범위 밖 코디네이션)

`docs/TERRAFORM_DEV.md` "Feast apply 환경별 런타임 경계 (#424)" 섹션 근처에
"셀프 호스티드 러너 이관 좌표" 하위 섹션을 추가해 앱 저장소가 참조할 값을
남긴다: 러너 라벨(`feast-apply-dev`/`feast-apply-prod`), KSA 이름, 대응 GSA
이메일, 선행 조건(environment 표현식 버그 수정 필요). 실제 `feast-apply.yml`
재작성은 이 태스크에 포함하지 않는다.

**완료 조건**: 문서 갱신만. 앱 저장소 쪽 이슈 생성은 사용자 확인 후 별도
진행(이 저장소 소유 아님).

## 순서와 의존성

Task 1 → 2 → 3(순차, Terraform 리소스가 서로 참조) → 5(3 완료 후 실제 러너
필요) → 6·7(독립적, 아무 때나 병행 가능). Task 4는 확인용이라 순서에
영향 없음.

## 롤백

Task 2~3에서 만든 KSA/NetworkPolicy/ArgoCD Application은 앱 저장소가 아직
참조하지 않는 한(Task 5 검증 워크플로우 제외) 프로덕션 트래픽에 영향이
없다 — `terraform destroy`(대상 한정) 또는 ArgoCD Application 삭제로 되돌릴
수 있다. `feast_apply.tf`(#346 경로)는 이번 계획에서 전혀 건드리지 않으므로
기존 GHA+Job 워크플로우는 항상 동작 가능한 상태로 남는다.
