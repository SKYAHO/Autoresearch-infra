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
| Elasticsearch CR `autoresearch` | 예 (#98) | single-node, `kubernetes_manifest` — CRD 부트스트랩 순서 주의 |
| Kibana/Beat CR | 예 (후속 #99/#100) | `kubernetes_manifest` |
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

## Elasticsearch 구성 (#98)

| 항목 | 값 | 비고 |
|---|---|---|
| CR / 버전 | `autoresearch` / `var.elasticsearch_version`(9.2.0) | ES/Kibana 스택 버전은 동일하게 유지 |
| nodeSet | `default` 1 node (master+data 겸용) | dev 최소. zonal 클러스터라 multi-zone HA는 범위 밖(이슈 참고 사항) |
| 리소스 | heap 1G(`ES_JAVA_OPTS`), request 2Gi/500m, limit 3Gi | heap = 컨테이너 메모리의 ~50% 기준 |
| 배치 | nodeSelector `dev-default` pool 고정 | 실측 여유(~8.8GB)가 있는 노드로 한정 — airflow-dev pool 압박 방지. **전용 node pool 불필요**(#96, headroom 3Gi 미만이 되면 #105에서 재검토) |
| PVC | `elasticsearch-data` 30Gi `standard`(pd-standard, HDD) | 70% 사용 시 증설 검토(#96). SSD quota 초과로 HDD 선택(#98 인시던트) — dev 로그 워크로드에 충분 |
| mmap | `node.store.allow_mmap: false` | vm.max_map_count sysctl(privileged) 회피 — PSS baseline 유지 |
| TLS/인증 | ECK 기본(자체 서명 TLS + `elastic` 사용자) | 비밀번호는 `autoresearch-es-elastic-user` Secret에서 회수(#103 runbook). Git/문서 금지 |
| index replicas | 기본 template은 #101에서 `number_of_replicas: 0` | single-node에서 green 유지를 위한 필수값(#96) |

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
kubectl -n elastic get svc              # 모든 Service가 ClusterIP여야 함
kubectl -n elastic get elasticsearch    # HEALTH green / PHASE Ready (#98)
```

## 롤백

- `helm_release.eck_operator` 제거 후 apply → operator만 삭제. CRD와 기존
  CR(ES/Kibana)은 남고 reconcile만 정지된다(데이터/pod 유지).
- **CRD는 수동으로 지우지 않는다** — ES/Kibana CR 연쇄 삭제로 PVC 데이터
  유실까지 이어질 수 있다. 정리가 필요하면 CR 제거(#98 롤백) → snapshot
  확인 → CRD 정리 순서를 지킨다.
- ES CR 제거(`kubernetes_manifest.elasticsearch` 삭제 후 apply)는 pod/서비스를
  지우고, **PVC는 `volumeClaimDeletePolicy: DeleteOnScaledownOnly` 설정으로
  남는다**. 주의: ECK 기본값(DeleteOnScaledownAndClusterDeletion)이었다면
  CR 삭제가 PVC→PD 삭제(standard-rwo reclaimPolicy Delete)로 이어져 데이터가
  영구 소실된다 — 이 필드를 제거하지 않는다. 데이터까지 정리하려면 CR 제거
  후 PVC를 수동 삭제하고, 보존이 필요하면 제거 전 snapshot(#102)을 확인한다.
- chart 버전 롤백은 `eck_chart_version`을 되돌려 apply.
