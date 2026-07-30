#!/bin/sh
# #439 OAuth client 반영 검증 — "재발급 ≠ 반영"(#404 실측) 재발 차단.
# 5개 UI의 K8s Secret client id가 기대 프로젝트 발급분인지(프로젝트 번호
# 프리픽스), SM 정본이 있는 4종은 K8s ↔ SM 해시 일치까지 값 비노출로 검증한다.
#
# 사용: scripts/verify-oauth-clients.sh [k8s-context] [project-id]
#   기본 context=현재 kubectl context, project=autoresearch-503903
set -eu

CTX="${1:-$(kubectl config current-context)}"
PROJECT="${2:-autoresearch-503903}"
EXPECT_NUM="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')"
FAIL=0
WARN=0

k8s_val() { # ns secret key
  kubectl --context "$CTX" -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d
}
h8() { shasum -a 256 | cut -c1-8; }

check_prefix() { # label ns secret key
  v="$(k8s_val "$2" "$3" "$4" | cut -d- -f1)" || v=""
  if [ "$v" = "$EXPECT_NUM" ]; then echo "OK  $1: client id 프리픽스 $v"
  elif [ -z "$v" ]; then echo "ERR $1: Secret/키 없음 ($2/$3.$4)"; FAIL=1
  else echo "ERR $1: 기대 $EXPECT_NUM, 실제 $v — 미반영 client"; FAIL=1; fi
}

check_sm() { # label ns secret key sm-name
  a="$(k8s_val "$2" "$3" "$4" | h8)"
  b="$(gcloud secrets versions access latest --secret "$5" --project "$PROJECT" 2>/dev/null | tr -d '\n' | h8)" || b=""
  if [ -z "$b" ] || [ "$b" = "$(printf '' | h8)" ]; then
    echo "WARN $1: SM 정본 '$5' 비어 있음 — versions add 필요"; WARN=1
  elif [ "$a" = "$b" ]; then echo "OK  $1: K8s↔SM 해시 일치($a)"
  else echo "ERR $1: K8s($a) ≠ SM($b) — 주입 또는 정본 갱신 누락"; FAIL=1; fi
}

echo "== client id 프리픽스 (기대 프로젝트 번호: $EXPECT_NUM)"
check_prefix "Airflow " airflow    airflow-web-oauth    GOOGLE_OAUTH_CLIENT_ID
check_prefix "Grafana " monitoring grafana-google-oauth GF_AUTH_GOOGLE_CLIENT_ID
check_prefix "Kibana  " elastic    kibana-oauth         client-id
check_prefix "MLflow  " mlflow     mlflow-oauth         client-id
check_prefix "ArgoCD  " argocd     argocd-google-oidc   clientId

echo "== SM 정본 대조 — id/secret 쌍 모두 (재발급은 쌍으로 바뀜: secret만 어긋나도 invalid_client)"
check_sm "Airflow id     " airflow airflow-web-oauth GOOGLE_OAUTH_CLIENT_ID     "autoresearch-dev-airflow-oauth-client-id"
check_sm "Airflow secret " airflow airflow-web-oauth GOOGLE_OAUTH_CLIENT_SECRET "autoresearch-dev-airflow-oauth-client-secret"
check_sm "MLflow id      " mlflow  mlflow-oauth      client-id                  "autoresearch-dev-mlflow-oauth-client-id"
check_sm "MLflow secret  " mlflow  mlflow-oauth      client-secret              "autoresearch-dev-mlflow-oauth-client-secret"
check_sm "ArgoCD id      " argocd  argocd-google-oidc clientId                  "argocd-google-oidc-client-id"
check_sm "ArgoCD secret  " argocd  argocd-google-oidc clientSecret              "argocd-google-oidc-client-secret"
# #439 정본 신설분 — apply·versions add 전에는 WARN(경고 종료 아님)이 정상
check_sm "Grafana id     " monitoring grafana-google-oauth GF_AUTH_GOOGLE_CLIENT_ID     "autoresearch-dev-grafana-oauth-client-id"
check_sm "Grafana secret " monitoring grafana-google-oauth GF_AUTH_GOOGLE_CLIENT_SECRET "autoresearch-dev-grafana-oauth-client-secret"
check_sm "Kibana id      " elastic    kibana-oauth         client-id                    "autoresearch-dev-kibana-oauth-client-id"
check_sm "Kibana secret  " elastic    kibana-oauth         client-secret                "autoresearch-dev-kibana-oauth-client-secret"

# 종료 의미: ERR만 실패(exit 1). WARN(정본 미등록)은 exit 0 + 요약 표기 —
# "versions add 전 구간은 정상"이라는 운영 문서와 종료 코드가 일치해야 한다.
if [ "$FAIL" -ne 0 ]; then echo "결과: 실패(ERR) 항목 있음"; exit 1
elif [ "$WARN" -ne 0 ]; then echo "결과: 통과(단, WARN — 정본 미등록 항목 있음)"; exit 0
else echo "결과: 전부 통과"; fi
