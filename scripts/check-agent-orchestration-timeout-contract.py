#!/usr/bin/env python3
"""Agent Orchestration API와 Runner의 단일 timeout ConfigMap 계약을 검증한다.

API와 OAuth Runner는 서로 다른 deployment지만 Codex 실행 종료 여유를 고려한 같은
HTTP timeout을 써야 한다. 이 스크립트는 두 manifest가 동일 ConfigMap key를 참조하고,
Runner Codex timeout 110초 및 공통 HTTP timeout 120초가 유지되는지 검사한다.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DEPLOY_DIRECTORY = REPOSITORY_ROOT / "deploy" / "agent-orchestration"
TIMEOUT_CONFIG_MAP_NAME = "agent-orchestration-runner-timeout"
TIMEOUT_ENV_NAME = "CODEX_RUNNER_TIMEOUT_SEC"
TIMEOUT_VALUE = "120"


def _load_documents(path: Path) -> list[dict[str, Any]]:
    """YAML 파일의 비어 있지 않은 문서를 읽는다."""
    with path.open(encoding="utf-8") as manifest:
        return [document for document in yaml.safe_load_all(manifest) if document]


def _deployment(path: Path) -> dict[str, Any]:
    """단일 deployment 문서를 반환한다."""
    return next(
        document for document in _load_documents(path) if document["kind"] == "Deployment"
    )


def _environment(deployment: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """주 컨테이너의 환경 변수 이름별 manifest를 반환한다."""
    container = deployment["spec"]["template"]["spec"]["containers"][0]
    return {item["name"]: item for item in container["env"]}


def _assert_timeout_config_map() -> None:
    config_map = _load_documents(DEPLOY_DIRECTORY / "runner-timeout-config-map.yaml")[0]
    assert config_map["kind"] == "ConfigMap"
    assert config_map["metadata"]["name"] == TIMEOUT_CONFIG_MAP_NAME
    assert config_map["data"] == {TIMEOUT_ENV_NAME: TIMEOUT_VALUE}


def _assert_deployment_timeout_reference(path: Path) -> None:
    environment = _environment(_deployment(path))
    assert environment[TIMEOUT_ENV_NAME] == {
        "name": TIMEOUT_ENV_NAME,
        "valueFrom": {
            "configMapKeyRef": {
                "name": TIMEOUT_CONFIG_MAP_NAME,
                "key": TIMEOUT_ENV_NAME,
            }
        },
    }


def main() -> None:
    """공유 Runner HTTP timeout 계약을 검사하고 성공 메시지를 출력한다."""
    _assert_timeout_config_map()
    _assert_deployment_timeout_reference(DEPLOY_DIRECTORY / "api-deployment.yaml")
    _assert_deployment_timeout_reference(DEPLOY_DIRECTORY / "runner-deployment.yaml")
    runner_environment = _environment(
        _deployment(DEPLOY_DIRECTORY / "runner-deployment.yaml")
    )
    assert runner_environment["CODEX_TIMEOUT_SEC"]["value"] == "110"
    print("Agent Orchestration timeout contract: Codex=110, shared Runner HTTP=120")


if __name__ == "__main__":
    main()
