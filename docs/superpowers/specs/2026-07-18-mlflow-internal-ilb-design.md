# MLflow UI 내부 ILB 노출 설계 (#244)

> 관련 이슈: `SKYAHO/Autoresearch-infra#244`
> 대상 환경: dev
> 상태: 설계 + 1단계(예약 IP/DNS) 구현. Service flip은 apply·콘솔 등록 후 2단계.

## 1. 목표

MLflow UI/API 접근을 `kubectl port-forward`(oauth2-proxy 4180) 전용에서 **VPC
내부 전용 ILB + private DNS**로 확장한다. Airflow UI(#48)와 동일 패턴을 따르며,
인터넷 노출은 없다(접근은 Bastion #47 터널). 인증은 계속 oauth2-proxy(Google +
허용 이메일)가 앞단에서 강제한다.

## 2. 원칙 — 인증 경계 유지

- ILB는 **oauth2-proxy(4180)** 앞단에만 붙인다. `mlflow`(5000) Service는 절대
  ILB/외부로 노출하지 않고 ClusterIP 내부 전용을 유지한다(미인증 우회 차단).
- 따라서 브라우저 접근 경로는 `ILB VIP → oauth2-proxy → mlflow:5000`.
- GKE 내부 워크로드(SDK 기록)는 기존대로 `http://mlflow.mlflow:5000`(proxy 미경유,
  내부 전용)을 tracking URI로 쓴다. ILB는 사람의 UI 접근용이다.

## 3. 리소스 (Airflow #48 일관)

| 리소스 | 값 | 소유 |
| --- | --- | --- |
| 예약 내부 IP | `autoresearch-dev-mlflow-ilb`(SHARED_LOADBALANCER_VIP, dev subnet) | `terraform/envs/dev/dns.tf` |
| private zone | 기존 `internal` 재사용 | dev root |
| A 레코드 | `mlflow.dev.autoresearch.internal` → 예약 IP | dev root |
| output | `mlflow_ilb_ip`, `mlflow_internal_fqdn` | dev root |
| 내부 LB Service | oauth2-proxy(4180) 앞단, `loadBalancerIP` = 예약 IP | `deploy/mlflow` (ArgoCD) |

## 4. 단계 (하드 의존성 때문에 분리)

`loadBalancerIP`는 예약 IP 값(apply 전 미지)에, redirect URI 변경은 **콘솔 등록**에
하드 의존한다. 그래서 Airflow #48처럼 나눈다.

### 1단계 — 예약 IP + DNS (이 PR)

- `dns.tf`에 예약 IP + A 레코드, `outputs.tf`에 output 추가.
- apply(dev root, GCS state 쓰기 권한 운영자): `google_compute_address.mlflow_ilb`
  와 `google_dns_record_set.mlflow` 2개 add만 보여야 한다.

### 2단계 — Service flip + redirect (후속, 1단계 apply·콘솔 등록 후)

선행(사람만 가능): GCP 콘솔 OAuth client에 redirect URI
`http://mlflow.dev.autoresearch.internal/oauth2/callback` 추가.

`deploy/mlflow/oauth2-proxy.yaml`의 Service를 아래로 변경(예약 IP는
`terraform -chdir=terraform/envs/dev output -raw mlflow_ilb_ip`로 채운다):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mlflow-oauth-proxy
  namespace: mlflow
  annotations:
    networking.gke.io/load-balancer-type: "Internal"
spec:
  type: LoadBalancer
  loadBalancerIP: "<terraform output mlflow_ilb_ip 값>"
  selector:
    app.kubernetes.io/name: mlflow-oauth-proxy
  ports:
    - name: http
      port: 80
      targetPort: http   # 4180
```

같은 파일 Deployment의 `--redirect-url`을
`http://mlflow.dev.autoresearch.internal/oauth2/callback`로 변경. ArgoCD sync
후 반영. redirect URI 미등록 상태로 flip하면 Google 로그인 콜백이 실패하므로
콘솔 등록을 반드시 선행한다.

## 5. 보안

- ILB `Internal` → VPC 전용, 인터넷 노출 0. 접근은 Bastion(#47) 터널.
- 인증은 oauth2-proxy가 계속 강제(Google + 허용 이메일). `mlflow:5000` 미노출.
- L4 passthrough 평문(HTTP). dev MVP는 Airflow #48과 동일 수준으로 수용하고,
  운영 전환 시 L7 internal + TLS를 검토한다(`TERRAFORM_DEV.md` #48 주석 참조).

## 6. 롤백

- 2단계: Service를 ClusterIP로 되돌리면 ILB가 제거되고 port-forward 접근으로 복귀.
- 1단계: `google_dns_record_set.mlflow`·`google_compute_address.mlflow_ilb` 제거
  후 apply. 예약 IP는 다른 리소스가 참조하지 않을 때만 제거된다.

## 7. 완료 기준

- 팀원이 Bastion 터널로 `http://mlflow.dev.autoresearch.internal` 접속 시 Google
  로그인 후 MLflow UI 사용.
- `mlflow:5000`은 ClusterIP 유지(외부·ILB 미노출).
