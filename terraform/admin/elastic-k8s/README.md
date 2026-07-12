# Elastic (ECK) Kubernetes Admin Root

이 root는 dev GKE의 ECK operator와 (후속) Elasticsearch/Kibana를 별도
state로 관리한다. 아키텍처·정책은 #96 설계
(`docs/superpowers/specs/2026-07-13-elk-architecture-design.md`)를 따른다.

## 책임 범위

| 항목 | 이 root에서 관리 | 비고 |
|---|---|---|
| `elastic` namespace | 예 | `prevent_destroy`. 이슈 #97 본문의 elastic-system 대신 #96 설계의 단일 namespace |
| ECK operator Helm release | 예 | chart `eck-operator` `3.4.1` pin (#97) |
| NetworkPolicy | 예 | deny-by-default (아래 표) |
| Elasticsearch/Kibana/Beat CR | 예 (후속 #98/#99/#100) | `kubernetes_manifest` — CRD 부트스트랩 순서 주의 |
| snapshot GCS bucket / GSA | 아니오 | dev root (#102에서 추가) |
| `elastic` 사용자 비밀번호 | 아니오 | operator 생성 Secret에서 운영자가 회수(#103 runbook). Git/문서 금지 |

## 설치 구성 (#97)

| 항목 | 값 | 비고 |
|---|---|---|
| Chart | `eck-operator` `3.4.1` | `var.eck_chart_version`. 버전 고정 기준: ECK 3.x는 ES/Kibana 8~9.x 관리 — CR의 스택 버전과 operator 버전을 함께 pin하고 upgrade는 operator 먼저 |
| 감시 범위 | `managedNamespaces: [elastic]` | cluster 전역 기본값 대신 **최소 권한** — 이 namespace의 CR만 reconcile |
| webhook | enabled, **port 10250** | private GKE의 기본 master→node 방화벽 허용 포트 재사용 — monitoring-k8s의 `prometheusOperator.internalPort` 선례. 별도 firewall 불필요 |
| CRD | chart `crds/` 경로 설치 | helm uninstall이 CRD를 삭제하지 않음(keep). **CRD를 지우면 ES/Kibana CR 연쇄 삭제 → 데이터 유실** — rollouts root와 동일 주의 |
| RBAC | chart 기본 + managedNamespaces 제한 | operator가 관리하는 리소스(statefulset/secret/service 등)는 elastic ns 범위로 한정 |

## 네트워크 경계

| 방향 | 허용 | 이유 |
|---|---|---|
| ingress | 같은 ns, kube-system | Kibana→ES(9200), ES transport(9300), Filebeat→ES |
| ingress | master CIDR → 10250 | control plane → validating webhook |
| ingress | `var.kibana_ingress_source_cidr`(dev subnet) → 5601 | Kibana port-forward(#116 교훈). CR은 #99에서 추가되지만 경계는 선언 |
| egress | 같은 ns | 내부 통신 |
| egress | services CIDR 53/443 | kube-dns, kubernetes.default VIP — pre-DNAT(#122) |
| egress | kube-system 53 | post-DNAT dataplane 대비 |
| egress | master CIDR 443 | K8s API post-DNAT 대비(#138 패턴) |
| egress | `199.36.153.8/30`:443 | GCS snapshot(#102) — private googleapis VIP(#138) |

## 사용 방법

```bash
cd terraform/admin/elastic-k8s
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars에 실제 project_id를 입력합니다. 이 파일은 커밋하지 않습니다.

terraform init
terraform plan
terraform apply
```

운영자 환경 전용(일반 PR CI는 lint만). chart가 CRD와 ClusterRole을
포함하므로 cluster-admin 수준 Kubernetes 권한이 필요하다.

**완전 재구성(재해 복구) 순서**: #98 이후 `kubernetes_manifest`
(Elasticsearch/Kibana CR)는 plan 단계에서 CRD 스키마를 조회하므로, 빈
클러스터에서는 operator를 먼저 targeted apply한다(argocd-k8s 선례):

```bash
terraform apply -target=helm_release.eck_operator
terraform apply
```

로컬 검증:

```bash
terraform -chdir=terraform/admin/elastic-k8s fmt -check -recursive
terraform -chdir=terraform/admin/elastic-k8s init -backend=false
terraform -chdir=terraform/admin/elastic-k8s validate
```

## 설치 후 확인

```bash
kubectl -n elastic get pods
kubectl get crd | grep k8s.elastic.co   # elasticsearch/kibana/beat 등
kubectl -n elastic get svc              # 외부 노출 리소스 없어야 함
```

## 롤백

- `helm_release.eck_operator` 제거 후 apply → operator만 삭제. CRD와 기존
  CR(ES/Kibana)은 남고 reconcile만 정지된다(데이터/pod 유지).
- **CRD는 수동으로 지우지 않는다** — ES/Kibana CR 연쇄 삭제로 PVC 데이터
  유실까지 이어질 수 있다. 정리가 필요하면 CR 제거(#98 롤백) → snapshot
  확인 → CRD 정리 순서를 지킨다.
- chart 버전 롤백은 `eck_chart_version`을 되돌려 apply.
