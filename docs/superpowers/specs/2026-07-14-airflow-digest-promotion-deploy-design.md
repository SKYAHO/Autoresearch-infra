# Airflow digest 승격 및 자동 배포 IAM 설계

## 목적

검증된 `Autoresearch` application image digest를 자동 PR로
`Autoresearch-airflow`에 전달하고, 사람이 PR을 merge한 뒤 GitHub Actions가
dev GKE의 Airflow Helm release를 자동 배포하도록 최소 권한을 제공한다.

## 신뢰 경계

- application image push 권한은 정확한
  `SKYAHO/Autoresearch/.github/workflows/release.yml@refs/heads/main`
  `workflow_ref`에만 부여한다. release event의 `ref`가 tag이더라도 workflow
  파일 자체의 승인 경계를 유지한다.
- Airflow 배포 계정은
  `SKYAHO/Autoresearch-airflow@refs/heads/main`만 가장할 수 있다.
- 배포 계정의 GCP 권한은 `roles/container.clusterViewer`로 제한한다.
- Kubernetes 권한은 `airflow` namespace의 `admin` RoleBinding으로 제한한다.
- GitHub Actions는 GKE DNS endpoint를 사용한다. IP allowlist는 확장하지 않는다.
- 자동화는 application 저장소에서 Airflow PR을 생성하지만 merge 권한은
  행사하지 않는다.

## 리소스

| 계층 | 리소스 | 용도 |
| --- | --- | --- |
| bootstrap | `attribute.workflow_ref` mapping | 승인된 release workflow를 tag ref와 독립적으로 식별 |
| dev | `${resource_prefix}-airflow-cd` GSA | GitHub Actions의 GKE 접속 전용 신원 |
| dev | `roles/container.clusterViewer` | cluster metadata 조회와 connect |
| airflow-k8s | `airflow-deployer-admin` RoleBinding | `airflow` namespace Helm 배포 |

## 적용 순서와 롤백

1. bootstrap WIF provider mapping과 허용 repository 목록을 적용한다.
2. dev root에서 deployer GSA, WIF binding, cluster viewer를 적용한다.
3. `terraform/admin/airflow-k8s`에서 namespace RoleBinding을 적용한다.
4. Airflow repository variable을 설정한 뒤 수동 배포로 현재 digest를 검증한다.

롤백은 Airflow 자동 배포 workflow를 비활성화한 뒤 Kubernetes RoleBinding,
deployer WIF binding과 GSA를 제거한다. application pusher binding은 기존
`repository_ref`로 되돌리지 않고 workflow 실행을 중단해 대응한다. tag release에
대한 잘못된 ref 경계가 재발하기 때문이다.

Terraform apply는 이 변경의 코드 리뷰와 별도 운영 승인을 받은 뒤 수행한다.
