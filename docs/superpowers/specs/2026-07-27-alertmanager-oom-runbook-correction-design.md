# Alertmanager OOM 검증 Runbook 정정 설계 (#386)

## 목적

`ContainerOOMKilled` 검증 절차가 실제 Prometheus metric 계약을 만족하도록
운영 문서와 기존 실행 plan을 정정하고, Alertmanager SMTP 이메일 검증 완료 상태를
사실대로 기록한다.

## 확인된 원인

규칙은 다음 metric을 조회한다.

```promql
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
```

`restartPolicy: Never` Pod는 OOMKilled 뒤 재시작하지 않아 이 previous-termination
metric을 제공하지 않는다. `restartPolicy: Always` Pod는 OOMKilled 뒤 재시작하며,
규칙은 pending을 거쳐 `for: 1m` 뒤 firing한다.

## 변경 범위

- `docs/GRAFANA_OPERATIONS_RUNBOOK.md`
  - OOM 검증 Pod의 재시작 정책을 `Always`로 명시한다.
  - 재시작이 metric 계약의 전제임을 설명하고, Pod 삭제로 resolved 알림을
    확인하는 순서를 유지한다.
- `docs/OBSERVABILITY_STRATEGY.md`
  - #372의 ArgoCD sync, OOMKilled warning/resolved, CrashLooping warning/resolved
    이메일 실증 결과를 현재 상태에 반영한다.
  - warning/critical receiver route는 구성됐지만 critical 이메일을 별도로
    실증하지 않았다는 구분을 유지한다.
- `docs/superpowers/plans/2026-07-27-alertmanager-smtp-oomkilled.md`
  - 실행 가능한 OOM test Pod manifest와 설명의 `restartPolicy`를 `Always`로
    정정한다.

## 변경하지 않는 범위

- `ContainerOOMKilled` PrometheusRule 식, `for: 1m`, severity는 변경하지 않는다.
- Alertmanager SMTP Secret payload, receiver 주소, IAM, 네트워크, chart values를
  변경하지 않는다.
- 과거 설계 spec의 서술이나 spec/plan archive 이동은 이번 이슈 범위에 포함하지
  않는다.

## 검증

1. 세 문서에서 OOM test Pod의 실행 지시가 `restartPolicy: Always`로 일치하는지
   검색한다.
2. 현재 상태 문구가 실제로 검증한 warning/resolved 이메일과 미실증 critical
   이메일을 혼동하지 않는지 검토한다.
3. `git diff --check`로 문서 형식을 검증하고, diff에 Secret payload가 없는지
   확인한다.
