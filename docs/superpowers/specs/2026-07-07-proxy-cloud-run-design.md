# dev proxy Cloud Run 서비스 설계 (#27)

> Status: Done (구현·apply 완료) | Issue: #27 | Last Updated: 2026-07-09

## 목적

`proxy/Dockerfile`(앱 저장소 `SKYAHO/Autoresearch`) 기반 proxy 컨테이너를 dev 환경의
Cloud Run 서비스로 배포해, collector가 **IAM 인증**으로 호출하는 HTTP 엔드포인트를
제공한다. 트래픽은 하루 수 회 수준이므로 `min instances = 0` 기준 유휴 비용 0을
목표로 한다.

## 전제 (이슈 #27 참고 사항)

- 컨테이너: 포트 `8080`, `uvicorn app:app` 실행, 헬스체크 `GET /health`
- 호출 주체(collector)의 서비스 계정은 **미확정** — 확정 시 invoker binding 추가
- 이미지 소스는 앱 저장소의 `proxy/Dockerfile`

## 설계 결정

| 결정 | 내용 | 이유 |
|---|---|---|
| 리소스 | `google_cloud_run_v2_service` (GA) | v1 대비 최신 스펙(probe, scaling 블록), google provider GA 지원 |
| 서비스 이름 | `autoresearch-dev-proxy` | 저장소 네이밍 규칙 `${resource_prefix}-proxy` |
| 리전 | `asia-northeast3` | 기존 dev 리소스와 동일 |
| 이미지 경로 | `asia-northeast3-docker.pkg.dev/<project>/autoresearch-dev-docker/proxy:<tag>` 또는 `proxy@sha256:...` | 기존 AR 리포 재사용. `var.proxy_image`가 비어 있으면 버전 태그 예시(`proxy:dev-20260708-001`)로 구성 |
| 스케일링 | min 0 / max 1 (`var.proxy_max_instances`) | 유휴 비용 0, dev 트래픽(일 수 회)에 충분 |
| 리소스 크기 | 1 vCPU / 512Mi, `cpu_idle = true` | 최소 비용. CPU는 요청 처리 중에만 과금 |
| 런타임 SA | 전용 `autoresearch-dev-proxy` SA, **role 없음** | 최소 권한(YAGNI). proxy가 GCP 리소스를 쓰게 되면 그때 리소스 수준으로 부여 |
| 인증 | public access 없음. `roles/run.invoker`를 `var.proxy_invoker_members`에만 부여 | collector 주체 미확정 → 기본값 빈 목록(아무도 호출 불가). 확정 시 tfvars에 추가 |
| ingress | 기본 `INGRESS_TRAFFIC_INTERNAL_ONLY` (`var.proxy_ingress`) | collector가 같은 프로젝트 VPC(GKE)에서 호출한다고 가정. 외부 호출이 확정되면 `INGRESS_TRAFFIC_ALL`로 변경(IAM 인증은 유지) |
| 헬스체크 | startup/liveness probe `GET /health`:8080 | 이슈 완료 조건 |
| deletion_protection | `false` (dev) | 다른 dev 리소스와 동일 정책. PR에 명시 |
| 필요 API | `run.googleapis.com` 추가 (수동 활성화) | `google_project_service` 미사용 정책 유지 |

## 이미지 빌드/배포 경로

CI push 권한은 별도 배포 이슈에서 결정하므로, 이번 범위는 **수동 빌드/push**를
문서화한다.

```bash
# 앱 저장소에서 (인증: gcloud auth configure-docker asia-northeast3-docker.pkg.dev)
docker build -t asia-northeast3-docker.pkg.dev/<project>/autoresearch-dev-docker/proxy:dev-20260708-001 proxy/
docker push asia-northeast3-docker.pkg.dev/<project>/autoresearch-dev-docker/proxy:dev-20260708-001
```

**순서 제약**: 이미지가 AR에 존재해야 Cloud Run revision 배포(apply)가 성공한다.
plan은 이미지 없이도 통과하므로 PR 머지는 가능하고, apply만 push 이후에 한다.

**재배포 원칙**: 같은 `:latest` 태그를 다시 push해도 Terraform 설정의 이미지 문자열은
변하지 않는다. 새 revision을 Terraform으로 롤아웃하려면 `proxy_image`를 새 버전 태그
또는 digest로 변경한 뒤 apply한다.

## 비목표 (Non-goals)

- CI 기반 이미지 빌드/배포 자동화 (별도 이슈)
- prod/staging 구성, 커스텀 도메인, Cloud Armor
- proxy 애플리케이션 코드 변경 (앱 저장소 범위)

## 비용

- min 0이므로 유휴 비용 0. 요청 시에만 vCPU/메모리 과금 (일 수 회 × 짧은 처리 = 사실상 무시 가능)
- 콜드 스타트 지연(수 초)은 dev 트래픽 특성상 허용

## 리스크 / 롤백

- **이미지 미존재 상태 apply 실패** → 위 순서 제약 문서화로 대응
- **invoker 미확정** → 기본 접근 불가 상태로 배포되므로 안전. collector SA 확정 시 tfvars 추가 후 apply
- **internal ingress로 인한 호출 불가** — collector가 VPC 밖이라면 `proxy_ingress`를 `INGRESS_TRAFFIC_ALL`로 변경 (IAM 인증 유지)
- 롤백: 리소스 삭제(`terraform destroy -target` 또는 코드 제거 후 apply). 상태ful 데이터 없음
