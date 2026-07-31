# MLflow Training Snapshot Registry 설계

## 목표

학습 CSV를 내용 해시로 주소화하여 동일한 데이터셋은 MLflow artifact 버킷에 한 번만
보관하고, 학습 run은 GCS URI·generation·SHA-256으로 재현 가능한 snapshot을
참조하도록 한다.

## 범위와 경계

- 새 GCS 버킷을 만들지 않고 Terraform이 관리하는 기존 MLflow artifact 버킷을
  재사용한다.
- canonical prefix는 `training-snapshots/sha256=<64자리 hex>/`이다.
- 각 snapshot은 `training_dataset.csv`와 `snapshot_manifest.json`을 가진다.
- 앱의 CSV 생성·해시 계산·manifest 기록 및 MLflow run artifact 업로드 구현은
  `SKYAHO/Autoresearch#423`의 범위이며, 이 변경은 저장소·IAM·운영 계약만 다룬다.
- MLflow는 기존 proxy 모드를 유지한다. MLflow 서버 GSA의 artifact 권한을
  training workload에 상속시키지 않는다.

## 저장 및 무결성 계약

1. publisher가 CSV bytes의 SHA-256을 계산한다.
2. `gs://<mlflow-bucket>/training-snapshots/sha256=<digest>/training_dataset.csv`
   를 generation `0` 조건으로 create-if-absent 업로드한다.
3. manifest도 같은 digest와 CSV object URI, generation, byte size를 기록한다.
4. 같은 digest가 이미 있으면 기존 객체를 읽어 SHA-256과 generation을 검증하고
   재사용한다. 기존 객체를 덮어쓰는 update 권한은 부여하지 않는다.
5. digest가 다른 bytes로 기존 canonical 경로를 덮으려는 시도는 GCS의
   `roles/storage.objectCreator` 제한으로 실패해야 한다.
6. consumer는 다운로드한 CSV의 SHA-256과 manifest의 digest, URI, generation을
   모두 대조하고 불일치 시 실행을 실패시킨다.

CSV 업로드 후 manifest 업로드 전에 publisher가 종료되면 partial publish로
판정한다. 다음 실행은 CSV와 manifest를 각각 generation `0` 조건으로 재시도하고,
precondition failure가 발생하면 두 known URI를 직접 GET하여 둘 다 존재하고
digest·size·generation 검증을 통과할 때만 reuse한다. CSV만 있거나 manifest가
불일치하면 batch GSA는 overwrite/delete 권한이 없으므로 실행을 실패시키고
운영자가 MLflow GSA 또는 승인된 복구 절차로 정리한 뒤 재시도한다. 403은 권한
실패로 그대로 전파하며 기존 snapshot 재사용으로 처리하지 않는다.

## 보존·복구·비용

- MLflow artifact 버킷은 `prevent_destroy`를 유지한다.
- GCS Object Versioning을 켜고, 기존 7일 soft delete 복구층을 유지한다.
- 버킷 전체 versioning으로 생기는 MLflow artifact의 noncurrent generation은
  기본 30일 후 lifecycle로 정리한다. snapshot은 creator-only로 overwrite하지
  않으므로 이 규칙은 정상적인 canonical snapshot publish를 삭제하지 않는다.
- `mlflow_training_snapshot_retention_days` 기본값은 `0`(age 기반 삭제 없음)으로
  하여 재현에 필요한 snapshot을 조용히 삭제하지 않는다. 명시적으로 양수를
  설정한 환경만 live snapshot에 age lifecycle을 적용한다. 이 값은 참조 중인
  snapshot도 object 생성 시각 기준으로 삭제할 수 있으므로, 참조 run/model의
  보존 기간과 함께 변경해야 한다.
- soft delete 7일과 noncurrent version 30일은 서로 다른 복구 경로다. 전자는
  최근 삭제의 단기 안전망이고 후자는 versioned artifact generation의 비용을
  제한하는 장기 보존층이다. 두 층의 7일 중첩 비용은 dev에서 의도적으로 수용하며,
  staging/prod에서는 보존 정책과 비용을 다시 검토한다.
- canonical 객체는 digest 중복 제거로 저장량을 줄이지만, snapshot을 영구 보존하는
  기본값에서는 데이터 크기와 보존 기간에 비례해 GCS 저장 비용이 발생한다.
- 실수 삭제는 soft delete 기간 내 undelete하고, versioning generation 문제는
  이전 generation을 별도 복구 객체로 복사한 뒤 hash를 다시 검증한다.

## IAM 경계

- 학습·비교 consumer는 기존 `airflow/autoresearch-batch` KSA가 가장하는
  `autoresearch-dev-airflow-batch` GSA를 사용한다.
- 해당 GSA에는 MLflow artifact 버킷의 `training-snapshots/` object prefix에만
  `storage.objectCreator`와 `storage.objectViewer`를 부여한다.
- publisher/consumer는 bucket listing이나 bucket metadata reload에 의존하지 않고
  manifest에 기록된 known object URI를 직접 GET한다. 따라서 bucket-wide
  `legacyBucketReader`는 부여하지 않는다.
- bucket 전체 objectAdmin 또는 service-account key는 추가하지 않는다.
- MLflow 서버 GSA의 기존 artifact objectAdmin은 proxy 모드 동작을 위해 유지한다.
