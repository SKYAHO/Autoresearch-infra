# feast apply 셀프 호스티드 러너 이관 + 운영 배포 러너 분리 설계

> 관련 이슈: #541
> 상태: 설계 초안

## 목적

second-brain 볼트 `wiki/topics/GitHub-Actions-셀프호스티드-러너.md`의 "권장 전환
순서" 7단계 중 **5·6단계**를 다룬다. #533/#534(ARC PoC, 1~4단계)가 러너 전용
Kubernetes 경계와 ARC 설치, VPC 내부망 접근 증명까지 마쳤으므로 이번 변경은 그
위에 이어간다.

- **5단계**: `feast apply`를 `runs-on: [self-hosted, ...]`로 옮겨 private
  Redis 접근과 full scan을 검증한다.
- **6단계**: Terraform apply·운영 배포는 별도 러너와 GitHub Environment 승인
  게이트를 유지한다(self-hosted 러너 풀과 공유하지 않는다는 결정을 코드·문서로
  고정).

`docs/superpowers/specs/2026-08-05-actions-runner-controller-poc-design.md`
157~161행이 이 두 단계를 명시적으로 범위 밖에 뒀던 것을 이어받는다.

## 현재 문제

- `feast apply`는 지금 GitHub-hosted 러너(`ubuntu-latest`, VPC 밖) → WIF →
  GKE 인증 → `feast-apply-{dev,prod}` namespace에 Kubernetes `Job` 생성(#346) →
  Job Pod가 KSA/WI로 VPC 내부에서 실제 `feast apply`를 실행하는 우회 구조다.
  #533이 러너 자체가 VPC 내부망(K8s API 서버)에 직접 접근 가능함을 이미
  증명했으므로, 이 Job 생성/대기/RBAC 계층은 더 이상 필요하지 않다.
- **선행 조건이 되는 사고 발견**: 앱 저장소(`SKYAHO/Autoresearch`)
  `feast-apply.yml`의 `environment: ${{ ... || github.ref_name }}` 표현식이
  push 이벤트에서 브랜치명 `"main"`으로 풀린다. 앱 저장소에 내용이 빈
  GitHub Environment `"main"`이 존재해 값이 없고, 결과적으로 org-level 변수로
  폴백해 `#424`가 이미 삭제한 옛 공유 namespace를 가리킨다 — 2026-07-30부터
  main push마다 prod 경로가 실패 중이다(앱 저장소 소유, 이 저장소 범위 밖이나
  기록 필요). self-hosted 러너를 선택할 때도 같은 `environment` 표현식으로
  러너 라벨(`feast-apply-${environment}`)을 결정해야 하므로, **이 버그를 먼저
  고치지 않으면 러너 선택도 같은 방식으로 잘못된다** — 5단계 구현의 선행 조건으로
  명시한다.
- `apply.yml`(Terraform plan/apply)이 self-hosted 러너 풀과 격리돼 있는 것은
  지금은 우연(애초에 self-hosted 러너가 없었을 뿐)이지, 문서화된 결정이 아니다.
  dev-apply/admin-apply SA는 프로젝트 전역에 가까운 권한을 가지므로, feast-apply
  러너 풀이 침해되더라도 그 권한이 Terraform apply까지 번지지 않아야 한다.

## 결정

### 5단계 — 환경별 self-hosted 러너로 이관

**namespace/quota/limitrange는 재사용, 신규 KSA 2개만 추가.** `actions-runner-k8s`
namespace를 새로 쪼개지 않는다(#533 scaffold를 environment별로 복제하면
namespace/quota/limitrange 보일러플레이트가 3배가 된다). 대신:

- KSA 2개 신설: `feast-apply-dev-runner`, `feast-apply-prod-runner`
  (`automount_service_account_token = false`, `actions_runner_runner`와 동일
  패턴). `iam.gke.io/gcp-service-account` annotation은 **새 GSA를 만들지 않고**
  기존 `feast_apply_dev`/`feast_apply_prod` GSA(#424)를 그대로 가리킨다 — 이
  GSA는 이미 registry/staging GCS `objectAdmin`+`legacyBucketReader`, BigQuery
  dataset `metadataViewer`, prod만 Redis `dbConnectionUser`+CA
  `secretAccessor`를 갖고 있어 새 IAM이 필요 없다.
- ArgoCD Application 2개 추가: `deploy/actions-runner-scale-set-feast-dev/`,
  `-feast-prod/`(기존 `deploy/actions-runner-scale-set/` chart를 복제,
  `runnerScaleSetName`/`serviceAccountName`만 environment별로 다르게). ARC
  컨트롤러는 cluster 전역 1개를 그대로 공유한다.
- **`githubConfigUrl`은 이 저장소가 아니라 앱 저장소를 가리킨다.**
  `feast-apply.yml`은 `SKYAHO/Autoresearch`(앱 저장소)에 있으므로, 그 저장소가
  이 러너 스케일셋에 job을 배정하려면 `githubConfigUrl:
  https://github.com/SKYAHO/Autoresearch`로 등록해야 한다(PoC 스케일셋은
  `.../Autoresearch-infra`를 가리키는 것과 다름 — 스케일셋마다 대상 저장소가
  다를 수 있다는 점을 명확히 한다).
- **GitHub App 설치 범위를 앱 저장소로 확장해야 한다(수동, 1회).** 현재 App은
  `SKYAHO/Autoresearch-infra`에만 설치돼 있다(`docs/runbooks/2026-08-05-actions-runner-github-app-secret.md`
  1단계 5번). 같은 GitHub 계정(`SKYAHO`) 소유 저장소이므로 새 App 설치나 새
  Secret Manager 컨테이너 없이, 기존 설치(Installation)의 "Repository access"에
  `Autoresearch` 저장소를 추가하기만 하면 된다(Installation ID는 그대로 —
  Secret Manager/K8s Secret 값 갱신 불필요). 이 단계는 런북에 추가하고, 완료
  전에는 feast-dev/prod 스케일셋이 앱 저장소의 job을 받지 못한다(선행 조건).
  GitHub App 자격 증명 Secret 자체는 기존 `actions-runner-github-app` Secret을
  그대로 참조한다(재생성 불필요).

**NetworkPolicy는 스케일셋 라벨로 분리한다(신규 namespace 대신).** 같은
namespace를 세 스케일셋(PoC/feast-dev/feast-prod)이 공유하므로, 각
NetworkPolicy의 `pod_selector.match_labels`를 `actions.github.com/scale-set-name=<name>`
(chart가 러너 Pod에 붙이는 라벨, ArgoCD 배포 후 `kubectl get pods --show-labels`로
실측 확인)로 스코프해 서로 겹치지 않게 한다:

- `feast-apply-dev` 스케일셋 egress = DNS(x2), GKE metadata, WI metadata,
  PGA(GCS/BigQuery용 `restricted.googleapis.com`), GitHub Actions 서비스용
  `0.0.0.0/0:443`(RFC1918 except, ARC 러너 등록·job polling에 필수 — PoC와
  동일 예외). **K8s API 서버 규칙은 포함하지 않는다** — `feast apply`는
  `kubectl`/K8s API를 호출하지 않으므로 PoC 전용 규칙(`kubernetes.default.svc`
  검증용)을 최소 권한 원칙상 상속하지 않는다. Redis 규칙도 포함하지 않는다.
- `feast-apply-prod` 스케일셋 egress = 위 + Redis Cluster PSC. `feast_apply.tf`의
  prod 전용 블록(discovery `var.redis_discovery_port` + data node
  `var.redis_node_port_start`~`redis_node_port_end`, `var.redis_psc_subnet_cidr`)과
  **동일한 값**을 재사용한다 — `actions-runner-k8s`에 이 4개 변수를 신규로
  선언한다(현재 이 root에는 Redis 관련 변수가 없다).
- 기존 `actions-runner-poc` 스케일셋의 egress(K8s API 검증용)는 건드리지
  않되, 라벨 스코프가 없으면(현재 `pod_selector {}`로 namespace 전체 선택)
  세 스케일셋 모두에 같은 규칙이 겹쳐 적용된다 — 이번 변경에서 기존 정책도
  라벨 스코프로 좁혀 dev/PoC 러너가 실수로 prod Redis egress를 상속받지
  않게 한다(리뷰 포인트, PSA `baseline`만으로는 이 경계를 강제하지 못한다).

> **정정(#557, 2026-08-06)**: 위 88~90번째 줄의 "K8s API 서버 규칙은
> feast-apply 러너에 불필요하다"는 ephemeral runner Pod(= `feast apply`
> 실행 주체)에는 맞지만, 리스너(AutoscalingListener) Pod와 ARC 컨트롤러
> 매니저 Pod에는 틀렸다 — 리스너는 스케일셋 종류와 무관하게
> `EphemeralRunnerSet`을 patch하기 위해 매 폴링 사이클마다, 컨트롤러
> 매니저는 CRD watch·리스너/러너 Pod 생성을 위해 상시 apiserver 접근이
> 필수다. 리스너 Pod와 ephemeral runner Pod는 동일한 `scale-set-name`
> 라벨을 공유하므로 그 라벨로만 scoping하면 리스너를 배제하게 된다. 그
> 결과 `feast-apply-dev`/`feast-apply-prod` 리스너가 apiserver에
> 도달하지 못해 crash-loop했다(라이브 확인). 컨트롤러 매니저 Pod는
> `scale-set-name`도 `component=runner-scale-set-listener`도 달지
> 않아 애초에 어떤 K8s API 규칙에도 걸린 적이 없었고, 지금 정상 동작
> 하는 것은 재시작 없이 유지되는 기존 apiserver 커넥션(conntrack) 덕분
> 으로 추정된다 — 재시작 시 동일 crash-loop가 예상된다(PR #558 리뷰).
>
> #557에서는 K8s API egress를 **두 개의 별도 supplemental 정책**으로
> 나눴다: (1) `actions_runner_control_plane_k8s_api_egress` —
> `app.kubernetes.io/component` In [`runner-scale-set-listener`,
> `controller-manager`]로 스코프해 리스너 3개 스케일셋 전부와 컨트롤러
> 매니저에 적용, (2) `actions_runner_poc_k8s_api_egress` — 기존
> `scale-set-name=actions-runner-poc` 스코프를 그대로 유지해 96번째
> 줄이 서술하는 PoC ephemeral runner Pod의 K8s API 검증
> (`actions-runner-poc.yml`)을 그대로 보존한다. ephemeral runner Pod는
> 두 정책 어느 쪽에도 걸리지 않으므로(PoC 제외) feast-apply 스케일셋은
> 여전히 계속 차단된다.

**앱 저장소 좌표(이 저장소 범위 밖, 문서로만 명시)**: `feast-apply.yml`은
`runs-on: [self-hosted, feast-apply-${environment}]`로 바꾸고, Job 매니페스트
렌더링/재생성/대기/로그 수집 스텝을 제거해 `feast apply`를 워크플로우 스텝에서
직접 실행하도록 재작성해야 한다. 이 재작성과 환경 표현식 버그 수정은 앱 저장소
소유이며 이 이슈의 완료 조건에는 포함하지 않는다 — 좌표(러너 라벨, KSA/GSA
매핑)를 문서화해 앱 저장소 쪽 이슈가 참조할 수 있게 하는 것까지만 다룬다.

**롤백**: `terraform/admin/autoresearch-k8s/feast_apply.tf`(#346 GKE Job
namespace/RBAC)는 이번 변경에서 건드리지 않는다. 앱 저장소가 새 워크플로우로
전환한 뒤 문제가 있으면 워크플로우 파일만 이전 리비전으로 되돌리면 그대로
동작한다. 베이크 기간을 거친 뒤 별도 이슈로 Job RBAC/namespace 폐기 여부를
재검토한다(이번 이슈 범위 밖).

### 6단계 — 운영 배포(Terraform apply)는 별도 러너로 고정

`apply.yml`은 계속 GitHub-hosted `ubuntu-latest`에서 실행하고, self-hosted
라벨로 옮기지 않는다. dev-apply/admin-apply SA는 프로젝트 전역에 가까운
권한을 가지므로, feast-apply/PoC 러너 풀이 침해돼도 Terraform apply 권한까지
번지지 않아야 한다는 것이 근거다 — 두 신뢰 경계를 코드(러너 풀 자체를 아예
공유하지 않음)와 문서 양쪽에 고정한다.

새 Terraform 리소스는 필요 없다(`apply.yml`은 이미 GitHub-hosted다). 대신:

- `docs/TERRAFORM_DEV.md`(또는 `apply.yml` 상단 주석)에 이 경계를 명시적
  결정으로 기록한다: "Terraform apply/운영 배포 워크플로우는 self-hosted
  러너 라벨을 사용하지 않는다."
- PR 리뷰 기준(`CLAUDE.md` 리뷰 기준 섹션 또는 `.claude/docs/agent-workflow-reference.md`)에
  "`apply.yml`에 `runs-on: self-hosted` 계열 라벨을 추가하는 변경은 별도
  설계 검토 없이는 반려한다"를 한 줄 추가하는 것을 검토한다(선택, 과하면
  생략 가능 — 문서화만으로 충분하면 스킵).

## 범위 밖(명시)

- 앱 저장소(`SKYAHO/Autoresearch`) `feast-apply.yml` 실제 재작성 — 별도
  이슈/PR, 앱 저장소 소유.
- 발견된 `environment` 표현식 버그의 실제 수정 — 앱 저장소 소유, 별도
  이슈로 트래킹(이 스펙은 선행 조건으로만 명시).
- `terraform/admin/autoresearch-k8s/feast_apply.tf`(#346 GKE Job RBAC/namespace)
  폐기 — 베이크 기간 후 별도 이슈.
- 오토스케일링 min/max 튜닝, GitHub IP 대역 고정 allowlist 하드닝 — #533에서
  이미 범위 밖으로 남겼고 여전히 유효.
- vault 7단계(PoC 외 다른 내부망 워크플로우로 확장).

## 검증

- `terraform -chdir=terraform/admin/actions-runner-k8s fmt -check -recursive`,
  `init -backend=false`, `validate`(신규 변수·KSA·NetworkPolicy)
- `terraform -chdir=terraform/admin/argocd-k8s validate`(Application 2개 추가분)
- CI apply(`scope: admin`) 후 ArgoCD UI에서 신규 Application 2개가
  `Synced`/`Healthy`인지 확인
- `feast-apply-dev` 스케일셋에 연결된 임시 워크플로우(또는 `workflow_dispatch`
  테스트)로 GCS/BigQuery 읽기 접근 성공 확인
- `feast-apply-prod` 스케일셋에서 Redis PSC 접속 성공 확인(`redis-cli PING`
  또는 동등한 in-cluster 호출)
- 음성 대조군: `feast-apply-dev` 스케일셋 Pod에서 Redis 포트로 접속 시도 시
  timeout(라벨 스코프 NetworkPolicy가 실제로 분리됐음을 증명, #533 Task 7
  패턴 재사용)
- `apply.yml`에 self-hosted 라벨이 없음을 grep으로 재확인
  (`grep -n "runs-on" .github/workflows/apply.yml`)
