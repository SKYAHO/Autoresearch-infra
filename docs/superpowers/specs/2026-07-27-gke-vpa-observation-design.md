# GKE VPA 관측 도입 설계 (#373)

> 작성: 2026-07-27 | 상태: 승인됨
> 연계: Autoresearch-airflow#159

## 목표

GKE dev 클러스터에 Vertical Pod Autoscaling(VPA) 애드온을 활성화하고,
Airflow scheduler의 실제 컨테이너 리소스 사용량에 근거한 recommendation을
수집한다. 이 변경은 scheduler resource를 자동 변경하거나 실행 중인 task를
중단하지 않는다.

## 배경

2026-07-27 `youtube_gcs_action_log_pipeline` 실행 중 scheduler 컨테이너가
1536Mi memory limit 중 1472Mi를 사용한 상태에서 OOMKilled됐다. LocalExecutor는
task 프로세스를 scheduler Pod 안에서 실행하므로, VPA가 Pod를 eviction하는
방식으로 resource를 적용하면 장시간 task도 함께 중단된다.

## 책임 경계

| 영역 | 소유 저장소 | 변경 |
| --- | --- | --- |
| GKE VPA API/controller | Autoresearch-infra | `google_container_cluster.dev`의 VPA 애드온 활성화 |
| VPA CR 생성/조회 RBAC | Autoresearch-infra | `airflow` namespace의 Helm deployer·installer에 VPA lifecycle 최소 권한 부여 |
| scheduler VPA desired state | Autoresearch-airflow | Helm template으로 VPA CR 배포 |
| scheduler request/limit 조정 | Autoresearch-airflow | 관측 후 별도 이슈에서 `values.yaml`을 수동 변경 |

VPA CR을 infra Terraform state에 두지 않는다. CR은 Airflow Helm release가
소유하는 StatefulSet의 lifecycle과 함께 배포·롤백되어야 한다.

## 설계

`terraform/envs/dev/gke.tf`의 `google_container_cluster.dev`에 다음 최상위
구성을 추가한다. `vertical_pod_autoscaling`은 google provider v7.39.0에서
`addons_config`의 하위 block이 아니다.

```hcl
  vertical_pod_autoscaling {
    enabled = true
  }
```

이는 GKE VPA CRD와 recommender/controller를 제공한다. workload의 resource
request/limit이나 replica 수를 변경하지 않는다. 다만 GKE addon 활성화는 비동기
cluster update operation이므로, zonal control plane 또는 node 재생성이 필요하지
않다고 단정하지 않는다. apply는 DAG 스케줄이 없는 운영 창에서 수행하고 완료된
GKE operation을 확인한다.

GKE managed addon의 내부 RBAC는 공개 계약이 아니다. 따라서
`terraform/admin/airflow-k8s`가 `airflow` namespace에
`autoscaling.k8s.io/verticalpodautoscalers` 전용 Role과 RoleBinding을 선언한다.
Helm deployer GSA와 installer 사용자는 Helm lifecycle에 필요한
`get`, `list`, `watch`, `create`, `update`, `patch`, `delete`만 받는다. 기존
`admin` ClusterRole의 aggregation 또는 addon 내부 Role 이름에 의존하지 않는다.

VPA CR은 애드온 적용 후 Autoresearch-airflow#159에서 배포한다. 해당 CR은
`autoscaling.k8s.io/v1`, namespace `airflow`, target `apps/v1` StatefulSet
`airflow-scheduler`, `updateMode: "Off"`를 사용한다.

container policy와 min/max 경계는 초기 관측 단계에 두지 않는다. scheduler와
git-sync 컨테이너의 recommendation을 모두 수집하고, 사람의 운영 검토에서
scheduler의 현재 resource 설정과 node·namespace 여유를 대조한다.

## 적용 순서

1. infra 변경을 fmt, validate, 인증 환경의 Terraform plan으로 검증한다.
2. VPA Role/RoleBinding은 별도 `admin-apply` 승인 경로로 적용한다.
3. PR merge 후 사용자의 명시적 승인으로 GKE addon `dev-apply`를 DAG 스케줄이 없는
   운영 창에서 수행하고, 완료된 GKE operation을 확인한다.
4. CRD 생성과 `Established` condition을 순서대로 기다린 뒤 served VPA API를
   확인한다. CRD가 아직 없으면 `kubectl wait --for=condition=Established`는 즉시
   실패하므로 생성 polling 또는 `--for=create`를 선행한다.
5. Helm deployer와 installer가 VPA lifecycle 권한을 갖는지 `kubectl auth can-i`로
   확인한다.
6. Autoresearch-airflow#159 Helm 변경을 배포한다.
7. 실행 데이터가 쌓인 뒤 `kubectl describe vpa airflow-scheduler -n airflow`로
   recommendation을 확인한다.

## 비목표

- `Auto` 또는 `Recreate` update mode 사용
- scheduler, webserver, KPO batch workload의 자동 resource 변경
- LocalExecutor 변경
- VPA recommendation에 따른 memory limit의 즉시 상향
- HPA 또는 node pool autoscaling 정책 변경

## 검증과 롤백

Terraform 검증은 다음 명령으로 수행한다.

```bash
terraform -chdir=terraform/envs/dev fmt -check -recursive
terraform -chdir=terraform/envs/dev init -backend=false
terraform -chdir=terraform/envs/dev validate
```

운영 적용 후에는 CRD 생성, Established condition, served VPA API와 deployer RBAC를
확인한다. readiness polling은 대화형 shell을 종료하지 않는 서브셸에서 실행한다. 문제가 있으면
먼저 Autoresearch-airflow의 VPA manifest를 제거해 CR을 삭제한 뒤, 필요할 때만
후속 Terraform 변경으로 애드온을 비활성화한다. 관측 모드에서는 scheduler Pod
변경이 없으므로 scheduler task 중단을 유발하지 않는다.
