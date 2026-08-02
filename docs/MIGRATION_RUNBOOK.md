# 프로젝트 이전/재구축 실행 Runbook

> 환경 좌표의 정본과 Terraform 초기화는 [ENVIRONMENT_CATALOG.md](ENVIRONMENT_CATALOG.md)를
> 따른다. 카탈로그 변경만으로 리소스를 이전하거나 apply하지 않으며, 이 문서의 승인·검증·
> 롤백 절차를 함께 따른다.

> #437. 2026-07-29~30 GCP 프로젝트 이전(#404, `ar-infra-501607` →
> `autoresearch-503903`)의 실측 절차를 재사용 가능한 실행 문서로 정리했다.
> 결정 요약은 `CHANGE_HISTORY.md`(2026-07-29~30 항목), 개별 함정의 상세 근거는
> 이슈 #404 진행 기록을 본다. **이 문서만 위에서 아래로 따라가면 #404에서
> 실제로 겪은 누락·장애가 절차상 재발하지 않는 것**이 목표다.

대상 시나리오: 다른 GCP 프로젝트로의 전면 이전, 신규 환경(staging/prod) 신설,
클러스터 전면 재구축. GCP는 프로젝트 간 리소스 이동을 지원하지 않으므로 전량
IaC 재적용 + 데이터 복사가 기본 전략이다.

---

## 전체 개요 — 이번에 무엇을, 왜, 어떻게 했나

> 실제 작업에 쓰인 용어를 그대로 쓰되, 처음 등장할 때 괄호로 뜻을 풀어
> 썼다. 명령어 수준 절차는 아래 Phase별 섹션을 본다.

### 무엇을 했나

