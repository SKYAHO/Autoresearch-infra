# 운영 문서 안내

이 디렉터리는 AutoResearch dev 인프라를 운영할 때 사람이 직접 참고하는 문서를
둔다. 과거 작업별 상세 spec/plan은 현재 운영 절차와 분리하고, 완료된 결정은
`CHANGE_HISTORY.md`에 요약한다.

## 먼저 볼 문서

| 상황 | 문서 |
|---|---|
| 지금까지 만든 dev 인프라 전체 구성을 빠르게 파악 | [`INFRASTRUCTURE_SUMMARY.md`](INFRASTRUCTURE_SUMMARY.md) |
| 팀원에게 GKE, Bastion, Airflow/Grafana UI 접속 방법을 안내 | [`TEAM_OPERATIONS_RUNBOOK.md`](TEAM_OPERATIONS_RUNBOOK.md) |
| Grafana에서 GKE/Airflow/앱 상태 점검, 앱 메트릭 e2e 검증 확인 | [`GRAFANA_OPERATIONS_RUNBOOK.md`](GRAFANA_OPERATIONS_RUNBOOK.md) |
| ArgoCD 접속, sync/diff/rollback, 장애 대응, 임의 워크로드 실배포 검증 확인 | [`ARGOCD_OPERATIONS_RUNBOOK.md`](ARGOCD_OPERATIONS_RUNBOOK.md) |
| Argo Rollouts promote/abort/rollback 등 점진 배포 운영 | [`ROLLOUTS_OPERATIONS_RUNBOOK.md`](ROLLOUTS_OPERATIONS_RUNBOOK.md) |
| Kibana/ELK 로그 검색·운영 절차 확인 | [`KIBANA_OPERATIONS_RUNBOOK.md`](KIBANA_OPERATIONS_RUNBOOK.md) |
| Vault 접속·시크릿 운영 절차 확인 | [`VAULT_OPERATIONS_RUNBOOK.md`](VAULT_OPERATIONS_RUNBOOK.md) |
| dev Terraform 리소스, 변수, output, apply 절차 확인 | [`TERRAFORM_DEV.md`](TERRAFORM_DEV.md) |
| Prometheus/Grafana 운영 모니터링 설계 확인 | [`OBSERVABILITY_STRATEGY.md`](OBSERVABILITY_STRATEGY.md) |
| bootstrap state bucket, WIF, CI service account 확인 | [`TERRAFORM_BOOTSTRAP.md`](TERRAFORM_BOOTSTRAP.md) |
| GitHub label, Project 운영 기준 확인 | [`GITHUB_LABELS_AND_PROJECT.md`](GITHUB_LABELS_AND_PROJECT.md) |
| main branch ruleset 확인 | [`BRANCH_RULESET_MAIN.md`](BRANCH_RULESET_MAIN.md) |
| ArgoCD GitOps 책임 경계와 Terraform→ArgoCD 이관 전략 확인 | [`GITOPS_STRATEGY.md`](GITOPS_STRATEGY.md) |
| 완료된 인프라 변경의 결정 이력 확인 | [`CHANGE_HISTORY.md`](CHANGE_HISTORY.md) |

## 문서 작성 기준

- 실제 secret 값, service account JSON key, Terraform state, 로컬
  `terraform.tfvars` 실값은 문서에 쓰지 않는다.
- 운영 명령어는 복사해서 실행 가능한 형태로 작성하되, 개인 이메일이나 임시 IP는
  예시가 아니라 설명으로만 남긴다.
- 명령어, 설정, 권한, 접근 경로가 바뀌면 관련 Terraform 변경과 같은 PR에서 문서를
  갱신한다.
- 새 리소스나 네트워크/IAM 변경처럼 비자명한 작업은 `docs/superpowers/README.md`의
  기준에 따라 작업 중 spec/plan을 만들 수 있다. 작업이 완료되면 핵심 결정만
  `CHANGE_HISTORY.md`에 요약하고, 현재 운영 절차는 runbook 또는 Terraform 문서에
  반영한다.
