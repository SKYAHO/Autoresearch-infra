# Vault 운영 Runbook (dev)

dev GKE의 Vault(`vault` namespace, #132/#134) 운영 절차. 설치 구성은
`terraform/admin/vault-k8s/README.md`, 설계는
`docs/superpowers/specs/2026-07-12-vault-dev-design.md` 참조.

전제: `gcloud` 인증과 dev GKE `kubectl` 컨텍스트(팀 절차는
`TEAM_OPERATIONS_RUNBOOK.md`).

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
   절대 남기지 않는다.** 팀 비밀번호 관리 경로로만 보관한다.
2. 터미널 스크롤백을 정리한다.
3. 초기 설정(audit, auth, policy) 완료 후 root token을 revoke한다:

```bash
vault token revoke <root-token>
# 이후 root 권한이 필요하면 recovery key로 재생성:
# vault operator generate-root
```

## audit device 활성화 (init 직후 권장)

```bash
vault audit enable file file_path=/vault/audit/audit.log
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

`terraform/admin/vault-k8s/README.md`의 롤백 절차를 따른다. 순서 요약:
release 제거 → PVC 정리 → (필요 시에만) dev root KMS key 정리. 순서를
어기면 Raft 데이터 복호화가 영구 불능이 된다.
