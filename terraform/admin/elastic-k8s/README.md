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
| 노출 | ClusterIP + port-forward만 | LB/Ingress 없음. **Kibana 자체 TLS 비활성(#394)** — 9.x가 TLS 서빙 시 secure 세션을 강제해 http 프록시 로그인이 차단되던 결함 해소. ES·Kibana↔ES TLS는 유지 |

접속 (내부 전용):

```bash
kubectl -n elastic port-forward svc/autoresearch-kb-http 5601:5601
# 브라우저: http://localhost:5601 (#394부터 Kibana는 http — break-glass 직접 접속 시)
```

로그인은 `elastic` 사용자. 비밀번호는 운영자가 Secret에서 회수하고
채팅/Git/문서에 남기지 않는다:

```bash
kubectl -n elastic get secret autoresearch-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 -d
```

상세 운영 절차(검색, 정기 점검, 장애 대응, 업그레이드 주의)는
[docs/KIBANA_OPERATIONS_RUNBOOK.md](../../../docs/KIBANA_OPERATIONS_RUNBOOK.md)(#103)를 따른다.

## Kibana Google(Gmail) 로그인 (#293/#325)

팀원이 Gmail로 접근을 통제한다. ECK Basic 라이선스라 네이티브 OIDC(Platinum)를
못 쓰고, Kibana 9.2에서 anonymous 자동 로그인이 안정적으로 동작하지 않아(#323),
**oauth2-proxy(Google 로그인 + 허용 이메일)로 접근을 통제하고 Kibana는 기본 basic
인증(`elastic` 등 실제 사용자)으로 로그인**한다(이중 로그인이나 신뢰도 우선).
oauth2-proxy는 `authenticated-emails` Secret 파일을 유일한 이메일 allowlist로
사용하며, `email-domain=*`와 조합하지 않는다.

- 사용자는 Kibana(5601)가 아니라 **oauth2-proxy Service(4180)** 를 로컬 **4181**
  포트로 port-forward 한다(MLflow의 로컬 4180과 충돌 방지). proxy가 Google 로그인 +
  허용 이메일로 인증한 뒤 Kibana로 프록시하고, **Kibana `/login`에서 다시** `elastic`
  (또는 별도 사용자)로 로그인한다. http port-forward라 세션 쿠키는
  `xpack.security.secureCookies=false`로 둔다.
- `elastic` 비밀번호는 `autoresearch-es-elastic-user` Secret에서 회수한다(문서/PR/
  채팅 미기재). 팀원별 read-only 사용자가 필요하면 ES fileRealm/native 사용자를 별도
  발급한다.

**operator secret 주입 — `kibana-oauth`** (값을 명령행·히스토리에 남기지 않도록 file 기반):

선행: GCP 콘솔에서 OAuth client(웹) 생성, redirect URI
`http://localhost:4181/oauth2/callback` 등록.

```bash
(
set -euo pipefail
umask 077
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
# #439: 정본은 Secret Manager — 발급 직후 id/secret 한 쌍을 먼저 등록
#   gcloud secrets versions add autoresearch-dev-kibana-oauth-client-{id,secret} --data-file=-
for k in client-id client-secret; do
  gcloud secrets versions access latest \
    --secret "autoresearch-dev-kibana-oauth-$k" --project "$PROJECT_ID" \
    | tr -d '\n' > "$d/$k"
  test -s "$d/$k" || { echo "ERROR: $k 정본 비어 있음 — versions add 먼저"; exit 1; }
done
# cookie 비밀과 allowlist: Secret 없음과 인증/연결 실패를 구분한다.
# 기존 Secret을 재실행할 때는 두 값을 보존한다. 최초 생성 또는 의도적 allowlist 변경만
# ALLOWLIST_FILE에 실제 승인 이메일 파일(한 줄에 하나, 로컬 0600)을 지정한다.
if kubectl -n elastic get secret kibana-oauth --ignore-not-found -o name > "$d/existing-secret"; then
  if test -s "$d/existing-secret"; then
    for k in cookie-secret authenticated-emails; do
      kubectl -n elastic get secret kibana-oauth -o "jsonpath={.data.$k}" \
        | base64 -d > "$d/$k"
      test -s "$d/$k" || { echo "ERROR: kibana-oauth.$k 없음"; exit 1; }
    done
  else
    python3 -c 'import os,base64,sys;sys.stdout.write(base64.urlsafe_b64encode(os.urandom(32)).decode())' > "$d/cookie-secret"
  fi
else
  echo "ERROR: kibana-oauth 존재 여부를 읽지 못함 — context/인증을 확인"; exit 1
fi

# ALLOWLIST_FILE이 지정되면 기존 목록 대신 그 파일을 사용한다. 지정하지 않은
# 재실행은 기존 목록을 보존하며, Secret이 없으면 명시적 파일 없이는 생성하지 않는다.
if test -n "${ALLOWLIST_FILE:-}"; then
  test -f "$ALLOWLIST_FILE" || { echo "ERROR: ALLOWLIST_FILE을 읽을 수 없음"; exit 1; }
  cp "$ALLOWLIST_FILE" "$d/authenticated-emails"
elif ! test -s "$d/existing-secret"; then
  echo "ERROR: 최초 생성에는 ALLOWLIST_FILE=/안전한/경로/approved-emails 지정 필요"; exit 1
fi
awk 'BEGIN { ok=1; n=0 } { sub(/\r$/, ""); if ($0 == "" || $0 ~ /^#/) next; if ($0 !~ /^[^[:space:]@]+@[^[:space:]@]+$/) ok=0; n++ } END { if (!ok || n == 0) exit 1; print "authenticated-emails format OK, entries=" n }' "$d/authenticated-emails" \
  || { echo "ERROR: authenticated-emails는 빈 줄·# 주석 외에 한 줄당 이메일 하나여야 함"; exit 1; }

kubectl create secret generic kibana-oauth -n elastic \
  --from-file=client-id="$d/client-id" \
  --from-file=client-secret="$d/client-secret" \
  --from-file=cookie-secret="$d/cookie-secret" \
  --from-file=authenticated-emails="$d/authenticated-emails" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -rf "$d"; trap - EXIT

kubectl rollout restart deployment/kibana-oauth-proxy -n elastic
kubectl rollout status deployment/kibana-oauth-proxy -n elastic --timeout=120s
)
```

반영 검증(값 비노출): `scripts/verify-oauth-clients.sh <k8s-context> <project-id>` — 5종 프리픽스·SM 해시 일괄 대조(#439).

접속:

```bash
kubectl -n elastic port-forward svc/kibana-oauth-proxy 4181:4180
# 브라우저: http://localhost:4181 → sign-in → Google 로그인 → Kibana
```

client 자격만 갱신할 때는 `ALLOWLIST_FILE` 없이 위 블록을 다시 실행한다. 기존
`authenticated-emails`와 `cookie-secret`이 모두 보존된다. 최초 생성 또는 이메일 목록을
의도적으로 바꿀 때만 승인 이메일만 담은 로컬 비추적 파일을 준비해
`ALLOWLIST_FILE=/안전한/경로/approved-emails`로 지정한 뒤 위 블록을 실행한다.
파일은 저장소·채팅·명령행 인자에 넣지 않는다. allowlist 갱신만으로 전원 재로그인을
유발하지 않는다.

허용 목록에서 한 사용자를 제거할 때는 목록을 갱신하고 위 rollout 완료를 확인한다.
oauth2-proxy는 보호된 요청마다 세션 이메일을 새 allowlist로 재검사하므로, 이 경우
cookie-secret을 바꿔 전원 재로그인을 시킬 필요가 없다.

### 전원 세션 무효화 (cookie-secret 회전)

cookie-secret 유출 의심이나 전원 강제 로그아웃이 필요한 경우에만 아래 절차를 쓴다.
기존 client 자격과 허용 이메일은 값 비노출 파일로 보존한 채 cookie-secret만
회전하고 rollout 완료까지 확인한다. 대화형 셸 자체가 종료되지 않도록 명령 전체는
subshell에서 실행된다.

```bash
(
set -euo pipefail
umask 077
d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
for k in client-id client-secret authenticated-emails; do
  kubectl -n elastic get secret kibana-oauth -o "jsonpath={.data.$k}" \
    | base64 -d > "$d/$k"
  test -s "$d/$k" || { echo "ERROR: kibana-oauth.$k 없음"; exit 1; }
done
python3 -c 'import os,base64,sys;sys.stdout.write(base64.urlsafe_b64encode(os.urandom(32)).decode())' \
  > "$d/cookie-secret"
kubectl create secret generic kibana-oauth -n elastic \
  --from-file=client-id="$d/client-id" \
  --from-file=client-secret="$d/client-secret" \
  --from-file=cookie-secret="$d/cookie-secret" \
  --from-file=authenticated-emails="$d/authenticated-emails" \
  --dry-run=client -o yaml | kubectl apply -f -
rm -rf "$d"; trap - EXIT
kubectl rollout restart deployment/kibana-oauth-proxy -n elastic
kubectl rollout status deployment/kibana-oauth-proxy -n elastic --timeout=120s
)
```

완료된 rollout 뒤에는 기존 cookie가 검증되지 않아 모든 사용자가 다시 로그인해야 한다.

**접근 경로·break-glass**: 사람 접근은 proxy(4181로 노출되는 Service 4180)로 강제한다
— `elastic-ingress`는 노드→5601 직접 경로를 열지 않는다(proxy→Kibana는 same-ns라 정상).
anonymous를 폐기(#325)해 Kibana 5601은 이제 항상 basic 로그인을 요구하므로 무인증
우회 위험은 없지만, proxy를 단일 접근 경로로 유지한다. proxy 장애·`kibana-oauth`
미주입 시 operator break-glass는 `elastic-ingress`에 5601 ingress를 임시로 되살린 뒤
(terraform 또는 `kubectl`) `elastic`로 직접 접속하고 복구 후 되돌린다.

## 로그 수집 (#100)

| 항목 | 값 | 비고 |
|---|---|---|
| 수집기 | Filebeat (ECK `Beat` CR, DaemonSet) | Elastic Agent 대신 단일 용도로 단순화(#96) |
| 수집 범위 | **`airflow`·`autoresearch` namespace 컨테이너 로그 + `elastic` ns의 filebeat 컨테이너(자기 로그, #365)** | autodiscover 조건 allowlist. 그 외 시스템/플랫폼 로그는 Cloud Logging 담당 — 중복 수집 방지 기준(#96 역할 분리) |
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

**적용은 선언식이다(리뷰 반영)**: policy JSON은 `filebeat-ilm-policy`
ConfigMap(Terraform 관리)에 있고, filebeat이 `setup.ilm.overwrite`로 기동
시마다 재적용한다 — ES 재구축·policy 유실 시에도 수동 개입 없이 복원된다.
운영자는 확인만 한다(port-forward + elastic 인증 후):

```bash
curl -sk -u "elastic:$PW" https://localhost:19200/_ilm/policy/filebeat
curl -sk -u "elastic:$PW" "https://localhost:19200/.ds-filebeat-*/_ilm/explain?only_errors=true"
```

PVC 가득참 방어는 시간 기준 delete만이 아니다: ES disk watermark
(flood_stage 95%)가 인덱스를 read-only로 전환해 노드를 보호하고, PVC
사용량은 모니터링 대상 지표(OBSERVABILITY_STRATEGY)다.

filebeat 템플릿의 replicas 0은 Beat config(`setup.template`)가 관리하지만,
**이미 생성된 backing index**에는 소급되지 않으므로 1회 수동 적용한다:

```bash
curl -sk -u "elastic:$PW" -X PUT "https://localhost:19200/.ds-filebeat-*/_settings" \
  -H 'Content-Type: application/json' -d '{"index.number_of_replicas": 0}'
```

## Snapshot 백업 (#102)

| 항목 | 값 | 비고 |
|---|---|---|
| bucket | dev root `es-snapshots` bucket | age lifecycle **없음**(증분 구조 손상 방지) + **soft delete 7d**(#176 — 삭제 객체 복구 창). 정리는 SLM retention |
| 인증 | KSA `elasticsearch` → GSA(WI, 키 없음) | repository-gcs가 ADC(metadata)로 가장. bucket 단위 objectAdmin + legacyBucketReader만 |
| 주기/보관 | SLM 일 1회(18:30 UTC = 03:30 KST), expire 7d (min 3 / max 14) | 복구 창 성격은 #96 — 최근 데이터 복구 전용, 장기 보관 아님 |

repository 등록과 SLM policy는 ES 내부 리소스라 운영자 절차로 관리한다
(1회 등록, 유실 시 재등록 — 상태 확인은 정기 점검):

```bash
# 1) repository 등록 + 검증 (verify가 bucket 권한/경로를 end-to-end 확인)
curl -sk -u "elastic:$PW" -X PUT https://localhost:19200/_snapshot/gcs_snapshots   -H 'Content-Type: application/json' -d '{
  "type": "gcs",
  "settings": { "bucket": "autoresearch-503903-autoresearch-dev-es-snapshots" }
}'

# 2) SLM policy (일 1회 03:30 KST, 7일 보관)
curl -sk -u "elastic:$PW" -X PUT https://localhost:19200/_slm/policy/daily-snapshots   -H 'Content-Type: application/json' -d '{
  "schedule": "0 30 18 * * ?",
  "name": "<daily-snap-{now/d}>",
  "repository": "gcs_snapshots",
  "config": { "include_global_state": false },
  "retention": { "expire_after": "7d", "min_count": 3, "max_count": 14 }
}'

# 3) 상태 확인 (정기 점검 항목)
curl -sk -u "elastic:$PW" https://localhost:19200/_slm/policy/daily-snapshots
curl -sk -u "elastic:$PW" "https://localhost:19200/_snapshot/gcs_snapshots/_all?verbose=false" | head
```

### 복구 절차 (#102 완료 조건)

> 주의(#359): SLM 정책은 `include_global_state: false`이고 아래 절차는
> `.ds-filebeat-*`만 restore하므로 **Kibana saved object(`.kibana*`)는
> 스냅샷·복구 범위 밖**이다. saved object는 apply 시
> `kibana_saved_objects.tf` Job이 저장소 ndjson에서 자동 복원한다(#365 —
> 수동 import는 폴백).

```bash
# 1) snapshot 목록에서 대상 확인
curl -sk -u "elastic:$PW" "https://localhost:19200/_snapshot/gcs_snapshots/_all?verbose=false"

# 2) 손상된 data stream/index 정리 후 복구 (예: filebeat data stream)
curl -sk -u "elastic:$PW" -X POST   "https://localhost:19200/_snapshot/gcs_snapshots/<snapshot-name>/_restore"   -H 'Content-Type: application/json' -d '{
  "indices": ".ds-filebeat-*",
  "include_global_state": false
}'

# 3) 복구 후 health green + 문서 수 확인
```

**객체 삭제 사고 복구(#176 soft delete)**: 실수/오작동으로 snapshot 객체가
삭제된 경우, GCS soft delete가 7일간 보관한다. objectAdmin 자격으로도
보관 기간 내 조기 purge가 불가능하다(GCS는 soft-deleted 객체의 강제 삭제
API를 제공하지 않는다 — 보관 만료 후 자동 삭제만). 복구는 개별 객체가
아니라 **삭제된 관련 객체 전체를 함께 restore**해야 한다(증분 세그먼트 +
`index-N` 메타데이터가 일관된 시점으로 돌아가야 repository가 유효). 절차:
`gcloud storage restore`로 해당 시점 삭제분을 일괄 복구 → ES에서
`_snapshot/gcs_snapshots/_verify`로 재검증 → snapshot 목록 정합 확인.
부분 복구는 repository 손상을 남길 수 있으니 피한다.

전체 유실(PVC 소실) 시: ES 재기동(빈 클러스터) → repository 재등록 →
restore 순서. repository 등록만 하면 기존 bucket의 snapshot을 그대로
읽을 수 있다.

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
| egress | `169.254.169.254/32`:80, `169.254.169.252/32`:987-988 | WI metadata 경로(#102 snapshot — vault와 동일 근거 #126/#127) |
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

Kibana saved object(data view·저장 검색·Logs Overview 대시보드)는 `.kibana`
시스템 인덱스에 살고 아래 SLM 스냅샷 범위 밖이라, 저장소의
`kibana-saved-objects/logs-overview.ndjson`이 유일한 복구 원본이다.
**#365부터 자동 import** — `kibana_saved_objects.tf`의 Job이 ndjson 해시가
바뀔 때(파일 변경)와 완전 재구성 시 `_import?overwrite=true`(멱등)를
실행한다(Kibana 기동 전이면 선폴링+backoff로 흡수). **파일이 그대로인 채
객체만 삭제된 경우 apply는 No changes** — 복원 강제는
`terraform apply -replace=kubernetes_job_v1.kibana_saved_objects_import`.
수동 import는 폴백: Stack Management → Saved Objects → Import.

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
