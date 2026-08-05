# ArgoCD main 변경 자동 sync 설계

## 목적

사람이 검토한 배포 manifest를 infra `main`에 merge하면 ArgoCD가 이를 감지해 자동
sync한다. 이미지 digest를 별도 Bot이나 자동 PR로 갱신하지 않는다.

## 결정

- serving·MLflow와 동일하게 Agent Orchestration Application도 `targetRevision=main`과
  `automated { prune=false, selfHeal=false }`를 사용한다.
- 고정 SHA를 요구하던 `agent_orchestration_target_revision`과 GitHub Variable
  `AGENT_ORCHESTRATION_TARGET_REVISION` 의존성을 제거한다.
- `agent_orchestration_deployment_enabled`는 Application 자체를 비활성 ref로 돌리는
  비상 차단 스위치로 유지한다. enabled=true일 때만 main을 추적한다.
- Terraform apply는 Application spec을 이 새 정책으로 전환하는 **최초 한 번만**
  필요하다. 이후 manifest merge에는 Terraform apply가 필요 없다.

## 안전 경계

- main merge 자체는 기존 PR·CI·ruleset 검토를 거친다.
- ArgoCD는 prune·self-heal을 하지 않으므로 삭제와 live drift 강제 복구는 자동화하지 않는다.
- DB migration, OAuth·Secret 변경, IAM·NetworkPolicy 변경은 같은 main merge에서
  자동 sync될 수 있으므로 해당 PR의 검증과 rollback 정보를 필수로 남긴다.
- rollback은 이전 정상 manifest commit을 revert/새 PR로 main에 반영하고 ArgoCD 상태를
  확인한다. 긴급 중지는 enabled=false 설정과 reviewed admin apply를 사용한다.
