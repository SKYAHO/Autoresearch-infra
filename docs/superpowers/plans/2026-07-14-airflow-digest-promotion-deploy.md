# Airflow digest 승격 및 자동 배포 구현 계획

1. bootstrap WIF에 `workflow_ref` attribute mapping을 추가하고 세 repository를
   안전한 default 허용 목록으로 둔다.
2. application pusher의 가장 조건을 정확한 release workflow ref로 변경한다.
3. Airflow `main` 전용 deployer GSA와 `roles/container.clusterViewer`를 추가한다.
4. `airflow` namespace에 deployer GSA용 `admin` RoleBinding을 추가한다.
5. output, Terraform 운영 문서와 변경 이력을 갱신한다.
6. `terraform fmt`, `terraform validate`와 정적 계약 test로 검증한다.

이 계획에는 `terraform apply`, GitHub repository variable 변경과 실제 Helm 배포가
포함되지 않는다.
