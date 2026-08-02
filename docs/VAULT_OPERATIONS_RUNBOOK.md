# Vault 운영 Runbook (dev)

> ⚠️ **폐기(#412, 2026-07-29 드랍 확정) → 코드 제거 완료 / state 정리
> 대기(#478)**: Vault는 dev에서 더 진행하지 않는다. 새 클러스터(#404 이전
> 후)에는 helm release·`vault` namespace가 존재하지 않았고, admin-apply
> ROOTS에서도 제외됐다(#416). #478에서 `terraform/envs/dev/vault.tf`와
> `terraform/admin/vault-k8s/` root 코드를 완전히 삭제했다 — 남은 GCP/K8s
> state 정리(dev root는 `kms_vault_orphan.tf` 유지 + 잔여 4개 destroy apply,
> vault-k8s는 `terraform state rm`)는 별도 승인 후 진행한다. 아래 내용은
> 실행 불가한 **이력 보존용**이며,
> 실 서비스 secret은 GCP Secret Manager가 담당한다.

dev GKE의 Vault(`vault` namespace, #132/#134) 운영 절차. 설치 구성 문서는
#478에서 root와 함께 삭제됐다(필요 시 `git log --diff-filter=D --
terraform/admin/vault-k8s` 이후 git history 참조). 설계는
`docs/superpowers/specs/2026-07-12-vault-dev-design.md` 참조.

전제: `gcloud` 인증과 dev GKE `kubectl` 컨텍스트(팀 절차는
`TEAM_OPERATIONS_RUNBOOK.md`).

## ⚠️ 하드 게이트: 실 secret 이관 전 TLS 필수 (#177)

현재 Vault listener는 **평문(TLS 비활성)** 이다. API 토큰과 secret payload가
클러스터 네트워크를 평문으로 이동한다. 아래를 **모두** 만족하기 전에는
**실 서비스 secret을 절대 저장하지 않는다** — 지금은 더미 값(hello-vault-dev)만
허용한다.

**현재 노출 표면(위협 모델)**: consumer가 없다. vault namespace의
NetworkPolicy ingress는 (a) 같은 namespace pod (b) 노드 대역 → 8200
(port-forward)만 허용한다. #177에서 **kube-system 전체 포트 허용 규칙을
제거**해, 이전에 존재하던 "kube-system의 모든 pod가 8200 평문 접근" 예외를
닫았다. port-forward 경로의 TLS 구분: 로컬 kubectl → kube-apiserver(TLS) →
kubelet(apiserver-kubelet TLS) → **kubelet → vault pod:8200(노드 로컬,
평문)**. 즉 평문 구간은 **kubelet과 vault pod 사이의 노드 내부 홉**뿐이며,
실제 위험은 "vault pod가 뜬 노드에 침투한 주체의 로컬 스니핑"으로 국한된다.
실 secret이 없는 한 탈취할 값도 없다. 위험이 실체화되는 시점은 **consumer
워크로드가 붙어 평문 secret 트래픽이 네트워크를 가로지를 때**이며, 그 전에
아래 게이트를 통과해야 한다.

**실 secret 이관 체크리스트 (전부 필수)**:

- [ ] Vault TLS 활성화 (`global.tlsDisable: false` + 인증서 신뢰·회전 자동화 —
      cert-manager 또는 Vault PKI, 별도 설계 이슈)
- [ ] consumer 연동 방식 확정 (직접 연동 시 양쪽 NetworkPolicy, 또는 ESO)
- [ ] audit device 활성 + 로그 수집 경로 확인
- [ ] 실 secret과 Secret Manager의 역할 경계 재확인 (무엇을 Vault로, 무엇을
      Secret Manager에 남길지)

이 게이트를 통과하지 않은 상태의 Vault는 **학습·검증 전용**이다. 실
서비스 secret은 계속 GCP Secret Manager가 담당한다.

## 접속 (내부 전용)

Vault UI/API는 인터넷에 공개하지 않는다. 접근은 kubectl port-forward만 사용한다.

```bash
kubectl -n vault port-forward svc/vault 8200:8200
# UI: http://localhost:8200  (TLS는 1단계 비활성 — 실 secret 저장 금지)
```

CLI 사용 시:

```bash
export VAULT_ADDR=http://localhost:8200
```

## 상태 확인

```bash
kubectl -n vault get pods
kubectl -n vault exec vault-0 -- vault status
```

정상 기준: `Initialized true`, `Sealed false`, `Recovery Seal Type gcpckms`
(KMS auto-unseal은 Sealed가 재기동 후에도 자동으로 false가 된다).

## 최초 init (1회)

최초 apply는 pod가 uninitialized 상태에서도 Ready(health `uninitcode=204`)로
완료된다. apply가 끝난 뒤 아래 init을 실행한다. auto-unseal 구성이므로
unseal key 대신 **recovery key**가 발급된다.

```bash
kubectl -n vault exec vault-0 -- vault operator init \
  -recovery-shares=3 -recovery-threshold=2
```

출력물 처리 (보안 최우선):

1. **root token과 recovery keys를 Git/PR/채팅/Terraform state/일반 파일에
   절대 남기지 않는다.** 팀 비밀번호 관리(비밀번호 관리자, macOS 키체인 보안
   메모 등) 경로로만 보관한다.
2. 터미널 스크롤백을 정리한다(⌘+K 또는 창 닫기 — `clear`는 스크롤백에
   기록이 남는다).
3. 아래 "초기 구성"을 완료한 뒤 root token을 revoke한다. auth method가
   구성되기 전에 revoke하면 관리 접근이 recovery key `generate-root`에만
   의존하게 되므로 순서를 지킨다.

## 초기 구성 (#136, init 후 1회)

root token으로 audit, Kubernetes auth, KV v2, 최소 권한 policy를 구성한다.
init 출력물을 회수한 운영자가 직접 실행한다.

```bash
kubectl -n vault exec -it vault-0 -- sh

vault login   # 프롬프트에 root token 입력 (화면 미표시)

# 1) audit device (file)
vault audit enable file file_path=/vault/audit/audit.log

# 2) Kubernetes auth method. chart 기본값(server.authDelegator.enabled=true)이
#    vault KSA에 TokenReview 권한(ClusterRoleBinding)을 이미 부여한 상태다.
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"

# 3) KV v2 engine
vault secrets enable -path=secret kv-v2

# 4) 최소 권한 policy + Kubernetes auth role (시범: 읽기 전용)
vault policy write demo-read - <<'POLICY'
path "secret/data/demo/*" {
  capabilities = ["read"]
}
POLICY

vault write auth/kubernetes/role/demo-reader \
  bound_service_account_names=default \
  bound_service_account_namespaces=vault \
  policies=demo-read \
  ttl=1h

# 5) 시범 secret (더미 값만 — TLS 활성화 전 실 secret 저장 금지)
vault kv put secret/demo/sample message="hello-vault-dev"

# 6) 초기 구성 완료 후 root token revoke
vault token revoke -self
exit
```

이후 root 권한이 필요하면 recovery key로 재생성한다:
`vault operator generate-root`.

**consumer 범위 주의**: NetworkPolicy가 타 namespace → vault:8200을
차단하므로, Kubernetes auth consumer는 현재 vault namespace 내부로
한정된다. 타 namespace 워크로드(airflow 등) 연동은 ingress 허용 추가 또는
External Secrets Operator 도입을 별도 설계로 다룬다.

## Kubernetes auth 동작 검증 (root token 불필요)

vault namespace의 KSA JWT로 로그인해 시범 secret을 읽는다.

주소는 반드시 headless service(`vault-internal`, pod IP 직결)를 쓴다.
service VIP(`vault.vault.svc`)는 vault ns 내부 pod의 egress도 pre-DNAT
평가(#122)에 걸려 8200이 차단된다(같은 ns pod IP 직결만 허용).

```bash
kubectl -n vault run vault-auth-test --rm -i --restart=Never \
  --image=badouralix/curl-jq --overrides='{"spec":{"serviceAccountName":"default"}}' \
  -- sh -c '
JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
TOKEN=$(curl -s -X POST http://vault-internal.vault.svc:8200/v1/auth/kubernetes/login \
  -d "{\"role\":\"demo-reader\",\"jwt\":\"$JWT\"}" | jq -r .auth.client_token)
curl -s -H "X-Vault-Token: $TOKEN" \
  http://vault-internal.vault.svc:8200/v1/secret/data/demo/sample | jq .data.data'
# 기대 출력: {"message": "hello-vault-dev"}
```

## 재기동 시 auto-unseal 확인

pod가 재시작되면 KMS로 자동 unseal된다. 수동 개입이 필요 없어야 정상이다.

```bash
kubectl -n vault delete pod vault-0
kubectl -n vault wait --for=condition=Ready pod/vault-0 --timeout=180s
kubectl -n vault exec vault-0 -- vault status   # Sealed false 확인
```

## 장애 대응

| 증상 | 원인 후보 | 확인/조치 |
|---|---|---|
| pod가 seal 초기화에서 crash | KMS 접근 실패 | `kubectl -n vault logs vault-0`에서 gcpckms 오류 확인. dev root #132(GSA/WI/key) apply 여부, KSA annotation, NetworkPolicy metadata 경로(987/988) 확인 |
| `permission denied` (KMS) | WI principal 불일치 | dev root `vault_k8s_namespace`/`vault_k8s_service_account`와 이 root의 namespace/release name 일치 확인 |
| DNS 실패 | egress 경계 | services CIDR 53 규칙(#122 교훈) 확인 |
| Sealed true 지속 | KMS key version disable/destroy됨 | **key version을 복구(re-enable)해야만 unseal 가능.** rotation(새 version 추가)은 무해하지만 이전 version 제거는 영구 불능을 만든다 |
| port-forward 접속 불가 | ingress 경계 | 노드 대역 → 8200 규칙 확인 |

## 정기 점검

- `vault status`로 Sealed false 확인
- KMS key rotation(90d)은 자동이며 unseal에 영향 없다 — **이전 key version을
  수동으로 disable/destroy하지 않는다**
- audit log 용량(PVC 5Gi) 확인

## 폐기/롤백

설치 구성 문서(`terraform/admin/vault-k8s/README.md`)는 #478에서 root와
함께 삭제됐다 — 필요 시 git history에서 복원한다. 순서 요약: release
제거 → PVC 정리 → (필요 시에만) dev root KMS key 정리. 순서를 어기면
Raft 데이터 복호화가 영구 불능이 된다.

## 머지~승인 apply 사이 예상 drift (claude-review 9/10차 지적, #478)

`terraform/envs/dev/vault.tf` 삭제(#478) 머지 후, 승인 apply(`kms_vault_orphan.tf`의
rotation 제거 update + 아래 4개 destroy)를 실행하기 전까지는
`terraform-drift.yml`이 매일 09:23 KST에 **아래 5개 리소스**를 drift로
감지한다 — `google_kms_crypto_key.vault_unseal`도 포함된다(claude-review
10차 지적으로 정정: 머지 직후 config에는 `rotation_period`가 이미 빠져
있지만 live/state에는 아직 기존 `rotation_period = "7776000s"`가 남아
있으므로, 이 리소스도 **in-place update 대상**으로 매일 plan에 함께
잡힌다 — 승인 apply가 실행해야 할 변경 자체가 정확히 이 상태다):

- `google_kms_crypto_key.vault_unseal` (in-place update, rotation 제거)
- `google_service_account.vault` (destroy)
- `google_service_account_iam_member.vault_wi` (destroy)
- `google_project_iam_custom_role.vault_unseal` (destroy)
- `google_kms_crypto_key_iam_member.vault_unseal` (destroy)

**동작**: `terraform plan -detailed-exitcode`는 이 1개 update + 4개
destroy 때문에 exitcode `2`를 반환한다. workflow의 "결과 판정" 스텝은
exitcode가 `0`이 아니면 무조건 `exit 1`이므로 **job 자체가 매일 실패
처리된다**(정상 동작, 실제 오류 아님). 이슈는 `[DRIFT] dev root
코드-인프라 불일치` 제목 + `bug`/`terraform`/`gcp` 라벨로 첫날 1회만
생성되고, 이후 매일은 라벨 필터로 그 기존 이슈를 찾아 코멘트만 추가한다
(같은 제목의 이슈가 매일 새로 생기지는 않는다).

**진짜 새 drift와 구분하는 방법**: 각 코멘트의 "변경 리소스 요약" 블록에는
resource 주소가 그대로 남는다(`will be destroyed`/`will be updated
in-place` 헤더 형태 — `terraform-drift.yml`의 allowlist 정규식
`# .+ will be `가 두 헤더 모두 매치한다). 매일 코멘트 내용이 정확히 위
5개 주소 + `Plan: 0 to add, 1 to change, 4 to destroy.`와 같다면 승인
apply 대기 중인 예상 drift다. **위 5개 주소 전부가 정확한 부분집합이고
그 외 주소가 하나도 없다면**(add는 항상 0이어야 함) — 5개 전부든,
승인 apply가 중간 실패해 일부만 반영된 뒤 남은 부분집합이든 — Vault
정리 관련 예상 drift로 취급한다(승인 apply가 정확히 이 5개 리소스만
건드리므로, 부분 실패해도 이 5개의 부분집합 밖으로 나가는 리소스는
생기지 않는다). **5개 주소 밖의 다른 리소스 주소가 하나라도 섞여
있으면** 그 부분만 Vault와 무관한 새 drift이므로 별도로 조사한다(5개
자체는 여전히 예상 drift로 무시한다 — 두 판단은 독립적이다). 승인
apply 완료 후에는 이 5개 리소스가 모두 수렴하므로(4개는 state에서
사라지고, crypto key는 in-place update가 반영돼 더 이상 diff가 없음)
이 절은 더 이상 적용되지 않는다 — apply 완료 후 첫 drift 실행이
exitcode 0(또는 다른 사유의 drift만 없음)인지 확인해 마무리한다.

**승인 apply 화면에서 `google_kms_key_ring.vault`가 안 건드려짐을
확인하는 방법(claude-review 14차 지적)**: 이번 승인 apply의 실제 plan도
위와 같은 allowlist를 거쳐 `apply.yml`의 `$GITHUB_STEP_SUMMARY`에
출력된다 — 나오는 줄은 정확히 위 5개 리소스 주소 헤더 +
`Plan: 0 to add, 1 to change, 4 to destroy.`뿐이다. Terraform plan은
액션이 있는 모든 리소스를 예외 없이 출력하므로, `google_kms_key_ring.vault`가
실제로 건드려졌다면 6번째 주소 줄로 나타난다 — 지금은 두 속성
(`name`/`location`)이 모두 불변이라 diff 자체가 없어 어떤 줄도 만들지
않는다(12차 지적 답변 참조). 즉 승인자는 "key_ring이라는 문자열이 안
보이는지" 대신 **"주소 줄이 정확히 5개이고 그 5개가 전부 위 목록과
일치하는지, Plan: 요약 숫자가 0/1/4인지"**로 확인한다 — 6번째 줄이
나타나거나 숫자가 다르면 key_ring을 포함해 무언가 예상 밖의 리소스가
이 apply에 섞였다는 뜻이다.

**dev root 전체를 destroy해야 하는 상황과 `prevent_destroy`의 상호작용
(claude-review 14차 지적)**: 프로젝트 이전이나 dev 환경 전체 재구축처럼
dev root를 통째로 destroy해야 하는 드문 상황에서는, `terraform destroy`
(또는 `terraform plan -destroy`)가 이 두 리소스를 destroy 대상에 포함하는
순간 **plan 계산 자체가 통째로 실패**한다 — Terraform은 plan을 리소스별로
부분 진행하지 않고 한 번에 계산하므로, 다른 리소스는 전혀 건드리지
못한 채 "Error: Instance cannot be destroyed"로 root 전체 destroy가
막힌다. 우회하려면 이 2개 리소스를 destroy 대상에서 명시적으로 빼야
한다 — `-target`으로 나머지 리소스만 지정하거나, 일회성 커밋으로 두
리소스의 `lifecycle { prevent_destroy = true }`를 제거한 뒤 destroy한다.
후자를 택해도 실제 GCP 동작은 리소스마다 다르다: `google_kms_key_ring`은
GCP에 삭제 API 자체가 없어 provider가 API를 호출하지 않고 state에서만
지운다(GCP 쪽 리소스는 그대로 남는다 — 지금의 orphan 상태와 동일).
반면 `google_kms_crypto_key` destroy는 실제로 모든 CryptoKeyVersion
파기를 예약하는 API를 호출한다(비가역). Vault가 이미 #412에서 영구
폐기됐고 다른 소비자가 없는 전체 teardown 시나리오라면 이 결과 자체는
받아들일 만하다 — `prevent_destroy`의 목적은 이 destroy를 영원히
금지하는 것이 아니라, dev root의 일상적인 변경(다른 리소스 추가/삭제)
도중 **의도치 않게** 함께 destroy되는 사고를 막는 것이다. 이 저장소에는
전체 teardown 전용 절차 문서가 아직 없다 — 실제로 그 상황이 오면 이
절을 시작점으로 삼는다.

**승인 apply 완료 후 검증**: rotation 해제가 실제로 반영됐는지는 이
apply의 plan/apply 요약만으로는 확인할 수 없다 — `next_rotation_time`이
이 리소스의 Terraform schema 속성이 아니라 drift 감지 범위 밖이기
때문이다(spec 문서의 "claude-review 13차 지적" 절 참조). 아래 gcloud
명령이 유일한 검증 수단이다:

```bash
gcloud kms keys describe vault-unseal \
  --keyring="${resource_prefix}-vault" --location=<region> \
  --project=<project_id> --format='value(rotationPeriod,nextRotationTime)'
```

두 값 모두 비어야 정상이다.

`google_kms_key_ring.vault`가 이 5개에 없는 이유(claude-review 12차
지적): key ring 리소스는 `name`/`location` 2개 속성만 schema에 있고
둘 다 생성 후 불변(ForceNew)이라 — 이 PR에서 어떤 속성값도 바꾸지
않았으므로 — config와 live state가 항상 일치해 plan에 diff 자체가
전혀 나타나지 않는다("추적 대상에서 뺐다"가 아니라 "속성 diff가 없어
plan에 나타날 수가 없다"). `prevent_destroy`는 여전히 걸려 있어 만약
key ring 자체가 config에서 사라지면(`removed` 블록 등) plan이 즉시
에러로 막힌다 — drift 목록에 없는 것과 삭제 방지가 걸려 있는 것은
별개다.

**머지 후 승인 apply 전, Vault와 무관한 다른 dev root apply가 먼저
승인·실행되는 경우**(claude-review 12차 지적): `apply.yml`의 dev root
apply는 그 시점 dev root 전체 plan을 적용하므로, 이 5개 변경은 그
apply가 무엇을 위해 트리거됐든 함께 반영된다 — 이는 문제가 아니라
정상 동작이다(config가 이미 머지돼 있는 이상 어느 apply가 먼저
실행되든 결과는 같다). 그 apply의 승인자가 plan 요약에서 이 5개를
식별하는 근거: 위 5개 리소스 주소는 전부 리소스 이름에 `vault`가
포함된다(`google_kms_crypto_key.vault_unseal`,
`google_service_account.vault`,
`google_service_account_iam_member.vault_wi`,
`google_project_iam_custom_role.vault_unseal`,
`google_kms_crypto_key_iam_member.vault_unseal`) — plan 요약(`GITHUB_STEP_SUMMARY`)이
리소스 주소를 그대로 노출하므로, 다른 PR의 변경과 섞여 있어도 주소에
`vault`가 있는 항목만 이 절의 대상으로 골라 확인하면 된다. 별도
자동화(예: CI에서 Vault 관련 항목만 분리해 강조 표시)는 두지 않는다 —
5개뿐인 소규모 목록이라 사람이 주소 문자열로 골라내는 것으로 충분하고,
자동화를 추가하면 이 정리가 끝난 뒤 곧바로 걷어내야 할 코드가 하나 더
생긴다.
