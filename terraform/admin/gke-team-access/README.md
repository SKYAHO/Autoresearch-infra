# 팀원 GKE·Bastion·BigQuery 접근 권한

이 admin Terraform root는 dev GKE 클러스터, Bastion, BigQuery 분석 작업에 접근해야
하는 사람 Google 계정을 관리합니다.

개인 이메일 주소가 PR plan 댓글에 노출되거나, CI가 로컬 tfvars 없이 실행될 때
사람 계정을 제거하려 시도하지 않도록 `terraform/envs/dev`와 분리되어 있습니다.

## 사용법

```bash
cd terraform/admin/gke-team-access
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars에 실제 Google 계정을 입력합니다. 이 파일은 커밋하지 않습니다.

terraform init
terraform plan
terraform apply
```

권한은 프로젝트 수준 `roles/container.viewer`로 부여합니다(#45: DNS 엔드포인트
접속에 필요한 `container.clusters.connect` 포함). `ar-infra-501607`에 dev GKE
클러스터가 하나뿐인 동안에는 허용 가능한 범위입니다. 프로젝트에 클러스터가 더
추가되면 IAM condition으로 binding 범위를 좁히거나 클러스터 접근을 전용
프로젝트로 분리합니다.

## BigQuery 분석 권한 (#215)

`team_member_emails`의 각 계정에는 다음 권한을 additive IAM member로 부여합니다.
실제 이메일은 이 root의 로컬 `terraform.tfvars`에만 두며, 코드·문서·PR plan에
넣지 않습니다.

| 범위 | 역할 | 용도 |
| --- | --- | --- |
| 프로젝트 | `roles/bigquery.jobUser` | query/load/export BigQuery job 실행 |
| `autoresearch_dev_analytics` dataset | `roles/bigquery.dataEditor` | 분석 테이블 생성·갱신·삭제 |
| `feast_offline_store` dataset | `roles/bigquery.dataEditor` | Feast/data lake 테이블 생성·갱신·삭제 |

`dataEditor`는 두 dataset에만 부여합니다. 프로젝트 수준
`roles/bigquery.dataEditor`, `roles/editor`, `roles/owner`는 부여하지 않습니다.
`jobUser`는 프로젝트 범위의 job 생성 권한이므로, 팀원이 실행하는 query/load job은
`maximum_bytes_billed` 등 job 수준 비용 제한을 함께 사용해야 합니다.

`team_member_emails`에서 이메일을 제거하고 apply하면 해당 계정의 GKE, Bastion,
BigQuery IAM member가 함께 제거됩니다.
이미 발급된 access token은 만료될 때까지, 보통 최대 약 1시간 동안 유효할 수
있습니다.

## 이미지·빌드·DB 운영 권한 (#266)

세 저장소(`Autoresearch-infra`·`Autoresearch`·`Autoresearch-airflow`)의 runbook이
요구하는데 빠져 있던 권한을 `team_member_emails` 전원에게 추가로 부여합니다.

| 범위 | 역할 | 용도 |
| --- | --- | --- |
| `autoresearch-dev-docker` 저장소 | `roles/artifactregistry.reader` | 배포된 이미지 목록·digest 확인(release 파이프라인 운영 절차) |
| 프로젝트 | `roles/cloudbuild.builds.editor` | `gcloud builds submit`으로 Feast 등 이미지 빌드. ⚠️ build는 기본 compute SA로 실행되고 그 SA가 dev GAR writer라, 빌드를 통한 **간접 이미지 push 경로**가 함께 열립니다(`terraform/envs/dev/cloud_build.tf`). 차단하려면 build 전용 SA 분리가 필요합니다 |
| `<project>_cloudbuild` 버킷 | `roles/storage.objectAdmin` | 위 build의 source 업로드(버킷 범위로만) |
| 프로젝트 | `roles/cloudsql.viewer` | Cloud SQL 인스턴스 상태·private IP 조회. DB 접속 권한 아님 |
| `autoresearch-dev-db-password` secret | `roles/secretmanager.secretAccessor` | 저장된 DB 비밀번호 **값 읽기**. Airflow runbook의 `kubectl create secret` 절차에 필요합니다. 새 version 추가·rotate는 별도 역할(`secretVersionAdder`/`secretVersionManager`)이 필요하며 이 PR에서는 부여하지 않습니다 |

사람 계정에 **직접** 부여한 Artifact Registry 역할은 `reader`뿐이며, 직접 push(`writer`)는
WIF SA와 아래 학습 이미지 writer 대상에만 둡니다. 프로젝트 수준 Secret Manager·Cloud SQL
client·Storage admin은 부여하지 않습니다.

## 학습 이미지 AR writer (#185/#256, 정책 갱신 #266)

학습 이미지(`autoresearch-training`)를 GAR에 첫 **수동 push**로 언블록하기 위해,
`training_image_ar_writer_emails`의 각 계정에 **`autoresearch-dev-docker` 저장소
범위** `roles/artifactregistry.writer`만 부여합니다(프로젝트 수준 아님,
`team_member_emails`와 분리). 실제 이메일은 로컬 `terraform.tfvars`에만 둡니다.

**임시 조치입니다.** 첫 push/E2E 검증이 끝나면 `training_image_ar_writer_emails`를
빈 목록으로 두고 apply해 **회수**합니다. 항구적 이미지 push 경로는 개인 계정이
아니라 앱 CI의 `application_pusher` WIF SA입니다(#185 본작업).

팀원에게는
[`docs/TEAM_OPERATIONS_RUNBOOK.md`](../../../docs/TEAM_OPERATIONS_RUNBOOK.md)의
로컬 설정 절차를 공유합니다. 실제 공인 IP, kubeconfig 파일, service account key가
들어간 예시 파일은 공유하거나 커밋하지 않습니다.
