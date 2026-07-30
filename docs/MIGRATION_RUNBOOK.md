# 프로젝트 이전/재구축 실행 Runbook

> #437. 2026-07-29~30 GCP 프로젝트 이전(#404, `ar-infra-501607` →
> `autoresearch-503903`)의 실측 절차를 재사용 가능한 실행 문서로 정리했다.
> 결정 요약은 `CHANGE_HISTORY.md`(2026-07-29~30 항목), 개별 함정의 상세 근거는
> 이슈 #404 진행 기록을 본다. **이 문서만 위에서 아래로 따라가면 #404에서
> 실제로 겪은 누락·장애가 절차상 재발하지 않는 것**이 목표다.

대상 시나리오: 다른 GCP 프로젝트로의 전면 이전, 신규 환경(staging/prod) 신설,
클러스터 전면 재구축. GCP는 프로젝트 간 리소스 이동을 지원하지 않으므로 전량
IaC 재적용 + 데이터 복사가 기본 전략이다.

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
  있어야 생성 성공.

## Phase 3 — admin roots apply

ROOTS 순서는 admin-apply.yml이 정본(#436 — ns 소유 root 선행). 신선 클러스터
한정 선행 2단계:

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
| argocd | `argocd-google-oidc` | argocd-k8s README | verbatim 복사(#404에서 누락됐던 항목) |

- airflow 첫 helm 설치 시, 복사해 둔 chart-관리 Secret(fernet-key·
  webserver-secret-key 등)은 **helm 소유권 입양**이 필요하다:
  `app.kubernetes.io/managed-by=Helm` label + `meta.helm.sh/release-name/-namespace`
  annotation. 첫 설치 자체가 CI에서 실패하는 문제는 airflow#196.
- OAuth client는 프로젝트 종속 — 재발급 시 id/secret **한 쌍**을 SM 정본에
  먼저 넣고, 주입 → `rollout restart` → **프리픽스/해시 검증**까지가 한 절차다
  ("재발급 ≠ 반영" 함정, 검증 자동화는 #439).

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
2. OAuth 반영 검증: 5종 K8s Secret의 client id 프로젝트 번호 프리픽스가 새
   프로젝트인지 확인(#439 스크립트).
3. 옛 프로젝트 정리: 결제 분리(사실상 정지, 재연결로 롤백 가능) → 관찰 기간 →
   shutdown(30일 유예). **정리 전 옛 프로젝트 소속 OAuth client 의존이 0인지
   재확인**이 유일한 하드 게이트.
4. 다른 클론·워크트리의 stale backend 캐시는 `git pull` +
   `terraform init -reconfigure` — 옛 버킷 403("billing account absent")이
   보이면 이 케이스다.

## 알려진 함정 압축 목록 (#404 실측)

닭-달걀(첫 apply 로컬), plan 플랫폼 종속, CRD 선적용, ns 소유 순서(#436),
Secret 선주입, 수기 인벤토리 누락(argocd), URL-인코딩 비번(#438), SQL 선기동
충돌, airflow env 변수 선교체(자동배포), 첫 helm 설치 CI 부재(airflow#196),
helm Secret 입양, quota 비대칭(PREEMPTIBLE 0), cloudbuild 버킷 부재, Cloud Run
API 누락, "재발급 ≠ 반영"(#439), 코드 밖 수동 오브젝트 누락(batch KSA — #427로
IaC 편입 완료, 재발 시 같은 원칙 적용).
