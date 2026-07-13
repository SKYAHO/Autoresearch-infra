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
| Kibana CR `autoresearch` | 예 (#99) | 1 replica, ClusterIP + port-forward 전용 |
| Beat CR `autoresearch` (Filebeat) | 예 (#100) | DaemonSet, namespace allowlist 수집 |
| Filebeat RBAC | 예 (#100) | 전용 SA + 읽기 전용 ClusterRole(autodiscover) |
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

## Kibana 구성과 접속 (#99)

| 항목 | 값 | 비고 |
|---|---|---|
| CR / 버전 | `autoresearch` / ES와 동일(`var.elasticsearch_version`) | `elasticsearchRef`로 operator가 ES 연결(계정/CA 자동) |
| 리소스 | request 1Gi/200m, limit 1Gi | dev-default pool 고정(#98과 동일 이유) |
| 노출 | ClusterIP + port-forward만 | LB/Ingress 없음. TLS는 ECK 기본(self-signed) |

접속 (내부 전용):

```bash
kubectl -n elastic port-forward svc/autoresearch-kb-http 5601:5601
# 브라우저: https://localhost:5601 (self-signed 경고는 dev 내부 경로 특성상 허용)
```

로그인은 `elastic` 사용자. 비밀번호는 운영자가 Secret에서 회수하고
채팅/Git/문서에 남기지 않는다:

```bash
kubectl -n elastic get secret autoresearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d
```

상세 운영 절차(비밀번호 변경, 검색 기본, 장애 대응)는 #103 runbook에서
제공한다.

## 로그 수집 (#100)

| 항목 | 값 | 비고 |
|---|---|---|
| 수집기 | Filebeat (ECK `Beat` CR, DaemonSet) | Elastic Agent 대신 단일 용도로 단순화(#96) |
| 수집 범위 | **`airflow`·`autoresearch` namespace 컨테이너 로그만** | autodiscover 조건 allowlist. 시스템/플랫폼 로그는 Cloud Logging 담당 — 중복 수집 방지 기준(#96 역할 분리) |
| RBAC | 전용 SA + 읽기 전용 ClusterRole | pods/namespaces/nodes/replicasets/jobs get·list·watch만 |
| PSS | hostPath(/var/log) read가 baseline 위반 — **audit/warn만 발생(비강제), 수용** | 로그 수집기의 본질적 요구. enforce 전환 시 Beat 전용 예외 설계 필요 |
| 인덱스 | data stream `filebeat-<version>` | 템플릿 replicas 0(#101 — single-node green 전제) |

## 보존 정책 — ILM (#101)

ES 내부 리소스(ILM policy)는 Vault 내부 리소스와 같은 원칙으로 Terraform이
아닌 **운영자 절차**로 관리한다. filebeat data stream이 참조하는 `filebeat`
policy를 아래 기준으로 유지한다(기본값은 rollover 30d/50gb + **삭제 없음**
— 무한 증가):

| 항목 | 값 | 근거 |
|---|---|---|
| rollover | max_age 1d 또는 primary shard 5gb | #96 — 일 단위 관리 |
| delete | rollover 후 7일 | Prometheus retention과 정합. **비용 증가 방지의 핵심**(PVC 30Gi 고정에서 무한 보관 차단) |
| 운영 전환 시 | delete min_age만 상향 | dev/운영 보관 기간 분리 기준(#101 이슈 참고 사항) |

적용/확인(port-forward + elastic 인증 후):

```bash
curl -sk -u "elastic:$PW" -X PUT https://localhost:19200/_ilm/policy/filebeat \
  -H 'Content-Type: application/json' -d '{
  "policy": {
    "phases": {
      "hot":    { "actions": { "rollover": { "max_age": "1d", "max_primary_shard_size": "5gb" } } },
      "delete": { "min_age": "7d", "actions": { "delete": {} } }
    }
  }
}'

# 확인
curl -sk -u "elastic:$PW" https://localhost:19200/_ilm/policy/filebeat
curl -sk -u "elastic:$PW" "https://localhost:19200/.ds-filebeat-*/_ilm/explain?only_errors=true"
```

filebeat 템플릿의 replicas 0은 Beat config(`setup.template`)가 관리하지만,
**이미 생성된 backing index**에는 소급되지 않으므로 1회 수동 적용한다:

```bash
curl -sk -u "elastic:$PW" -X PUT "https://localhost:19200/.ds-filebeat-*/_settings" \
  -H 'Content-Type: application/json' -d '{"index.number_of_replicas": 0}'
```

## 네트워크 경계

| 방향 | 허용 | 이유 |
|---|---|---|
| ingress | 같은 ns, kube-system | Kibana→ES(9200), ES transport(9300), Filebeat→ES |
| ingress | master CIDR → 10250 | control plane → validating webhook |
| ingress | `var.kibana_ingress_source_cidr`(dev subnet) → 5601 | Kibana port-forward(#116 교훈). CR은 #99에서 추가되지만 경계는 선언 |
| egress | 같은 ns | 내부 통신 |
| egress | services CIDR 53/443/9200 | kube-dns, kubernetes.default, ES http VIP(Filebeat #100) — pre-DNAT(#122) |
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
