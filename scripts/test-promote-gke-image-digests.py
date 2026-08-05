#!/usr/bin/env python3
"""GKE immutable image digest 승격 도구의 계약 테스트입니다."""

from __future__ import annotations

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts/promote_gke_image_digests.py"
MANIFESTS = (
    "deploy/serving/deployment.yaml",
    "deploy/mlflow/deployment.yaml",
    "deploy/agent-orchestration/api-deployment.yaml",
    "deploy/agent-orchestration/api-migration-job.yaml",
    "deploy/agent-orchestration/runner-deployment.yaml",
    "deploy/agent-orchestration/ui-deployment.yaml",
)
REGISTRY = "asia-northeast3-docker.pkg.dev/autoresearch-503903/autoresearch-dev-docker"


class PromoteGkeImageDigestsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        for relative_path in MANIFESTS:
            source = REPO_ROOT / relative_path
            target = self.root / relative_path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_tool(self, *extra_args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "--repo-root",
                str(self.root),
                "--serving-digest",
                f"{REGISTRY}/autoresearch-serving@sha256:{'1' * 64}",
                "--mlflow-digest",
                f"{REGISTRY}/autoresearch-mlflow@sha256:{'2' * 64}",
                "--api-digest",
                f"{REGISTRY}/autoresearch-agent-orchestration-api@sha256:{'3' * 64}",
                "--ui-digest",
                f"{REGISTRY}/autoresearch-agent-orchestration-ui@sha256:{'4' * 64}",
                "--runner-digest",
                f"{REGISTRY}/autoresearch-agent-orchestration-runner@sha256:{'5' * 64}",
                *extra_args,
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_replaces_all_declared_references_atomically(self) -> None:
        result = self.run_tool()

        self.assertEqual(result.returncode, 0, result.stderr)
        api_files = (
            "deploy/agent-orchestration/api-deployment.yaml",
            "deploy/agent-orchestration/api-migration-job.yaml",
            "deploy/agent-orchestration/runner-deployment.yaml",
        )
        api_text = "\n".join((self.root / path).read_text() for path in api_files)
        self.assertEqual(api_text.count("@sha256:" + "3" * 64), 5)
        self.assertIn("@sha256:" + "1" * 64, (self.root / MANIFESTS[0]).read_text())
        self.assertIn("@sha256:" + "2" * 64, (self.root / MANIFESTS[1]).read_text())
        self.assertIn("@sha256:" + "4" * 64, (self.root / MANIFESTS[-1]).read_text())
        self.assertIn("@sha256:" + "5" * 64, (self.root / MANIFESTS[-2]).read_text())

    def test_rejects_inconsistent_existing_api_references_without_writing(self) -> None:
        api_file = self.root / "deploy/agent-orchestration/api-deployment.yaml"
        original = api_file.read_text()
        api_file.write_text(original.replace("@sha256:76092067", "@sha256:86092067", 1))

        result = self.run_tool()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("API image references must share one existing digest", result.stderr)
        self.assertEqual(api_file.read_text(), original.replace("@sha256:76092067", "@sha256:86092067", 1))


if __name__ == "__main__":
    unittest.main()
