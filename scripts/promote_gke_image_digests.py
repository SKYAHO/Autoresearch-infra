#!/usr/bin/env python3
"""검증된 immutable GKE 이미지 digest를 manifest에 원자적으로 승격합니다."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


REGISTRY = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker"
DIGEST_PATTERN = re.compile(r"^" + re.escape(REGISTRY) + r"/(?P<image>[a-z0-9-]+)@sha256:[0-9a-f]{64}$")


@dataclass(frozen=True)
class Target:
    name: str
    image: str
    paths: tuple[str, ...]
    expected_count: int


TARGETS = (
    Target("serving", "autoresearch-serving", ("deploy/serving/deployment.yaml",), 1),
    Target("mlflow", "autoresearch-mlflow", ("deploy/mlflow/deployment.yaml",), 1),
    Target(
        "api",
        "autoresearch-agent-orchestration-api",
        (
            "deploy/agent-orchestration/api-deployment.yaml",
            "deploy/agent-orchestration/api-migration-job.yaml",
            "deploy/agent-orchestration/runner-deployment.yaml",
        ),
        5,
    ),
    Target("ui", "autoresearch-agent-orchestration-ui", ("deploy/agent-orchestration/ui-deployment.yaml",), 1),
    Target("runner", "autoresearch-agent-orchestration-runner", ("deploy/agent-orchestration/runner-deployment.yaml",), 1),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, required=True)
    for target in TARGETS:
        parser.add_argument(
            f"--{target.name}-digest",
            required=target.name != "mlflow",
            help="MLflow는 release workflow가 immutable digest를 출력하기 전까지 생략할 수 있습니다.",
        )
    return parser.parse_args()


def require_digest(value: str, target: Target) -> None:
    match = DIGEST_PATTERN.fullmatch(value)
    if match is None or match.group("image") != target.image:
        raise ValueError(f"{target.name} digest must be {REGISTRY}/{target.image}@sha256:<64 lowercase hex>")


def replace_target(
    root: Path, target: Target, new_digest: str, staged_contents: dict[Path, str]
) -> dict[Path, str]:
    image_pattern = re.compile(re.escape(f"{REGISTRY}/{target.image}") + r"@sha256:([0-9a-f]{64})")
    contents: dict[Path, str] = {}
    existing_digests: set[str] = set()
    count = 0
    for relative_path in target.paths:
        path = root / relative_path
        if path in staged_contents:
            content = staged_contents[path]
        else:
            try:
                content = path.read_text()
            except FileNotFoundError as error:
                raise ValueError(f"required manifest is missing: {relative_path}") from error
        matches = list(image_pattern.finditer(content))
        count += len(matches)
        existing_digests.update(match.group(1) for match in matches)
        contents[path] = content
    if count != target.expected_count:
        raise ValueError(f"{target.name} image reference count must be {target.expected_count}, got {count}")
    if target.name == "api" and len(existing_digests) != 1:
        raise ValueError("API image references must share one existing digest")
    return {path: image_pattern.sub(new_digest, content) for path, content in contents.items()}


def main() -> int:
    args = parse_args()
    root = args.repo_root.resolve()
    replacements: dict[Path, str] = {}
    try:
        for target in TARGETS:
            digest = getattr(args, f"{target.name}_digest")
            if digest is None:
                continue
            require_digest(digest, target)
            replacements.update(replace_target(root, target, digest, replacements))
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    for path, content in replacements.items():
        path.write_text(content)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
