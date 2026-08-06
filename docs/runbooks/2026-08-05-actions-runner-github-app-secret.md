# 셀프 호스티드 러너(ARC) GitHub App 자격 증명 주입 (#533)

ARC(Actions Runner Controller) 스케일셋이 GitHub Actions API를 호출하려면
GitHub App 자격 증명이 필요하다. Terraform은 Secret Manager 컨테이너만
만들고(`terraform/envs/dev/actions_runner.tf`) 값 자체는 관리하지 않는다 —
GitHub App 생성은 조직 GitHub UI에서 운영자가 수동으로 먼저 해야 한다.

이 절차는 `argocd_google_oidc_client`(#289)·grafana OAuth(#439) 패턴과
동일하다: Secret Manager가 정본, 값 주입은 사람이 `gcloud`/`kubectl`로 직접
한다. 컨트롤러/러너 GSA에는 `secretmanager.secretAccessor`를 부여하지
않는다.

## 1. GitHub App 생성 (조직 GitHub UI, 수동, 1회)

1. 조직 Settings → Developer settings → GitHub Apps → New GitHub App.
2. Repository permissions: **Actions: Read and write**,
   **Administration: Read and write**. `Administration`은 repo 범위 App
   권한 중 가장 강한 축으로 branch protection/ruleset 수정, 저장소 설정
   변경까지 포함하지만, repo 범위 셀프 호스티드 러너 등록·해제 API가
   요구하는 최소 권한이라 채택한다(#533 리뷰). org 수준 설치 +
   `Organization self-hosted runners: Read and write`로 `Administration`
   없이 우회하는 대안도 있으나, org 전체 러너 관리 권한을 얻는 쪽이라 이
   PoC(repo 하나 범위)에는 더 넓은 권한이 된다 — 채택하지 않는다. 그 외
   권한은 추가하지 않는다.
   - **blast radius**: 이 App private key가 유출되면 `SKYAHO/Autoresearch-infra`
     저장소의 설정·branch protection·러너 등록을 임의로 바꿀 수 있다(코드
     자체를 push할 권한은 없음 — `contents` 권한 미부여). 유출 의심 시
     GitHub App 설정에서 즉시 **Generate a private key**로 키를 폐기하고,
     2~3단계를 반복해 새 키로 교체한다.
3. Webhook은 비활성화한다(ARC 컨트롤러가 직접 poll — 이 PoC 범위에서는
   webhook 불필요).
4. 생성 후 **App ID**를 기록한다.
5. `SKYAHO/Autoresearch-infra` 저장소에만 App을 설치(Install)하고
   **Installation ID**를 기록한다(설치 후 URL의 숫자,
   `github.com/settings/installations/<id>`).
6. **Generate a private key**로 `.pem` 파일을 내려받는다. 이 파일은
   Git·Slack·이슈 등 어디에도 올리지 않는다.

## 2. Secret Manager 값 채우기

Terraform이 만든 빈 컨테이너 3개(`actions-runner-github-app-id`,
`actions-runner-github-app-installation-id`,
`actions-runner-github-app-private-key`)에 값을 채운다.

```bash
umask 077
printf '%s' '<App ID>' | gcloud secrets versions add \
  actions-runner-github-app-id --project "$PROJECT_ID" --data-file=-

printf '%s' '<Installation ID>' | gcloud secrets versions add \
  actions-runner-github-app-installation-id --project "$PROJECT_ID" --data-file=-

gcloud secrets versions add actions-runner-github-app-private-key \
  --project "$PROJECT_ID" --data-file="<다운받은 .pem 파일 경로>"
```

`.pem` 파일은 값을 옮긴 뒤 즉시 삭제한다(`rm -f`, 또는 `shred -u`).

## 3. Kubernetes Secret 생성

ARC 스케일셋 chart는 `githubConfigSecret: actions-runner-github-app`
(pre-defined secret, `deploy/actions-runner-scale-set/values.yaml`)로 이
Secret을 참조한다. key 이름은 chart가 요구하는 이름
(`github_app_id`/`github_app_installation_id`/`github_app_private_key`)을
그대로 써야 한다.

Private key는 여러 줄(PEM)이라 `--from-env-file`(#213 기본 컨벤션, 한 줄
`KEY=VALUE`만 지원)로는 옮길 수 없다. `--from-file`로 각 key를 개별 파일에서
읽는다(agent-orchestration #525 런북과 동일 패턴) — 이 역시 셸 히스토리에
값을 남기지 않는다.

```bash
umask 077
sdir="$(mktemp -d)"          # 고정 경로 금지 — 공유 호스트 심링크/선점 위험
trap 'rm -rf "$sdir"' EXIT

for key in github_app_id github_app_installation_id github_app_private_key; do
  secret_id="actions-runner-${key//_/-}"
  gcloud secrets versions access latest \
    --secret "$secret_id" --project "$PROJECT_ID" > "$sdir/$key"
  test -s "$sdir/$key" || { echo "ERROR: $key 정본 비어 있음 — 2단계 먼저"; exit 1; }
done

kubectl -n actions-runner create secret generic actions-runner-github-app \
  --from-file=github_app_id="$sdir/github_app_id" \
  --from-file=github_app_installation_id="$sdir/github_app_installation_id" \
  --from-file=github_app_private_key="$sdir/github_app_private_key" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -rf "$sdir"; trap - EXIT
```

`--dry-run=client -o yaml | kubectl apply -f -`를 쓰는 이유는 재발급 시에도
멱등하기 위해서다(`create` 단독은 이미 Secret이 있으면 `AlreadyExists`로
실패한다).

## 4. 반영 확인

ARC 스케일셋 리스너(`AutoscalingListener`) Pod는 이 Secret을 시작 시에만
읽는다. 리스너는 컨트롤러가 직접 만드는 **단독 Pod**라 Deployment가 없다 —
`kubectl rollout restart deployment`는 대상을 찾지 못하고
`no resources found`로 끝난다(#533 리뷰). 리스너 Pod를 지우면 컨트롤러가
새 Secret 값으로 즉시 재생성한다:

```bash
kubectl -n actions-runner delete pod \
  -l actions.github.com/scale-set-name=actions-runner-poc,app.kubernetes.io/component=runner-scale-set-listener
```

라벨 셀렉터는 스케일셋 배포(Task 4 ArgoCD Application) 이후
`kubectl -n actions-runner get pods --show-labels`로 실제 값을 확인하고
필요하면 위 명령을 갱신한다. `set -e`가 없는 절차이므로 이 명령이 실패해도
스크립트는 계속 진행된다 — 출력에서 `deleted`를 직접 확인한다.

## 5. feast-apply 스케일셋을 위한 설치 범위 확장 (#541, 수동, 1회)

`feast-apply-dev`/`feast-apply-prod` 러너 스케일셋은 이 저장소가 아니라 앱
저장소(`SKYAHO/Autoresearch`, `feast-apply.yml`이 있는 곳)를 대상으로 job을
받는다(`deploy/actions-runner-scale-set-feast-{dev,prod}/values.yaml`의
`githubConfigUrl`). 이 App은 1단계에서 `Autoresearch-infra`에만 설치했으므로,
같은 계정(`SKYAHO`) 소유 저장소인 `Autoresearch`도 접근 범위에 추가해야 한다:

1. `github.com/settings/installations/<Installation ID>`(1단계 5번에서 기록한
   값) → **Configure**.
2. "Repository access"에서 "Only select repositories"를 유지한 채
   `SKYAHO/Autoresearch`를 추가로 선택하고 저장한다.
3. Installation ID·App ID·Private key는 바뀌지 않는다 — Secret Manager,
   K8s Secret 어느 쪽도 갱신할 필요가 없다.

이 단계 전에는 feast-dev/prod 스케일셋의 리스너 Pod는 뜨지만, 앱 저장소가
보낸 job을 전혀 받지 못한다(등록된 저장소가 아니라서 GitHub이 job을 배정하지
않음 — 실패가 아니라 무한 대기로 관측된다).

## 6. 리스너/컨트롤러 라벨 drift 점검 (#559)

`terraform/admin/actions-runner-k8s`의 K8s API egress `NetworkPolicy` 2개
(`actions_runner_control_plane_k8s_api_egress`,
`actions_runner_poc_k8s_api_egress`)는 ARC가 Pod 생성 시 주입하는
`app.kubernetes.io/component`/`actions.github.com/scale-set-name` 라벨로
스코프돼 있다(#557). 이 라벨은 Helm values가 아니라 gha-rs 컨트롤러/chart가
정하므로, 업그레이드로 값이 바뀌면 정책이 조용히 매칭을 잃고 리스너가
crash-loop한다(즉시 에러가 아니라 job이 안 집히는 상태로만 관측됨, #557에서
실제 발생).

`actions-runner-k8s` 변경 apply 후, 또는 gha-rs 컨트롤러/chart 버전을 올린
직후 확인한다:

```bash
kubectl -n actions-runner get pods -l app.kubernetes.io/component=runner-scale-set-listener
# 스케일셋 개수만큼(현재 3개: actions-runner-poc, feast-apply-dev, feast-apply-prod)
# RESTARTS 0 나오는지 확인

kubectl -n actions-runner get pods -l app.kubernetes.io/component=controller-manager
# 컨트롤러 매니저 1개, RESTARTS 0 확인
```

둘 중 하나라도 예상 개수보다 적게 나오거나 `RESTARTS`가 늘어나면, 해당 Pod가
라벨 값 변경으로 두 `NetworkPolicy` 어디에도 걸리지 않아 apiserver 접근이
막혔을 가능성이 크다 — `kubectl get pods -n actions-runner --show-labels`로
실제 라벨 값을 확인하고 `main.tf`의 `pod_selector`를 갱신한다.

## 범위 밖

- App 권한 확장(웹훅, 조직 전체 설치 등)은 이 PoC 범위가 아니다(저장소 단위
  접근 범위 확장은 5단계에서 다룸 — 조직 전체 설치와는 다르다).
- Private key 로테이션 자동화는 다루지 않는다. `.pem`은 Secret Manager와
  K8s Secret 양쪽에 모두 저장되므로, 키를 재발급했다면 둘 다 새 값으로
  갱신해야 한다 — 2단계(Secret Manager)부터 3단계(K8s Secret), 4단계(리스너
  Pod 재기동으로 반영 확인)까지 순서대로 그대로 반복한다.
- GSA에 `secretmanager.secretAccessor`를 부여하는 대안은 채택하지 않는다
  (`argocd_google_oidc_client` 패턴 유지, Task 1 설계 근거 참조).
