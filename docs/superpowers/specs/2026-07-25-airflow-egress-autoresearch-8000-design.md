# airflow-egress에 autoresearch:8000 egress 추가 설계 (#344)

## 배경·목적

`SKYAHO/Autoresearch-airflow#135`(action_log DAG를 rerank-api 기반 노출로
전환, PR #138 머지 완료)가 실행되려면 `airflow` 네임스페이스의 KPO 파드가
`http://autoresearch-serving.autoresearch:8000`(champion 리랭킹 서버)로
HTTP 호출을 해야 한다.

`kubectl -n airflow get networkpolicy airflow-egress -o yaml`로 실측한
결과, 현재 `airflow_egress`(`terraform/admin/airflow-k8s/main.tf`)는
DNS·Cloud SQL(5432)·Redis(6379)·metadata 서버·MLflow(5000)·HTTPS(443)만
허용하고 `autoresearch` 네임스페이스:8000 egress가 없다. 지금 상태로
action_log DAG를 실행하면 `/rerank` 호출이 이 정책에 막혀 타임아웃 난다.

## 결정 — MLflow 규칙과 동일한 2-블록 패턴을 그대로 복제

`egress` 블록 2개를 `autoresearch:8000` 대상으로 추가한다. 하나가 아니라
둘인 이유는 기존 MLflow 규칙(364~396줄)의 주석에 이미 근거가 있다: Calico가
egress를 **Service ClusterIP 기준(DNAT 이전)** 에 평가하는 경로와, DNAT 이후
실제 목적지 파드 기준으로 평가하는 dataplane 경로가 다르다 — 전자는
`namespace_selector`가 매칭되지 않아 `ip_block`(클러스터 서비스 대역) 규칙이
필요하고, 후자를 위한 `namespace_selector` 규칙은 방어적으로 유지한다.
같은 이유가 MLflow(#234)에도 적용됐으므로 새 규칙을 임의로 재해석하지 않고
그 패턴을 포트·네임스페이스만 바꿔 그대로 따른다.

```hcl
# #344 Inference Server(champion 리랭킹, autoresearch 네임스페이스
# autoresearch-serving:8000). Calico가 egress를 DNAT 이전(service VIP 기준)에
# 평가하므로 namespace_selector가 VIP에 매칭되지 않는다 — 위 MLflow와 같은
# 이유로 services CIDR ipBlock을 사용한다.
egress {
  to {
    ip_block {
      cidr = var.cluster_services_cidr
    }
  }

  ports {
    protocol = "TCP"
    port     = "8000"
  }
}

# DNAT 후 평가하는 dataplane용 autoresearch namespace selector 규칙(방어적
# 유지, 위 MLflow 패턴과 동일).
egress {
  to {
    namespace_selector {
      match_labels = {
        "kubernetes.io/metadata.name" = "autoresearch"
      }
    }
  }

  ports {
    protocol = "TCP"
    port     = "8000"
  }
}
```

## 영향 범위

- 변경 파일 1개(`terraform/admin/airflow-k8s/main.tf`), 리소스 1개
  (`kubernetes_network_policy_v1.airflow_egress`) 안에 블록 2개 추가.
- 기존 egress 규칙(DNS·Cloud SQL·Redis·MLflow·HTTPS)은 무변경.
- 다른 admin root(`autoresearch-k8s` 등 7개)에는 diff가 없어야 한다 —
  `admin-apply.yml`이 8개 root를 한 번에 apply하므로, PR의
  `terraform-plan.yml` 출력에서 `airflow-k8s` 외 root에 예상치 못한 diff가
  없는지 반드시 확인한다(완료조건).
- IAM 변경 없음. 리소스 삭제/교체 없음(순수 추가라 in-place, 다운타임 없음).

## 검증

```bash
terraform -chdir=terraform/admin/airflow-k8s fmt -recursive
terraform -chdir=terraform/admin/airflow-k8s init -backend=false
terraform -chdir=terraform/admin/airflow-k8s validate
```

PR의 `terraform-plan.yml` 자동 댓글에서 `airflow-k8s` root에 egress 블록
2개 **추가만** 있고(`+` 뿐, `-`/`~` 없음), 다른 7개 root에 diff가 없는지
확인한다. 실제 반영은 `admin-apply.yml` 수동 트리거 → plan 요약 확인 →
GitHub Environment(`admin-apply`) 승인 → apply. 적용 후 `airflow` 네임스페이스
파드에서 `curl http://autoresearch-serving.autoresearch:8000/healthcheck`가
200을 반환하는지 확인한다(#344 완료조건).

## 롤백

두 `egress` 블록을 제거하고 같은 절차(PR → admin-apply 승인)로 재적용한다.
순수 추가 변경이라 롤백도 대칭적으로 안전하다.
