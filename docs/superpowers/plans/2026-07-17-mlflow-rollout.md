# MLflow 구현 순서 (#91 설계 기반)

> 설계: `docs/superpowers/specs/2026-07-17-mlflow-operating-design.md`
> 각 단계는 이슈→브랜치→Draft PR→검증→squash. 리소스 생성 apply는 사용자 승인 후.

## 순서와 작업 분해

### #92 — GCS artifact bucket
- [ ] `storage.tf`: `autoresearch-dev-mlflow-artifacts` 버킷(uniform access, public access 차단, soft_delete, 라벨)
- [ ] MLflow GSA에 `storage.objectAdmin` + `storage.legacyBucketReader`(#204 교훈)
- [ ] 문서: TERRAFORM_DEV 버킷 표, CHANGE_HISTORY
- 검증: `fmt/validate`, targeted plan(add only). 롤백: 버킷 리소스 revert(force_destroy=false라 데이터 보호)

### #93 — Cloud SQL DB/user
- [ ] `cloud_sql.tf`: `google_sql_database`(`mlflow`) + `google_sql_user`(`mlflow`) + `random_password`
- [ ] `secret_manager.tf`: MLflow DB secret + version(random_password) + resource-level `secretAccessor`(MLflow GSA)
- [ ] MLflow GSA에 `cloudsql.client`
- [ ] 문서: TERRAFORM_DEV DB 표, CHANGE_HISTORY
- 검증: plan(add only, 기존 인스턴스 in-place 없음 확인). 보안: 비번은 sensitive·Secret Manager만

### #94 — tracking server 배포 (앱 이미지 조율 필요)
- [ ] `terraform/admin/mlflow-k8s`(신규 root): namespace `mlflow` + KSA `mlflow`(WI) + NetworkPolicy(egress 화이트리스트)
- [ ] envs/dev: MLflow GSA 신설 + WI 바인딩(`svc.id.goog[mlflow/mlflow]`)
- [ ] `deploy/mlflow`: umbrella chart(community mlflow pin) + values(앱 GAR 이미지, backendStoreUri=secret, artifactRoot=gs://, serviceAccount WI, `--serve-artifacts`)
- [ ] `argocd-k8s`: AppProject destination `mlflow` 추가 + Application `mlflow`(manual sync, CreateNamespace=false)
- [ ] 앱 팀과 GAR 이미지 경로/태그 확정
- 검증: apply 후 ArgoCD Application Synced/Healthy, pod Running, UI 내부 접근(port-forward), 실험 1건 기록→artifact GCS 저장 확인
- 보안: UI 외부 노출 0 확인, WI 신원 확인, GCS 자격이 클라이언트에 없음 확인

### #95 — 운영 runbook
- [ ] `docs/MLFLOW_OPERATIONS_RUNBOOK.md`: 접속(port-forward/ILB), 실험/모델 등록 흐름, DB/artifact 백업·복구, 권한·시크릿 로테이션, 장애 대응
- [ ] docs/README 인덱스 등록

## 공통 원칙
- 모든 PR에 관련 md 동시 갱신(한글). 보안 최우선(외부 노출·IAM 확대·시크릿 노출 diff 확인).
- 실 리소스 apply는 사용자 명시 승인 후. plan 결과는 CI(플랜 워크플로 요약, #211 반영).
