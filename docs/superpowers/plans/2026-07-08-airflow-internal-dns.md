# Airflow UI 내부 노출 구현 계획 (#48)

> Status: Done (PR #51 merged, 2026-07-08 apply 완료) | Issue: #48 | Spec: `../specs/2026-07-08-airflow-internal-dns-design.md`

## 작업 순서

1. `terraform/envs/dev/dns.tf` 신설: 내부 고정 IP(`SHARED_LOADBALANCER_VIP`) +
   private zone(`dev.autoresearch.internal`) + `airflow.` A 레코드
2. `variables.tf`(`internal_dns_domain`), `locals.tf`(`dns.googleapis.com` API),
   `outputs.tf`(`airflow_ilb_ip`, `airflow_internal_fqdn`), tfvars.example
3. `terraform/admin/airflow-k8s`: NetworkPolicy ingress에
   `var.ui_ingress_source_cidr`(기본 dev subnet) → 8080 허용 추가
4. 문서: `docs/TERRAFORM_DEV.md` #48 섹션(Helm values 가이드 + 접속 방법),
   `docs/GKE_CLUSTER_ACCESS.md` UI 접근 원칙 갱신, 필수 API 표 dns 추가
5. 검증: fmt/validate(dev + airflow-k8s), `git diff --check`
6. Draft PR → 셀프 리뷰 → Ready

## 검증 체크리스트

- [x] fmt/validate 통과 (envs/dev + admin/airflow-k8s)
- [x] dev plan: 3 to add (address, zone, record), 기존 리소스 변경 없음
- [x] airflow-k8s plan: NetworkPolicy in-place update 1건
- [x] 문서 갱신

## Apply 후 확인 (머지 후, 사용자 승인 하에)

1. dev root apply → `airflow_ilb_ip`, `airflow_internal_fqdn` output 확인
2. airflow-k8s root apply (관리자 네트워크에서)
3. 앱 저장소에서 Helm values 적용 (LoadBalancer + internal 어노테이션 + `loadBalancerIP` + `externalTrafficPolicy: Local`)
4. Bastion(#47)에서 `curl http://airflow.dev.autoresearch.internal:8080/health` 성공
5. 로컬 브라우저: Bastion SOCKS(`-D 1080`, 원격 DNS) 상태에서 UI 접속 확인

## 선행/후속

- 선행: #47 Bastion (브라우저 경로), #32 Airflow namespace (적용 대상)
- 후속: #54/#55 OAuth 자격증명 Secret Manager 저장 완료 (#49는 close — redirect URI는 `http://localhost:8080` 기준, Google이 `.internal` 거부)
