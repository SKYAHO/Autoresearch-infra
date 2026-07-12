# private.googleapis.com 기반 egress 443 하드닝 설계

> 작성: 2026-07-13
> 배경: PR #135 리뷰 제안 — vault namespace의 egress `0.0.0.0/0:443`은
> secret 제어면의 deny-by-default 취지를 약화시킴

## 목적

Google API 트래픽을 고정 VIP 대역(`private.googleapis.com`,
199.36.153.8/30)으로 유도해, Google API만 필요한 namespace의 egress를
`0.0.0.0/0:443`에서 고정 CIDR로 좁힌다.

## 범위 결정 (namespace별)

| namespace | 443 목적지 | 결정 |
|---|---|---|
| vault | Cloud KMS(googleapis), Kubernetes API | **완전 축소** — 199.36.153.8/30:443 + services CIDR:443(kubernetes.default VIP) |
| argocd | GitHub(외부) + Kubernetes API | `0.0.0.0/0:443` **유지** — GitHub IP는 고정 CIDR로 관리 불가. 사유 주석/문서화 |
| airflow | OpenRouter(외부), Cloud Run proxy(run.app), Google APIs | `0.0.0.0/0:443` **유지** — 외부 API 의존. 사유 주석/문서화 |

당초 리뷰 답변에서 "3개 일괄 축소"를 제안했으나, argocd/airflow는 외부
endpoint 의존이 확인되어 vault만 축소한다. DNS zone은 VPC 공용 기반이므로
이후 Google-API-전용 namespace가 생기면 같은 방식으로 축소한다.

## 메커니즘

1. **dev root `dns.tf`**: VPC private zone `googleapis.com.` 추가
   - A `private.googleapis.com.` → 199.36.153.8~11
   - CNAME `*.googleapis.com.` → `private.googleapis.com.`
   - PGA(subnet Private Google Access, 활성)와 기존 default route로
     199.36.153.8/30 경로는 이미 성립한다. `restricted.googleapis.com`
     (VPC-SC용)이 아닌 `private.googleapis.com`(전체 API 지원)을 쓴다.
2. **vault-k8s**: egress `0.0.0.0/0:443` → `199.36.153.8/30:443` 교체,
   services CIDR 규칙에 443 추가(kubernetes.default VIP — pre-DNAT 평가).

## 영향 분석 (VPC 전체 DNS 변경이므로)

| 워크로드 | 영향 | 근거 |
|---|---|---|
| airflow/argocd pods | 없음 (경로만 VIP로 변경) | egress `0.0.0.0/0:443` 유지, 199.36.153.x도 포함됨 |
| GKE 노드 이미지 pull | 없음 | `pkg.dev`/`gcr.io`는 zone 범위 밖(googleapis.com만 override) |
| GKE 노드 ↔ control plane | 없음 | master private endpoint, googleapis.com 미사용 |
| metadata/WI | 없음 | `metadata.google.internal`, link-local — zone 범위 밖 |
| Cloud SQL | 없음 | private services CIDR 직결 |
| Cloud Run proxy 호출 | 없음 | `run.app`은 zone 범위 밖 |
| bastion/기타 VM | 경로만 변경 | gcloud 등 googleapis 호출이 VIP 경유로 전환 (PGA로 동작 동일) |

## 검증 기준

1. dev root apply 후: vault pod에서 `cloudkms.googleapis.com` 해석 결과가
   199.36.153.8~11 (VPC 전체 적용 확인)
2. vault-k8s apply 후: pod 재기동 → auto-unseal 정상(Sealed false) —
   KMS 경로가 새 VIP + 좁힌 egress로 동작한다는 증거
3. Kubernetes auth 로그인/secret 읽기 재검증 (K8s API VIP:443 경로)
4. 회귀 확인(#122 교훈 체크리스트): airflow batch WI metadata/GCS 접근,
   ArgoCD Application refresh(GitHub 접근) 정상
5. 두 root 최종 plan No changes

## 롤백

- vault-k8s: egress 규칙을 `0.0.0.0/0:443`으로 되돌려 apply (in-place)
- dev root: DNS zone/record 제거 apply — 제거 시 TTL(300s) 이내에 공개 IP
  해석으로 복귀. 두 변경 모두 노드 재생성/리소스 교체 없음