우리 인프라는 GCP(Google Cloud Platform) **프로젝트**(GCP에서 결제·IAM
권한·리소스를 한 단위로 묶는 최상위 컨테이너. 회사 조직 안의 "사업부
계정"에 가깝다) `ar-infra-501607` 안에 전부 들어 있었다. 이번에 이 전체를
새 프로젝트 `autoresearch-503903`(project number `611398460162`)으로
이전했다.

### 왜 "재구축" 방식이었나

GCP는 **프로젝트 간 리소스 이동을 지원하지 않는다** — 예를 들어 GKE
클러스터나 VM을 다른 프로젝트로 그대로 옮기는 API가 없다. 그래서 옮기는
대신 **새 프로젝트에 똑같은 인프라를 처음부터 다시 만드는(재구축)** 방식을
썼다.

이게 가능했던 이유는 이 저장소가 **IaC**(Infrastructure as Code —
서버·네트워크·권한 같은 인프라 구성을 코드로 정의해 관리하는 방식)로,
**Terraform**(코드로 작성한 인프라 정의를 실제 클라우드 리소스로
만들어 주는 도구)이 전체 인프라를 관리하고 있었기 때문이다. 코드를 새
프로젝트를 대상으로 다시 `terraform apply`(코드와 실제 상태의 차이를
계산한 뒤 실제 리소스에 반영하는 명령)하면, 원래 인프라와 동일한 구성을
새 프로젝트에 재현할 수 있다. 대안으로 `gcloud beta projects move`
(리소스는 그대로 두고 소속 조직만 바꾸는 명령)도 검토했지만, 회사가 새
프로젝트 ID 사용 자체를 확정했기 때문에 배제했다.

### 진행 순서 (Phase 0~6, 실측 상세)

> 각 항목은 실제 실행일과 관련 이슈·PR 번호를 함께 적었다. 명령어 수준
> 재현 절차는 아래 `## Phase 0` ~ `## Phase 6` 섹션을 그대로 따라가면
> 된다 — 여기서는 "무슨 일이 어떤 순서로, 왜 그 순서로" 일어났는지를
> 기록한다.

**Phase 0 — 부트스트랩 (2026-07-29, 사용자 선행 + 로컬 1회 apply)**

1. 사용자가 콘솔에서 새 프로젝트 `autoresearch-503903`에 작업 계정
   owner IAM 권한을 부여하고 결제 계정을 연결했다. 조직이 옛 프로젝트와
   다르면 IAM 전파에 수 분이 걸릴 수 있어 `gcloud projects describe`로
   반영을 확인했다.
2. **quota**(프로젝트별 리소스 사용 상한)를 **신청 전에 먼저
   실측**했다 — 옛 프로젝트에서 `E2_CPUS` quota 소진으로 Cluster
   Autoscaler scale-up이 6시간 동안 막힌 실측 사고(#388: 리전
   `E2_CPUS` 한도 8이 가동 노드 3대로 정확히 소진된 상태에서
   materialize KPO 파드(요청 2 CPU/4Gi)가 6시간+ Pending, CA가
   dev-default 1→2 증설을 14회 시도했으나 전부 `FailedScaleUp: GCE
   quota exceeded`)가 재발하지 않도록 증설을 검토했지만, 새 프로젝트의 기본 quota는 오히려 옛
   프로젝트보다 **후한 항목도 있었다**(예: `E2_CPUS` 24, `N2_CPUS`
   200, SSD 500GB — 프로젝트마다 기본값이 달라질 수 있어 "새
   프로젝트니까 더 박할 것"이라는 가정은 틀릴 수 있다). 그래서 무작정
   증설 신청부터 하지 않고 `gcloud compute project-info describe
   --format="table(quotas.metric,quotas.limit,quotas.usage)"` 등으로
   실제 값을 먼저 조회한 뒤, 부족한 항목만 선별로 신청했다(`PREEMPTIBLE_
   CPUS`가 0으로 리셋돼 있던 것은 이 실측에서도 못 잡고 Phase 6에서야
   드러났다 — 아래 참고).
3. 필요한 GCP API(compute, container, sqladmin, redis,
   artifactregistry, secretmanager, servicenetworking, iam,
   iamcredentials, sts, cloudbuild, bigquery, dns, cloudkms)를
   enable했다.
4. 새 Terraform **state 버킷**(Terraform이 "지금 어떤 리소스가 어떤
   상태로 존재하는지" 기록해 두는 GCS 버킷) `autoresearch-503903-dev-
   tfstate`를 versioning 켜서 새로 만들었다. 버킷 이름은 GCS 전역에서
   유니크해야 해서 옛 버킷명(`autoresearch-dev-tfstate`)을 그대로 못
   쓰고 프로젝트 id를 접두로 붙였다.
5. **WIF**(Workload Identity Federation — GitHub Actions가 서비스
   계정 키 파일 없이 GCP에 인증하는 방식) pool/provider와 **CI
   SA**(CI가 GCP 작업을 수행할 때 쓰는 서비스 계정)를 별도 Terraform
   **workspace**(`autoresearch-503903`, 옛 프로젝트 workspace와
   완전히 분리)에서 로컬 1회 apply했다. 결과는 **9 add / 0
   destroy**(옛 프로젝트 리소스는 전혀 건드리지 않음)였다. 이 apply
   자체가 CI 인증 수단을 만드는 작업이라 CI로는 수행할 수 없는
   닭-달걀 구조였다(`docs/TERRAFORM_BOOTSTRAP.md` 절차 재사용, #341
   최초 부트스트랩 때와 동일 패턴).
   → PR [#405](https://github.com/SKYAHO/autoresearch-infra/pull/405)
   "프로젝트 이전 Phase 0~1 — bootstrap 변수화·state backend 전환".

**Phase 1 — 코드·변수 전환 (2026-07-29, PR #405/#407/#414/#419)**

1. Terraform state backend 버킷 이름이 하드코딩된 파일들을 새
   버킷명으로 일괄 교체했다: `terraform/envs/dev` + `terraform/admin/*`
   admin root 10개의 `versions.tf`(backend 블록), `terraform/envs/dev/
   github_actions.tf`(admin-apply SA의 state 버킷 IAM 바인딩 대상),
   `.github/workflows/admin-apply.yml`·`dev-apply.yml`(plan 업로드 GCS
   경로), 관련 문서 7종(`TERRAFORM_DEV.md`, `INFRASTRUCTURE_SUMMARY.md`,
   `terraform/README`, `envs/dev/README`, `monitoring-k8s/README`,
   `.claude/docs/` 2종). **이 PR은 리뷰 시점에 CI `terraform-plan`이
   실패하는 것이 정상**이었다 — backend는 이미 새 버킷을 가리키는데
   repo variables(CI SA)는 아직 옛 프로젝트라 `terraform init` 인증
   자체가 안 되기 때문이다(환경보다 코드를 먼저 배포하는 순서라 생기는
   과도기, 머지 직후 variables 교체로 해소).
2. `deploy/mlflow/deployment.yaml`, `deploy/serving/deployment.yaml`의
   **Artifact Registry**(컨테이너 이미지를 저장하는 GCP 서비스) 이미지
   경로·`GCP_PROJECT` env·feast registry/staging·mlflow artifacts
   버킷 URL을 새 프로젝트 값으로 교체했다. 선행 조건인 이미지 복사가
   digest를 완전 보존했음을 먼저 확인했다(serving `f32379…`, mlflow
   `21f1bd…` — Phase 5에서 복사한 그 digest와 동일한지 대조) → PR
   [#407](https://github.com/SKYAHO/autoresearch-infra/pull/407)
   "deploy 이미지·버킷 참조를 새 프로젝트로 교체". 새 버킷명은 새
   프로젝트에 실제 생성된 버킷 목록과 대조해서 오탈자를 걸렀다.
3. bootstrap state 버킷명을 default 값이 있는 변수로 남겨 뒀다가
   실수로 옛 버킷을 다시 가리킬 여지가 있어, default 없는 필수 변수로
   전환했다 → PR
   [#414](https://github.com/SKYAHO/autoresearch-infra/pull/414).
4. **GitHub repo variables**(워크플로우 YAML이 참조하는 저장소 단위
   설정값 — `GCP_PROJECT_ID`, `WIF_PROVIDER_ID`, `CI_SA_EMAIL`,
   `DEV_APPLY_SA_EMAIL`, `ADMIN_APPLY_SA_EMAIL`, `WIF_POOL_ID` 등)는
   PR이 머지된 **직후에만** 교체했다. 미리 바꾸면 아직 열려 있는 다른
   PR의 `terraform plan`이 옛 프로젝트 기준으로 깨지기 때문이다(환경을
   코드보다 먼저 바꾸면 안 된다는 교훈을 앱 저장소 app#393에서 이미
   겪었던 것을 재적용).
5. 운영 문서 10종(README·runbook 등)의 프로젝트 참조를
   `autoresearch-503903`으로 일괄 갱신 → PR
   [#419](https://github.com/SKYAHO/autoresearch-infra/pull/419) "운영
   문서 프로젝트 참조 일괄 갱신".
   같은 시기에 피처 스토어(Feast) dev 환경 좌표(오프라인 dataset,
   GitHub Environments 분리)도 새 프로젝트 기준으로 재프로비저닝했다
   → 이슈 #408 → PR #409, 등록 절차 오탈자 수정 PR #418.

**Phase 2 — dev root CI apply (2026-07-29)**

1. VPC → Cloud NAT → Artifact Registry → Cloud SQL → Redis → GKE 순서
   (Terraform 의존성이 자동 계산하는 단일 root)로 **dev root**(하나의
   Terraform state로 함께 관리되는 dev 환경 전체 단위) 204개 리소스를
   apply했다.
2. WIF·CI SA 자체가 Phase 0의 산출물이라(먼저 만들어져야 CI가
   인증할 수 있는 순환 구조), 이 첫 apply만 **로컬 break-glass**(CI
   자동화를 거치지 않고 사람이 직접 인증해서 실행하는 예외 경로)로
   수행했다. 여기서 **plan 파일의 플랫폼 종속** 함정을 만났다 — CI(리눅스
   러너)가 만든 binary plan 파일을 로컬 macOS로 내려받아 `terraform
   apply <plan파일>`로 그대로 적용하려 했지만, Terraform의 plan 파일은
   OS/아키텍처에 종속돼 있어 다른 플랫폼에서 apply가 거부됐다. → plan
   파일을 재사용하지 않고 로컬에서 `plan`부터 `apply`까지 새로
   실행하는 것으로 우회했다(리뷰 대조는 CI가 올린 plan 텍스트와 로컬
   plan 텍스트를 diff해서 갈음).

   이 "첫 apply만 로컬 break-glass가 강제되는" 순환 구조 자체를
   구조적으로 없앨 수 있는지는 별도 검토 이슈(#440)로 남겼다 — apply
   전용 SA(dev-apply·admin-apply) 2종을 dev root가 아니라 **bootstrap
   root로 이관**하면 재구축 때마다 반복되는 이 순환을 없앨 수 있는가를
   검토했다. 결론은 **안 B(현행 구조 유지 + 절차 명문화)**로,
   안 A(SA를 bootstrap으로 이관)를 기각했다 — 근거는 재구축 빈도 대비
   안 A의 상시 비용이 더 크다는 것: 최강 권한 SA를 bootstrap이라는
   별도 state가 소유하게 되면 그 root의 권한이 비대해지고 state 분리
   원칙(리소스 종류별로 state를 나눠 blast radius를 좁힌다는 이
   저장소의 기존 설계, #341)이 약해지는 반면, 이 chicken-egg는 애초에
   재구축이라는 드문 이벤트에서만 나타나고 그때조차 bootstrap 자체의
   최초 apply는 안 A를 택해도 어차피 로컬 1회가 필요해 실질적으로
   얻는 게 없었다(PR
   [#446](https://github.com/SKYAHO/autoresearch-infra/pull/446)).
3. apply 완료 후 연속으로 `terraform plan`을 돌려 "No changes"를
   확인했다. 이후 `DEV_APPLY_SA_EMAIL`, `ADMIN_APPLY_SA_EMAIL`,
   `WIF_POOL_ID` 등 나머지 repo variables를 새 프로젝트 값으로
   전환해, 이 시점부터 CI(`terraform-plan`/`dev-apply`)가 새 프로젝트를
   정상적으로 대상으로 삼게 됐다.

**Phase 3 — admin roots 순차 apply (2026-07-29)**

1. GKE 클러스터가 준비된 뒤, Kubernetes 리소스를 관리하는 별도
   Terraform state 단위인 **admin root** 7개를 워크플로우의
   `ADMIN_ROOTS` 순서 — `autoresearch-k8s` → `airflow-k8s` →
   `monitoring-k8s` → `elastic-k8s` → `mlflow-k8s` →
   `argo-rollouts-k8s` → `argocd-k8s`(namespace 소유 root 먼저,
   다른 namespace를 참조하는 argocd는 마지막) — 로 apply했다.
   `gke-team-access`는 `ADMIN_ROOTS`에서 명시적으로 제외된
   root라(#314 — apply SA 권한 비대 방지, 사람 IAM은 로컬
   break-glass 유지) 별도로 로컬에서 71개 IAM 리소스를 apply했다.
   `vault-k8s`도 이미 드랍이 결정된 샌드박스라 대상에서 제외했다 —
   `admin-apply` 워크플로우의 ROOTS 목록에서도 빼도록 PR
   [#416](https://github.com/SKYAHO/autoresearch-infra/pull/416)으로
   반영(#412 A단계).
2. 신선 클러스터에서만 드러나는 함정 3종을 이 단계에서 실측했다(상세는
   아래 "진행 중 겪은 이슈와 해결" 참고): ① **CRD**(Custom Resource
   Definition)가 클러스터에 아직 없는 상태에서는 그 CRD를 쓰는 root의
   `terraform plan` 자체가 실패하므로, CRD를 설치하는 operator root만
   먼저 `-target`으로 선적용한 뒤 나머지 root를 순서대로 apply했다.
   ② 신선 클러스터에서 `namespaces "airflow" not found` 오류 — 당시
   이슈·PR 본문에는 "root 간 apply 순서 문제"로 기록됐지만, 사후
   조사(#436 → PR #442의 머지된 diff)에서 **오진으로 확정**됐다:
   cross-root 참조는 실측상 없었고, 진짜 원인은 airflow-k8s **root
   내부**에서 `airflow_components` Role이 namespace를 변수
   문자열로만 참조해 Terraform 그래프에 암시 의존이 잡히지 않았고,
   신선 클러스터에서 ns 생성과 Role 생성이 레이스를 일으킨 것이었다.
   기존 클러스터에서는 ns가 항상 먼저 존재해 드러나지 않았다. 해결은
   해당 Role에 `depends_on = [kubernetes_namespace_v1.airflow]` 한
   줄 보강 — 이 root에서 유일하게 누락돼 있던 의존 간선이었다.
   (문서화 교훈: 이슈/PR 본문은 작성 시점의 추정을 담을 수 있으므로,
   사후 기록은 머지된 diff·코드 주석 같은 최종 소스와 대조해야
   한다 — 이 항목 자체가 그 오진을 한 번 그대로 옮겨 적었다가 정정된
   사례다.) ③
   **oauth-proxy rollout**이 계속 대기(pending) 상태에 머문 원인은
   oauth-proxy Deployment가 참조하는 OAuth client Secret이 아직
   주입되지 않아서였다 — Secret을 먼저 주입해야 rollout이 진행되므로,
   apply 순서를 "리소스 생성 → Secret 선주입 → rollout 완료 확인"으로
   맞췄다(Secret 자체는 아래 Phase 4에서 재주입). 이 3종 함정의
   재발 방지로 PR
   [#442](https://github.com/SKYAHO/autoresearch-infra/pull/442)(#436)가
   ② 항목의 `depends_on` 간선을 보강하고(ROOTS 순서는 cross-root
   참조가 없음이 확인돼 현행 유지), "CRD operator `-target`
   선적용"·"operator Secret 선주입" 두 신선 클러스터 전용 단계를
   워크플로우 주석에 명문화했다.

**Phase 4 — Secret 재주입·환경 재구성 (2026-07-29)**

1. operator가 주입하는 **Secret**(비밀번호·API 키 등 민감 값) 13종을
   재주입했다 — 그대로 옮기면 되는 값 10종 + 새 환경에 맞게 값 자체를
   다시 계산해야 하는 값 3종(예: 새 ILB IP, 새 OAuth client 값)으로
   나뉘었다.
2. `mlflow-db` 비밀번호는 `random_password`가 생성한 값에 `#`·`@`
   같은 특수문자가 섞여 있어 DB 접속 URI(`postgresql://user:pw@host/db`
   형식) 파싱이 깨졌다 — MLflow가 뱉은 에러는 문자 그대로
   `Invalid IPv6 URL`이었다(비밀번호 안의 `@`나 `:`가 URI 파서에는
   host/포트 구분자나 IPv6 대괄호 표기로 오인돼 이런 낯선 에러 메시지로
   나타난다). → 우선 URL-인코딩해서 재주입하는 방식으로 우회했다.
   근본 해결로 비밀번호 생성 자체를 URI에 안전한 문자셋(unreserved
   set: 영문/숫자 + `-_.~`)으로 제한하는 하드닝(#438 → PR
   [#444](https://github.com/SKYAHO/autoresearch-infra/pull/444))이
   머지됐다 — `random_password.db_app_password`·`mlflow_db_password`
   양쪽에 `override_special = "-_.~"` 적용. 단 이 변경은 문자셋 변경이라
   다음 apply에서 비밀번호 2종을 **재생성(replace)** 시키므로, 야간
   배치 파이프라인 완주 후로 apply 시점을 조율하고 apply 직후
   Airflow metadata 커넥션 재구성·MLflow Secret 재주입(이번엔
   URL-인코딩 불필요)·관련 rollout restart·로그인 재검증을 한
   절차로 묶어 실행하기로 PR에 명시했다. 이슈 #404의 2026-07-31
   완결 기록에도 "rotate 적용"이 적혀 있다. 다만 이 서술만으로는 요약
   코멘트에 기댄 추정이므로, rotate 자체의 완료 여부는 apply 이력이나
   `terraform plan`의 `random_password` 무변경으로 직접 확인해야 한다.
3. **OAuth client**(구글 로그인 연동 인증 정보) 5종은 프로젝트에
   종속돼 복사가 안 되므로 콘솔에서 새로 발급받았다. MLflow에서 로그인
   실패가 났는데, 원인은 **client id에 정본이 없었던 것**이었다 —
   Airflow는 client id/secret 둘 다 Secret Manager에 정본으로 두는
   반면(#54), MLflow는 client secret만 Secret Manager에 있고 client
   id는 주입 runbook 문서에 **하드코딩된 텍스트**로만 존재했다. OAuth
   client를 재발급하면 id/secret이 **한 쌍으로 함께** 바뀌는데,
   Secret Manager의 secret 값은 갱신됐지만 문서에 박힌 id 텍스트는
   그대로라 두 값이 서로 다른 세대의 client를 가리키게 됐고, 결과는
   `invalid_client`로 로그인 자체가 막히는 것이었다(아래 이슈 항목
   "재발급 ≠ 반영" 참고). 근본 해결로 MLflow client id도 Secret
   Manager에 **빈 컨테이너로만** 먼저 Terraform 코드화했다(값 payload는
   코드 범위 밖 — `google_secret_manager_secret.mlflow_oauth_client_id`
   리소스 자체는 add 1건뿐이고, payload는 운영자가 apply 후 별도로
   `gcloud secrets versions add`로 주입, accessor는 부여하지 않아 주입은
   운영자 자격으로만 가능). 두 secret 모두 `prevent_destroy`를 걸어
   실수로 destroy될 때 저장소에서 복구 불가능한 payload가 사라지는
   사고를 막았다(#420 → PR #421). Grafana·Kibana OAuth client까지 같은
   방식으로 확장하는 작업은 후속 과제로 분리했다(#439). 이 과제는 PR
   [#445](https://github.com/SKYAHO/autoresearch-infra/pull/445)로
   마무리됐다 — Secret Manager 정본 4종(`…-grafana/kibana-oauth-
   client-{id,secret}`)을 mlflow(#420)·airflow(#54)와 대칭으로
   추가하고, 5종 UI(airflow·mlflow·grafana·kibana·argocd) client id의
   **프로젝트 번호 프리픽스**와 SM 정본 값의 **해시를 값 자체는
   노출하지 않고 대조**하는 `scripts/verify-oauth-clients.sh`를
   신설했다. 이 스크립트를 현행 클러스터에 실행해 프리픽스 5/5 일치,
   기존 정본 3종(airflow·mlflow) 해시 일치를 확인했고, 신설한
   grafana·kibana 2종은 SM에 아직 payload가 없는 상태라 WARN이
   뜨는 것까지가 설계된 정상 동작임을 실측으로 검증했다(payload
   등록·재검증은 PR에 "머지 후 작업"으로 명시된 조율 단계 — dev-apply로
   SM 컨테이너 4종 생성 후 현행 K8s Secret 값을 `versions add`로
   그대로 옮기고 스크립트를 다시 돌려 WARN이 사라지는지 확인하는
   순서). 이 payload 등록·재검증 조율 단계는 **완료됐음을 실행으로
   확인했다** — `scripts/verify-oauth-clients.sh <context> <project>` 재실행
   결과 5종 client id 프리픽스가 모두 새 프로젝트 번호이고, id/secret
   10쌍의 K8s↔SM 해시가 전부 일치해 `결과: 전부 통과`가 나온다(grafana·
   kibana의 payload 미등록 WARN도 해소됨). 요약 코멘트가 아니라 이 스크립트
   재실행이 이 항목의 정본 확인 수단이다.
4. ArgoCD 앱을 새 클러스터에 재등록하고, Kibana의 saved objects는
   재구축용 Job(`kibana_saved_objects`)을 재실행해 자동 복원했다.

**Phase 5 — 데이터 복사 (2026-07-29~30)**

1. Artifact Registry 컨테이너 이미지 7종을 digest를 보존한 채로
   복사했다.
2. GCS 버킷 8개를 `gcloud storage rsync`로 복사했다(raw data, feast
   registry, code artifacts, ES snapshot 등).
3. BigQuery 테이블 7개를 `bq cp`(cross-project 지원)로 복사했다.
4. Cloud SQL 데이터베이스 3개를 export/import했다 — MLflow DB는
   애플리케이션이 먼저 기동해 스키마를 자동 생성해 버린 상태에서
   import하다 "relation already exists" 충돌이 나서, DB를 완전히
   재생성한 뒤 재import했다. 이 경험으로 이후 순서를 뒤집었다: **앱을
   먼저 정지(replica 0)한 채로 DB를 만들고 import를 끝낸 뒤에야 앱을
   기동**해, 앱이 빈 DB에 스키마를 먼저 만들어버리는 경쟁을 원천
   차단했다.
5. Airflow는 환경 변수를 먼저 새 프로젝트 값으로 교체 → 앱 저장소 PR
   #187 머지 → 첫 설치는 배포 워크플로우(업그레이드 전용이라 최초
   설치는 대상 외)가 아니라 수동 `helm install`로 수행하고, 기존
   Secret은 helm 릴리스에 입양(adopt)시켰다.

**Phase 6 — 검증·전환·정리 (2026-07-30~31)**

1. **2026-07-30**: 잔여 조사·정리를 진행했다 — 앱 코드에 남아 있던
   옛 프로젝트 fallback 값 5곳 수정, 운영 문서 10종 갱신(위 PR #419),
   Elasticsearch 스냅샷 저장소 + SLM(Snapshot Lifecycle Management)
   재등록 후 1회 실행으로 26개 인덱스 스냅샷 SUCCESS 확인, feast apply
   재실행으로 `registry.db`가 새 버킷 좌표를 가리키도록 재생성, 드랍된
   vault 클러스터의 helm release·namespace를 최종 삭제. 이 시점에
   기능적으로는 무해하지만 남아 있던 잔여 관찰 2건도 기록해 뒀다 —
   monitoring 앱의 kube-prometheus-stack CRD가 diff 노이즈(재적용해도
   실제 리소스 변경은 없는 코스메틱 drift)를 일으키는 것, 이미 드랍
   결정이 난 vault-0 파드가 삭제 전까지 crashloop 상태로 떠 있던 것 —
   둘 다 대상 외 리소스라 이전 완료 판정에는 영향이 없었다.
2. **내부 UI FQDN 터널 접속 확인**: MLflow oauth2-proxy의 내부
   **ILB**(Internal Load Balancer) `deploy/mlflow/oauth2-proxy.yaml`이
   `loadBalancerIP: 10.10.0.22`(옛 프로젝트 예약 IP)로 리터럴
   하드코딩돼 있었는데, Terraform이 관리하는 DNS 레코드는 새 프로젝트의
   예약 IP `10.10.0.2`(예약 이름 `autoresearch-dev-mlflow-ilb`)를
   가리키고 있어 둘이 어긋났다(#425 → PR #426, Airflow 쪽은 DNS
   `10.10.0.3` ↔ Service `10.10.0.12`로 IP 자체는 다르지만 동일한
   패턴. 이 항목의 구체 IP는 모두 당시 실측값 — 다음 이전에서는
   달라지며 정본은 terraform output이다). 증상은 "connection
   refused"가 아니라 **SSH 리스너는 정상
   기동했는데 그 뒤로 0바이트 무응답인 채 10초 타임아웃**이라
   원인 특정에 시간이 걸렸다 — bastion까지는 SSH가 붙지만
   bastion→ILB 구간이 죽어 있다는 신호인데, 파드·endpoint 자체는
   멀쩡했기 때문에(진단 당시 `airflow-webserver` endpoint 2개 모두
   Ready) 워크로드 쪽부터 의심하면 시간을 버린다. 판별은 다음 3개를
   대조해서 했다:
   ```bash
   kubectl -n mlflow get svc mlflow-oauth-proxy \
     -o jsonpath='{.status.loadBalancer.ingress[0].ip}'   # → terraform output mlflow_ilb_ip와 일치해야 정상
   gcloud compute addresses list --filter="name~mlflow-ilb" \
     --format="value(status)"                              # → IN_USE 여야 정상
   gcloud dns record-sets list --zone=<zone> \
     --filter="name~mlflow"                                # rrdatas가 예약 IP와 일치해야 정상
   ```
   해결은 매니페스트의 `loadBalancerIP` **리터럴 값을 새 프로젝트
   예약 IP로 갱신**하고, 주석에 "예약 IP가 재생성되면 반드시
   `terraform output mlflow_ilb_ip` 값으로 다시 맞춘다"는 경고를
   보강한 것이다. 주의할 점: **"값이 복사본이라 이전을 따라오지
   못한다"는 구조 자체는 해소되지 않았다** — 플레인 YAML 매니페스트라
   terraform output을 자동 주입할 경로가 없어(kustomize/ArgoCD
   plugin 등 별도 설계 필요) output "참조"로의 전환은 미완의 후속
   과제고, 다음 이전에서도 이 파일의 IP 갱신은 **사람이 체크리스트로
   챙겨야 하는 수동 단계**다(아래 Phase 6 절차의 "ILB
   내부 UI FQDN 터널 접속 확인" 항목이 그 방어선). 뼈아픈 점은 해당 라인
   바로 옆 주석에 "`terraform output mlflow_ilb_ip`를 참조하라"고
   이미 적혀 있었다는 것 — 주석은 옳았지만 값이 복사본인 이상 이전을
   막지 못했다. 수정이 배포되기 전까지 팀 접속은 FQDN 대신 실제
   ILB IP(위 판별 ①에서 얻은 Service IP)로 직접 터널을 열거나
   `kubectl port-forward`로 우회해 차단을 피했다. IAP 터널로
   접속하는 브라우저는 `localhost:4180`을 보므로 OAuth client의
   redirect URI는 다시 등록할 필요가 없었다(#244 설계 그대로). 검증은
   해당 예약 IP 리소스의 상태가 `RESERVED`(미사용)에서 `IN_USE`로
   바뀌는 것으로 했다. 두 저장소는 배포 방식 자체가 달라 **적용
   절차도 달랐다**: 인프라 쪽 매니페스트는 ArgoCD가 **manual sync**
   정책으로 배포하므로 머지 후 ArgoCD UI에서 hard refresh → sync를
   수동으로 눌러야 반영됐고(ILB의 전달 규칙이 실제로 바뀌기까지 15~30초
   소요), **Airflow 쪽의 동일한 하드코딩**(`deploy/airflow/values.yaml`의
   `loadBalancerIP: 10.10.0.12` → `10.10.0.3`)은 이 PR 범위 밖으로
   분리해 별도 앱 저장소 PR(`SKYAHO/Autoresearch-airflow#192`)로
   처리했다 — 그 저장소는 머지=자동 배포라 인프라 PR과 같은 타이밍에
   묶으면 배포 시점을 통제할 수 없기 때문이다.
3. `airflow/autoresearch-batch` **KSA**(Kubernetes ServiceAccount)가
   과거 runbook에만 적힌 수동 `kubectl` 명령으로 만들어져 있어
   Terraform 코드 어디에도 정의돼 있지 않았고, 재구축 과정에서 통째로
   빠졌다. 야간 배치의 KubernetesPodOperator(KPO) 파드가 이 KSA를
   요구해 admission 단계에서 403으로 전량 실패한 뒤에야 발견했다 —
   에러 원문은 `pods "train-ctr-model-cgdfyfcs" is forbidden: error
   looking up service account airflow/autoresearch-batch:
   serviceaccount "autoresearch-batch" not found`. 이슈(#427)는
   팀원이 접수했는데, 진단에서 핵심이었던 관찰은 **Workload Identity
   삼각형의 두 변은 멀쩡히 남아 있었다**는 것이다 — GCP 쪽
   GSA(`google_service_account.airflow_batch`)와 WI
   바인딩(`google_service_account_iam_member.airflow_batch_wi`)은 dev
   root 코드에 있어서 재구축 때 정상 생성됐고, 빠진 것은 K8s 쪽 KSA
   단 하나였다. 그래서 어떤 root의 `terraform plan`에도 이상이 없었던
   것이다(코드에 없는 리소스의 부재는 plan이 감지할 대상 자체가
   아니다). 부수 함정도 하나 드러났다: 이 시점 옛 프로젝트 billing이
   이미 비활성화돼 있어, 팀원 로컬 환경의 Terraform state 접근이
   `UserProjectAccountProblem` 오류로 막혔고 진단은 `kubectl` 실환경
   조회와 정적 코드 검색만으로 진행해야 했다 — 이전 과도기에는 옛
   좌표를 바라보는 도구가 진단 수단에서 통째로 빠질 수 있다. 응급 조치로 팀이 수동으로 KSA를 다시 만들어 배치를
   먼저 복구했고, 근본 조치로 `terraform/admin/airflow-k8s`에 기존
   `airflow` KSA와 동일한 패턴(변수 + `resource_prefix` 파생 GSA
   email locals + WI annotation)으로
   `kubernetes_service_account_v1.airflow_batch` 리소스를 추가했다.
   그 응급 수동 생성분은 destroy 없이 **`terraform import`로 state에
   입양**했고, import 직후 plan은 `automount_service_account_token`
   기본값 명시 in-place diff **1건뿐**(파드 재시작·영향 없음)임을
   확인했다(#428). 검증은 재실행 중이던 야간 파이프라인이 어제
   실패했던 지점(collect KPO)을 통과하는 것으로 했다 — 이러면 다음
   재구축부터는 admin-apply 한 번으로 이 KSA도 자동 생성된다. 원인
   조사 중 놓치기 쉬운 구분점을 하나 정리해 뒀다: **KSA 자체가
   없으면** 파드가 뜨지도 못하는 admission 단계 403(이번 사고)이지만,
   **KSA는 있는데 GCP GSA와의 WI 바인딩만 어긋나면** 파드는 정상
   기동한 뒤 GCP API를 호출하는 런타임에서야 토큰 교환 403이 난다 —
   증상이 비슷해 보여도 원인은 다르고, 어느 쪽도 `terraform plan`으로는
   못 잡아내므로(plan은 K8s RBAC/WI 바인딩의 "실제 동작"까지는
   검증하지 않음) 재구축 후 최소 1회는 실제 파드 기동으로 검증해야
   한다. PR #428 리뷰에서 이 간극이 한 층 더 파헤쳐졌다 — KSA
   이름·namespace는 dev root(GSA·WI 바인딩)와 airflow-k8s root(KSA)가
   **각자 default를 가진 별개 변수**로 들고 있어서, 한쪽만 바꾸면 WI
   member는 문자열이라 KSA 실존을 검증하지 않고 KSA annotation도 GSA
   실존을 검증하지 않아 **어느 root의 plan/apply도 통과한 뒤 배치
   런타임 403에서만** 어긋남이 드러난다. 그래서 저장소의 cross-root
   결합 변수 패턴대로 두 변수에 validation(GSA email 형식 regex, KSA
   이름 RFC1123)과 "상대 root와 같은 값이어야 하며 불일치 시 plan은
   통과하고 런타임 403이 난다"는 description을 추가해, 형식 오류만이
   라도 plan 단계에서 잡히게 했다. 같은 리뷰에서 apply 순서 제약도
   확인됐다: dev root와 airflow-k8s root는 **어느 순서로 apply해도
   통과**하고(상호 실존 검증이 없으므로), 둘 다 적용되기 전까지는
   배치 런타임 403만 난다 — 재구축 체크리스트에 admin-apply 실행을
   필수 단계로 명시한 이유다.
4. batch-spot 노드풀은 새 프로젝트의 quota가 옛 프로젝트와 비대칭으로
   리셋돼 있었다: `E2_CPUS 24`(부족), `PREEMPTIBLE_CPUS 0`(batch-spot이
   의존하는 값, 완전 소진), `N2_CPUS 200`(넉넉). batch-spot 노드풀이
   쓰던 `e2-standard-2` 머신 타입이 `PREEMPTIBLE_CPUS` quota를 요구해
   자리를 못 잡고 계속 대기했다(#422). E2 quota 증설 신청은 실제로
   알아봤으나 어려움을 확인했고, 대신 **버스트 수요 자체를 여유 있는
   N2 quota로 이전**하는 쪽을 택했다 — `n2-standard-2`로 머신 타입
   전환(PR #423). 전환 후 최악 동시 사용량 기준으로 E2 16/24,
   N2 24/200으로 양쪽 모두 여유가 확보되고, retrain 노드풀
   (`n2-highmem`)과 머신 계열도 정렬된다. 비용은 노드 0대 유휴
   상태에선 불변이고 버스트 시 n2 spot 단가가 소폭 오르는 정도.
   머신 타입 변경은 노드풀 리소스의 **destroy+create**(교체)를
   유발하지만, batch-spot은 `min=0`이고 당시 가동 노드가 0개라 실제
   워크로드 영향은 없었다.
5. **2026-07-30 남은 항목 정리**: 야간 DAG 정상 동작 관찰, **OAuth
   client 5종 재발급이 실제 클러스터 Secret에 반영됐는지 재확인**(옛
   프로젝트 shutdown 전 필수 선행 조건 — #420 이슈로 MLflow부터
   Secret Manager 정본화, PR #421), 옛 프로젝트 shutdown 예약.
6. TEAM_OPERATIONS_RUNBOOK 기준 스모크 테스트(IAP SSH, Airflow/
   Grafana/Kibana/MLflow UI 로그인, 야간 DAG 1회 success)를 통과한
   뒤에야 다음 단계로 넘어갔다.
7. **2026-07-31**: OAuth 전환 완료로 런타임 의존이 0(가동 중
   워크로드·CI·데이터 경로 기준)임을 최종 확인한 뒤, 옛 프로젝트
   `ar-infra-501607`을 `gcloud projects delete`로 삭제 요청 처리했다
   (`DELETE_REQUESTED` 상태 — 30일 내 `gcloud projects undelete`로 프로젝트
   ID 복원은 가능하나 리소스·데이터 복구는 보장되지 않는다).
8. 마지막으로 `docs/` 전 문서 15종(약 6,900줄)을 코드·라이브 상태와
   전수 대조하는 병렬 감사를 수행해 발견 32건을 심각도별로
   정합했다(#435, `CHANGE_HISTORY.md`처럼 이력 성격 문서와 로컬 전용
   문서 2종은 감사 대상에서 제외):
   - **H(사실과 어긋나던 서술)**: Vault를 "운영 중"으로 서술하던
     문서 6개를 드랍 상태(#412)에 맞게 정정, admin root 개수 오기
     "8개"→7개(#416 반영 누락분), 옛 클러스터 GKE endpoint IP가
     리터럴로 박혀 있던 것, "app KSA는 수동 생성"이라는 서술이
     실제로는 `autoresearch-k8s`가 IaC로 관리하는 것과 모순되던 것.
   - **M(문서 간·문서 내 불일치, 컨벤션 위반)**: 알림 allowlist가
     문서마다 다른 개수로 서술돼 있던 것 통일, mermaid 다이어그램의
     ILB IP·SQL IP가 리터럴로 박혀 있던 것을 output 참조 서술로 교체,
     Redis Secret 예시가 `--from-literal`을 쓰던 것을 보안 컨벤션
     (`--from-env-file`, #213)에 맞게 교정.
   - **L(보강·표기)**: Secret Manager 목록·노드풀 목록·권한 표 등을
     최신 상태에 맞게 보강.
   이 감사에서 나온 후속 이슈 후보(리소스명 오탈자 정정, branch
   ruleset 승인 인원수 정책 재확정)는 별도 이슈로 분리하고 이 PR
   범위에는 포함하지 않았다.

### 진행 중 겪은 이슈와 해결

새로 만든 클러스터라서 기존 클러스터에서는 드러나지 않던 문제가 여럿
있었다.

- **CRD 미존재로 Custom Resource plan 자체가 불가능**: ECK(Elastic Cloud
  on Kubernetes)·ArgoCD처럼 **CRD**(Custom Resource Definition —
  쿠버네티스에 새로운 종류의 리소스를 등록해 두는 스키마 정의)를 쓰는
  root는, 클러스터가 신선해서 CRD가 아직 설치되지 않은 상태면 그 CRD를
  쓰는 **Custom Resource**(CR — CRD로 정의된 커스텀 오브젝트)의
  `terraform plan` 자체가 안 됐다. → operator(CRD를 설치하는 Helm
  릴리스)만 `-target` 옵션으로 먼저 적용한 뒤 CR을 적용하는 순서로
  우회했다.
- **namespace 생성 레이스**: 신선 클러스터 apply에서 `namespaces
  "airflow" not found` 오류가 났다. 당시엔 root 간 apply 순서 문제로
  기록됐지만 사후 조사(#436 → PR #442)에서 오진으로 확정 — 진짜
  원인은 airflow-k8s root **내부**에서 Role 리소스가
  **namespace**(쿠버네티스에서 리소스를 논리적으로 격리하는 구역)를
  변수 문자열로만 참조해 Terraform이 의존 관계를 모르는 채 ns 생성과
  레이스를 일으킨 것이었다(기존 클러스터에선 ns가 늘 먼저 있어 잠복).
  → 해당 리소스에 `depends_on` 명시 한 줄로 해결.
- **Secret 부재로 rollout 대기 실패**: oauth2-proxy 같은
  **Deployment**(쿠버네티스에서 파드 개수·버전을 관리하는 오브젝트)는
  필요한 Secret이 미리 주입돼 있지 않으면 **rollout**(새 버전 배포가
  정상 기동할 때까지 기다리는 절차)이 타임아웃으로 실패했다. → Secret을
  먼저 주입한 뒤 apply하는 순서로 바꿨다.
- **비밀번호 특수문자로 인한 파싱 오류**: Terraform의 `random_password`
  (무작위 비밀번호를 생성하는 리소스)가 만든 비밀번호에 `#`·`@` 같은
  특수문자가 포함되면, MLflow가 그 값을 DB 접속 URI에 그대로 넣다가
  파싱 오류("Invalid IPv6 URL")로 크래시했다. → 비밀번호를
  URL-인코딩(특수문자를 URL에서 안전한 형태로 바꾸는 인코딩)해서
  재주입했다.
- **"재발급 ≠ 반영"(MLflow 로그인 `invalid_client`)**: MLflow의 OAuth
  client는 Airflow와 달리 client secret만 Secret Manager 정본이 있고
  client id는 주입 runbook 문서에 하드코딩된 텍스트로만 있었다. 재발급은
  id/secret을 **한 쌍으로 함께** 바꾸는데, Secret Manager의 secret 값은
  새로 넣었지만 문서의 id 텍스트는 그대로 남아 있어 두 값이 서로 다른
  세대의 client를 가리키게 됐고, 로그인은 `invalid_client`로 막혔다.
  "재발급했다"와 "실제로 반영됐다"가 서로 다른 상태였던 것. → 우선
  client id의 프로젝트 번호 프리픽스(값 전체를 노출하지 않고도 대조
  가능)를 K8s Secret과 비교해 세대 불일치를 확인하고, Secret 갱신 후
  `rollout restart`로 즉시 복구했다. 근본 원인은 "id의 정본이
  없었다"는 것이라, MLflow client id도 Secret Manager에 빈 컨테이너로
  코드화해 Airflow와 동일하게 id/secret 둘 다 정본을 갖도록
  통일했다(#420 → PR #421, `prevent_destroy`로 실수 삭제도 방지).
- **수동 오브젝트 누락**: `airflow/autoresearch-batch`라는
  **KSA**(Kubernetes ServiceAccount — 파드가 GCP 리소스에 접근할 때 쓰는
  쿠버네티스 계정)가 runbook에만 적힌 수동 `kubectl` 명령으로 만들어져
  있었는데, 재구축에 쓰인 Terraform 코드에는 정의돼 있지 않아 통째로
  빠졌다. 낮 작업은 이 KSA를 안 써서 멀쩡했지만, 야간 배치가 이 KSA를
  요구해 **admission**(쿠버네티스가 파드 생성을 최종 허용하기 전
  검증하는 단계)에서 403으로 전량 실패했다. → KSA를 Terraform 코드로
  편입해 다음 재구축부터는 자동으로 함께 생성되게 했다. 교훈: 코드 밖
  수동 오브젝트는 재구축마다 빠지므로 발견 즉시 IaC로 편입한다.
- **`loadBalancerIP` 하드코딩과 DNS 불일치**: 내부 **ILB**(Internal Load
  Balancer — VPC 내부에서만 접근 가능한 로드밸런서)를 쓰는 Kubernetes
  Service 매니페스트에 `loadBalancerIP`가 리터럴 IP로 하드코딩돼
  있었는데, **DNS**(도메인 이름을 IP 주소로 변환해 주는 서비스. 여기선
  Terraform이 관리하는 private DNS zone)는 새 프로젝트의 예약 IP를
  가리키면서 두 값이 서로 어긋나, 내부 UI 접속용 SSH 터널이 전면 불가능
  해졌다. 증상이 "접속 거부"가 아니라 "10초간 무응답"이라 원인 특정에도
  시간이 걸렸다. → 매니페스트의 리터럴 IP를 새 프로젝트 예약
  IP(terraform output 값)로 갱신하고 갱신 의무를 주석·체크리스트로
  명문화했다. 단 플레인 YAML이라 output을 자동 주입할 경로가 없어
  값은 여전히 복사본이며, output 참조 자동화는 미완 후속 과제다.
- **Cloud SQL import 충돌**: 애플리케이션(MLflow)이 먼저 기동해 스키마를
  자동 생성해 버린 상태에서 옛 데이터베이스를 import하려다 "relation
  already exists" 충돌이 났다. → 데이터베이스를 완전히 재생성한 뒤
  재import하는 순서로 해결했다.
- **quota 비대칭**: 새 프로젝트는 **PREEMPTIBLE**(Spot과 유사하게 저렴하지
  만 언제든 회수될 수 있는 VM 유형) quota가 0으로 리셋돼 있어, 이
  quota를 쓰는 batch-spot 노드풀이 자리를 못 잡고 계속 대기했다. → quota
  증설을 신청하는 대신, 여유가 넉넉한 N2 머신 계열로 노드풀 사양을
  전환해 회피했다.
- **실 tfvars 커밋 직전 차단**: 문서 갱신 PR(#419)에
  `terraform.tfvars.old-project.bak` — 옛 프로젝트의 **실사용 dev 설정
  전체(78줄)** — 가 섞여 들어갔다가 리뷰에서 Blocker로 잡혔다. 원인은
  두 가지의 결합이었다: ① `.gitignore`의 `*.tfvars` 패턴은 확장자가
  `.bak`인 백업 파일을 매치하지 못한다(로컬 tfvars를 `.bak`으로
  백업하는 순간 ignore가 뚫린다) ② 공유 워킹트리에서 `git add -A`를
  써서 의도하지 않은 파일까지 스테이징됐다. → `git rm --cached`로 추적
  해제하고, gitignore에 `terraform.tfvars.*`·`*.tfvars.bak` 패턴을
  보강했으며, 작업 규칙을 "명시적 파일 지정 add만 사용"으로 바꿨다.
  같은 리뷰에서 별도 진행 중이던 mlflow OAuth 정본화 작업의 미완
  스냅샷도 `add -A`로 쓸려 들어온 것이 발견돼 PR에서 분리했다(그
  작업이 나중에 완결된 형태로 #420 → PR #421이 된 것).
- **자동 생성 전제 리소스의 IAM 404**: `autoresearch-503903_cloudbuild`
  버킷은 원래 **첫 Cloud Build 실행 때 GCP가 자동 생성**하는
  리소스인데, dev root apply가 그 버킷에 IAM 바인딩
  (`google_storage_bucket_iam_member`)을 걸려다 아직 버킷이 없어
  `404 notFound`로 실패했다 → 버킷을 수동 생성해 해소. 신선
  프로젝트에서는 "무언가 자동 생성해 줄 것"을 전제로 짠 IAM 코드가
  그 전제가 아직 성립하기 전에 apply되면서 깨질 수 있다(Compute
  default SA는 반대로 compute API enable 시점에 자동 생성돼 있어 같은
  패턴인데도 문제가 없었다).

### 결과

- 2026-07-29 착수 → 2026-07-31 옛 프로젝트 삭제 요청까지 약 2일이
  걸렸다. 두 프로젝트를 동시에 운영하는 기간의 **이중 과금**(같은
  워크로드에 대해 두 프로젝트 모두 비용이 발생하는 것)을 최소화하려
  일부러 짧게 묶어 진행했다.
- 로그인·UI 접속·야간 배치 정상 동작까지 검증을 마친 뒤에만 옛 프로젝트를
  정리했고, 삭제 요청 후에도 30일 유예 기간을 남겨 롤백 가능성을
  확보했다. 옛 프로젝트 `ar-infra-501607`는 2026-07-31에
  **`DELETE_REQUESTED`** 상태로 전환했다 — 이 상태에서는 30일 안에
  `gcloud projects undelete`로 **프로젝트 자체**를 되살릴 수 있다. 다만 이것이
  리소스·데이터의 원상복구를 뜻하지는 않는다 — undelete가 보장하는 것은 프로젝트
  ID와 리소스 네임스페이스이고, 유예 기간 중 개별 리소스는 영구 삭제될 수 있다.
  이 이전에서는 결제 분리가 선행돼 Cloud SQL 인스턴스·GKE 노드가 이미 정지된
  상태였으므로 더욱 그렇다. **실질 롤백 경로는 undelete가 아니라 "옛 좌표로
  repo variables·backend를 되돌린 뒤 IaC 재적용 + 데이터 백업 복원"이다.**
- 이슈 #404는 2026-07-31에 "Phase 0~6 전부 종료(야간 파이프라인
  e2e success·rotate 적용·verify 전부 통과 포함)"로 완결 기록되고
  닫혔다. 이전 자체에서 파생된 재발 방지 조치 7건(plan 파일 재사용
  회피, admin-apply ROOTS 순서 교정 #442, DB 비밀번호 URI-safe
  하드닝 #444, OAuth SM 정본화+검증 스크립트 #445, batch KSA IaC
  편입 #428, 첫 apply 닭-달걀 구조 검토 #440/#446, quota 실측
  선행)와 전 문서 감사(#435, 32건)는 이 이슈와 별도로 종결됐다.
- 아래 Phase별 절차는 이번에 겪은 문제를 다음 이전(staging/prod 신설,
  클러스터 재구축 등)에서는 재발하지 않도록 정리한 실행 매뉴얼이다.

---

## Phase 0 — 새 프로젝트 부트스트랩

사용자(콘솔/조직 관리자) 선행:

1. 프로젝트 생성 + 결제 연결, 작업 계정에 owner 부여
   (조직이 다르면 IAM 전파에 수 분 — `gcloud projects describe`로 확인)
2. **quota 실측 먼저, 신청은 그 다음**: 새 프로젝트 기본 한도가 옛것보다 후할
   수 있다(#404 실측: E2 24·N2 200·SSD 500). 특히 `PREEMPTIBLE_CPUS`가 0이면
   Spot이 일반 계열 quota를 소모한다(#422의 근거) — 한도가 부족하면 증설
   신청보다 **머신 계열 이전**(quota 풀 갈아타기)이 승인 대기 없는 대안.

운영자:

3. API enable — `TERRAFORM_BOOTSTRAP.md`의 목록 + **`run.googleapis.com`**
   (#404에서 누락돼 Cloud Run 생성 실패)
4. bootstrap apply — **기존 local state를 재사용하면 기존 프로젝트 리소스를
   파괴하려는 plan이 나온다**: `terraform -chdir=terraform/bootstrap workspace
   new <project-id>` 로 분리하고 `<project-id>.tfvars` + `-var-file`로 실행.
   state 버킷 이름은 전역 유니크 — 필수 변수라 값 없이는 멈춘다(#414).
5. `<project>_cloudbuild` 버킷은 첫 빌드 전엔 없다 — dev root의 버킷 IAM이
   404 나면 수동 생성(`gcloud storage buckets create gs://<project>_cloudbuild
   --location=US`) 후 재시도.

## Phase 1 — 코드·변수 전환 (순서가 생명)

- backend 버킷명(전 root `versions.tf` + workflow 경로 + admin_apply SA IAM),
  deploy manifest 좌표는 PR로 교체.
- **infra repo variables는 머지 "직후"** 교체(GCP_PROJECT_ID·WIF_PROVIDER_ID·
  CI_SA_EMAIL, 이후 DEV/ADMIN_APPLY_SA_EMAIL·WIF_POOL_ID) — 먼저 바꾸면 열린
  PR들의 plan이 옛 프로젝트 기준으로 깨진다.
- **airflow repo의 dev-gke environment 변수는 머지 "이전"** 교체 — 그 repo는
  main 머지가 곧 자동 배포라서 순서가 infra와 반대다(#404 실측).
- 과거 실측 기록 문서(날짜 박힌 검증 절)는 치환 대상이 아니다 — 사실 기록은
  옛 값 유지가 옳다(#419 리뷰 교훈).

## Phase 2 — dev root apply

- **첫 apply는 로컬 break-glass가 강제된다**: apply 전용 SA(dev-apply·
  admin-apply)를 dev root 자신이 만들기 때문(순환, #341 설계 — plan 잡은
  성공하고 apply 잡만 init 실패하는 형태로 발현. 구조 재검토는 #440).
- CI가 만든 plan 파일은 **플랫폼 종속**이라 로컬(mac)에서 apply 불가
  ("Inconsistent dependency lock file") — 로컬에서 plan부터 다시 만들되,
  CI 입력 동일성은 TF_VAR 환경변수 재현 + 로컬 `terraform.tfvars` 임시 제거로
  확보하고, 리소스 목록 diff로 CI plan과 일치 검증 후 apply.
- 첫 apply에서만 드러나는 것들: GKE WI pool 전파 지연, SA 생성 분당 quota
  429(재시도로 해소), Cloud Run 서비스는 대상 이미지가 새 AR에 먼저 복사돼
  있어야 생성 성공, `<project>_cloudbuild` 버킷 IAM 바인딩은 그 버킷이
  첫 빌드 때 자동 생성되는 리소스라 **404 notFound** — 버킷을 수동
  선생성해야 통과.

## Phase 3 — admin roots apply

ROOTS 순서는 `apply.yml`의 `ADMIN_ROOTS`가 정본(#451 — 옛 `admin-apply.yml`
정의를 이관. 순서 원칙은 namespace 소유 root 먼저·argocd 마지막이며, #436은
순서가 아니라 root 내부 `depends_on` 간선 보강이었다). Phase 2(dev root apply)가 CI로
전환된 뒤에는 `apply.yml`을 `scope: admin`으로 dispatch한다 — admin root는
Phase 2가 만든 GKE 클러스터가 이미 있어야 plan이 되므로, `scope: all`로
같이 돌리면 admin root plan 실패가 (이미 끝난) dev root apply까지 막지
않도록 `scope`를 명시적으로 좁힌다. 신선 클러스터 한정 선행 2단계:

1. CRD 의존 root는 operator만 로컬 `-target` 선적용:
   `elastic-k8s → helm_release.eck_operator`, `argocd-k8s → helm_release.argo_cd`
   (CRD 없이는 kubernetes_manifest CR의 **plan 자체가 불가**)
2. 아래 Secret 인벤토리의 "선주입 필요" 항목을 넣은 뒤 CI 실행 — oauth-proxy류
   Deployment는 Secret 없이는 rollout 대기 10분 타임아웃으로 apply가 실패한다.
3. `gke-team-access`는 CI 제외(#314) — 로컬 apply로 마무리.
4. 로컬 tfvars 함정: 모든 admin root의 로컬 `terraform.tfvars`에서 옛
   project_id를 일괄 갱신하고 시작할 것(4회 재발 이력이 있는 함정).

## Secret 인벤토리 (operator 주입 — 수기 목록 금지, ns 전수 순회로 재확인)

이전 시 복사 대상 식별은 아래 표가 아니라 **명령으로 시작**한다(#404에서 argocd
ns가 수기 목록에서 빠져 ArgoCD 로그인이 깨진 채 넘어갔다):

```bash
# 옛 클러스터의 모든 ns에서 operator 주입 Secret 후보를 나열
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  kubectl -n "$ns" get secrets -o json | python3 -c "
import json,sys
for it in json.load(sys.stdin)['items']:
    m=it['metadata']
    if it['type']=='Opaque' and not m.get('ownerReferences') \
       and 'helm.sh' not in str(m.get('labels','')):
        print('$ns', m['name'])"
done
```

2026-07-30 기준 실측 인벤토리(변하면 위 명령이 정본):

| ns | Secret | 소유/절차 문서 | 이전 방식 |
|---|---|---|---|
| elastic | `kibana-oauth` | elastic-k8s README | verbatim 복사 |
| mlflow | `mlflow-oauth` | mlflow-k8s README | verbatim 복사 |
| mlflow | `mlflow-db` | mlflow-k8s README | **환경 재구성** — 새 SQL IP + SM 비번, 비번은 **URL-인코딩**(mlflow가 URI에 원문 삽입 — 미인코딩 시 "Invalid IPv6 URL" 크래시, 근본 해소는 #438) |
| monitoring | `grafana-google-oauth`, `grafana-admin-credentials`, `alertmanager-slack-config` | GRAFANA runbook | verbatim 복사 |
| airflow | `airflow-web-oauth`, `airflow-email-alerts`, `airflow-fernet-key`, `airflow-webserver-secret-key`, `autoresearch-airflow-env` | airflow repo 문서 | verbatim 복사 |
| airflow | `airflow-metadata-db`, `airflow-broker-url` | airflow repo `docs/cloud-sql-metadata.md` | **환경 재구성** — 새 SQL IP + SM app 비번(URL-quote) |
| autoresearch | `autoresearch-serving-redis` | TEAM runbook | **환경 재구성** — 새 Redis discovery endpoint |
| argocd | `argocd-google-oidc` | argocd-k8s README | verbatim 복사(#404에서 누락됐던 항목) — README가 전제하는 Secret Manager 정본 `argocd-google-oidc-client-{id,secret}`이 실제로는 빈 채로 남아 있던 것을 뒤늦게 발견해, 클러스터에 이미 들어가 있던 실값을 SM으로 역주입해 문서-실제 정합을 맞췄다(PR #429). SM secret 리소스 자체는 `terraform/envs/dev`의 `google_secret_manager_secret.argocd_google_oidc_client`로 편입돼 `prevent_destroy` 보호를 받는다(#494) — 다음 재구축에서 dev root apply만으로 이 컨테이너 2종이 생성된다. 이름은 `autoresearch-dev-` 프리픽스 규칙의 의도적 예외(라이브 이름 유지, import 단순화)로 남는다. 값(version)은 여전히 Terraform 밖이라 이 표의 절차대로 채운다 |

- airflow 첫 helm 설치 시, 복사해 둔 chart-관리 Secret(fernet-key·
  webserver-secret-key 등)은 **helm 소유권 입양**이 필요하다:
  `app.kubernetes.io/managed-by=Helm` label + `meta.helm.sh/release-name/-namespace`
  annotation. 첫 설치 자체가 CI에서 실패하는 문제는 airflow#196.
- OAuth client는 프로젝트 종속 — 재발급 시 id/secret **한 쌍**을 SM 정본에
  먼저 넣고, 주입 → `rollout restart` → **프리픽스/해시 검증**까지가 한 절차다
  ("재발급 ≠ 반영" 함정, 검증 자동화는 #439).
- 주입 스크립트/절차의 세부 함정 4건(#421·#445 리뷰에서 잡혀 절차에 반영됨):
  - **빈 정본 무음 통과**: SM 컨테이너만 있고 version이 0개인 상태에서
    `gcloud secrets versions access latest ... > 파일` 루프를 돌리면,
    access는 실패해도 리다이렉션이 **0바이트 파일**을 만들고 파이프
    종료 코드는 마지막 명령(`tr`)의 0이라 루프가 그대로 진행돼, 결국
    `client-id: ""`인 K8s Secret이 "성공"으로 만들어진다 — oauth2-proxy는
    기동되지만 로그인만 원인 불명으로 막힌다. → 각 파일에 `test -s`
    가드(빈 파일이면 `versions add` 안내와 함께 중단).
  - **cookie-secret 비멱등**: 주입 블록을 갱신 때 그대로 재실행하면
    cookie-secret이 무조건 새로 생성돼 **전원 재로그인**을 유발한다. →
    기존 K8s Secret의 값을 보존하고 없을 때만 생성하는 멱등 블록으로.
  - **검증 사각**: 해시 대조가 client-secret만 보면, 정작 #404 사고의
    축이었던 client id 불일치(재발급 쌍 원칙 위반)는 검증을 **통과**한
    채 `invalid_client`로 남는다. → id/secret 두 키 모두 대조.
  - **`envFromSecret`은 기동 시에만 읽힌다**: Secret을 갱신해도 가동
    중인 파드는 옛 값을 물고 있다 — `rollout restart`까지가 주입의
    일부인 이유. `kubectl create secret`도 기존재 시 AlreadyExists로
    실패하므로 `--dry-run=client -o yaml | kubectl apply -f -` 멱등
    패턴을 쓴다.

## Phase 4~5 — 데이터 이전

- GCS: `gcloud storage rsync -r`(서버사이드). BQ: `bq cp --force`(cross-project).
- AR 이미지: digest 보존 복사(`docker pull --platform linux/amd64` → tag →
  push, **digest 대조로 검증**). 경로 교체 PR보다 복사가 먼저다.
- **Cloud SQL: 반드시 "앱 scale=0 → export → import → 재기동" 순서**.
  #404에서 mlflow가 먼저 떠서 빈 스키마를 만들었고 import가
  `relation "alembic_version" already exists`로 충돌 — DB delete/create 후
  재import로 복구했다(DB delete는 커넥션 소멸 대기 재시도 필요).
  export/import는 SQL SA에 대상 버킷 objectAdmin 부여가 선행.
- feast registry.db는 복사본이 옛 BQ 좌표를 품는다 — 복사 후 **feast apply
  1회 재실행**으로 재생성.
- ES 스냅샷 저장소·SLM은 클러스터 밖 설정이 아니라 **ES API 등록**이다 —
  새 클러스터에서 `_snapshot`/`_slm` 재등록 + 즉시 1회 실행으로 검증
  (KIBANA/elastic-k8s README 참조).

## Phase 6 — 검증·전환·정리

1. 스모크: 수동 DAG 1회 + **야간 스케줄 자연 실행 관찰**(수동과 다른 경로를
   탄다 — #404에서 batch KSA 부재가 야간에만 드러났다), UI 5종 Google 로그인,
   serving 응답.
2. **내부 UI FQDN 터널 접속 확인**: Airflow/MLflow 등 내부 ILB 매니페스트의
   `loadBalancerIP`가 **리터럴로 하드코딩**돼 있으면, DNS(Terraform 소유)는
   새 프로젝트 예약 IP를 가리키는데 Service는 옛 프로젝트 IP를 그대로 가리켜
   터널이 전면 불가해진다(#404에서 Airflow·MLflow 둘 다 발생, #425/#426).
   증상은 connection refused가 아니라 **10초 무응답**(bastion→대상 구간이
   죽은 것)이라 워크로드부터 보면 시간을 버린다. 판별 3종을 같이 대조:
   ① `kubectl get svc -o jsonpath='{.spec.loadBalancerIP}'`(매니페스트가 **요청한**
   IP)와 `{.status.loadBalancer.ingress[0].ip}`(실제 **할당된** IP)를 함께 본다.
   두 값이 다르면 요청이 반영되지 않은 것이고, 같더라도 DNS·예약 IP와 어긋날 수
   있으므로 아래 ②③과 대조해야 한다
   ② `gcloud dns record-sets list` rrdatas
   ③ `gcloud compute addresses list` status(`RESERVED`=미사용,
   `IN_USE`=정상). 해결은 매니페스트의 리터럴 IP를 새 예약
   IP(`terraform output mlflow_ilb_ip`/`airflow_ilb_ip` 값)로 갱신.
   **주의: 플레인 YAML이라 output 자동 주입 경로가 없어 값은 여전히
   복사본이다** — 다음 이전에서도 이 갱신은 체크리스트로 챙겨야 하는
   수동 단계다(output 참조 자동화는 kustomize/ArgoCD plugin 등 별도
   설계가 필요한 미완 후속 과제).
3. OAuth 반영 검증: 5종 K8s Secret의 client id 프로젝트 번호 프리픽스가 새
   프로젝트인지 확인(#439 스크립트).
4. 옛 프로젝트 정리: 결제 분리(사실상 정지, 재연결로 롤백 가능) → 관찰 기간 →
   shutdown(30일 유예 — `gcloud projects delete` 직후 상태는
   `DELETE_REQUESTED`, `gcloud projects undelete`로 유예 내 **프로젝트 복원**
   가능 — 리소스·데이터 복구는 보장되지 않으므로 실질 롤백은 IaC 재적용 +
   백업 복원으로 계획한다).
   정리 전 하드 게이트는 **세 가지**다(이번 이전 실측 기준).
   - **OAuth client 의존 0** 재확인(`scripts/verify-oauth-clients.sh`).
   - **주기 워크로드가 최소 1회 자연 실행되어 성공**했는지. 이번 이전에서
     batch KSA 부재(#427)는 수동 스모크가 아니라 **야간 스케줄이 자연 실행될
     때에야** 드러났다. 즉 "수동 트리거 성공"은 이 게이트를 대신하지 못한다.
   - **옛 좌표를 바라보는 도구가 필요한 미완 진단이 없는지**. 결제를 분리하면
     옛 프로젝트 state 접근이 `UserProjectAccountProblem`으로 막혀, 그 시점
     이후의 진단은 `kubectl` 실환경 조회와 정적 코드 검색만으로 해야 한다
     (#427 진단이 실제로 그랬다). 결제 분리는 되돌릴 수 있지만 재연결에
     시간이 걸리므로, 미해결 조사 항목이 있으면 분리를 미룬다.
5. 다른 클론·워크트리의 stale backend 캐시는 `git pull` +
   `terraform init -reconfigure` — 옛 버킷 403("billing account absent")이
   보이면 이 케이스다.

## 알려진 함정 압축 목록 (#404 실측)

닭-달걀(첫 apply 로컬), plan 플랫폼 종속, CRD 선적용, ns 의존 간선 누락(#436),
Secret 선주입, 수기 인벤토리 누락(argocd), URL-인코딩 비번(#438), SQL 선기동
충돌, airflow env 변수 선교체(자동배포), 첫 helm 설치 CI 부재(airflow#196),
helm Secret 입양, quota 비대칭(PREEMPTIBLE 0), cloudbuild 버킷 부재, Cloud Run
API 누락, "재발급 ≠ 반영"(#439), 코드 밖 수동 오브젝트 누락(batch KSA — #427로
IaC 편입 완료, 재발 시 같은 원칙 적용), 내부 UI `loadBalancerIP` 하드코딩과
DNS 예약 IP 불일치(#425→#426 — 리터럴 값 갱신으로 해소, output 자동 참조는
미완이라 다음 이전에서도 수동 갱신 필요), Secret Manager 컨테이너의 IaC 누락
(`argocd-google-oidc-client-{id,secret}`이 라이브에만 있고 Terraform에 정의가
없어 재구축에서 빠지던 문제 — 이름 프리픽스가 다른 4개 서비스와 달라 육안으로
구분됐다. `terraform/envs/dev`에 편입해 해소(#494)), 옛 프로젝트 참조 잔재(vault helm-values 2곳·
gke_ctr_retrain.tf import 지시 주석 — 실행 지시라 다음 재구축에서 삭제 요청된
프로젝트를 대상으로 삼게 된다).
