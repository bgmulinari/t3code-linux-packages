from __future__ import annotations

import argparse
import json
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY_ROOT / "scripts"))

import release_tool  # noqa: E402


class ReleaseToolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.config = release_tool.load_config(REPOSITORY_ROOT / "config/mirror.json")
        self.upstream = release_tool.read_json(
            REPOSITORY_ROOT / "tests/fixtures/upstream-releases.json"
        )
        self.downstream = release_tool.read_json(
            REPOSITORY_ROOT / "tests/fixtures/downstream-releases.json"
        )

    def test_classifies_release_channels(self) -> None:
        self.assertEqual(release_tool.classify_tag("v0.0.33"), "stable")
        self.assertEqual(
            release_tool.classify_tag("v0.0.34-nightly.20260810.1062"), "nightly"
        )

    def test_normalizes_supported_tag_shapes(self) -> None:
        self.assertEqual(release_tool.tag_to_version("v0.0.33"), "0.0.33")
        self.assertEqual(
            release_tool.tag_to_version("nightly-v0.0.17-nightly.20260415.44"),
            "0.0.17-nightly.20260415.44",
        )
        with self.assertRaises(release_tool.MirrorError):
            release_tool.tag_to_version("release/current")
        with self.assertRaises(release_tool.MirrorError):
            release_tool.tag_to_version("v0.0.35-desktop-preview")
        with self.assertRaises(release_tool.MirrorError):
            release_tool.tag_to_version("0.0.35")

    def test_prefers_stable_and_skips_superseded_nightlies(self) -> None:
        candidates = release_tool.select_candidates(
            self.upstream,
            self.downstream,
            self.config,
            limit=10,
            requested_tag=None,
            commit_resolver=lambda _repository, _tag: self.fail("fixture commit was ignored"),
        )
        self.assertEqual(
            [candidate.tag for candidate in candidates],
            ["v0.0.34", "v0.0.34-nightly.20260811.1063"],
        )

    def test_newest_stable_comes_before_older_pending_stable(self) -> None:
        upstream = [
            *self.upstream,
            {
                "tag_name": "v0.0.35",
                "draft": False,
                "prerelease": False,
                "published_at": "2026-08-12T12:00:00Z",
                "resolved_commit": "b" * 40,
            },
        ]
        candidates = release_tool.select_candidates(
            upstream,
            self.downstream,
            self.config,
            limit=10,
            requested_tag=None,
            commit_resolver=lambda _repository, _tag: self.fail("fixture commit was ignored"),
        )
        self.assertEqual(
            [candidate.tag for candidate in candidates],
            ["v0.0.35", "v0.0.34", "v0.0.34-nightly.20260811.1063"],
        )

    def test_nightly_older_than_mirrored_nightly_is_never_scheduled(self) -> None:
        downstream = [
            *self.downstream,
            {
                "tag_name": "v0.0.34-nightly.20260811.1063",
                "draft": False,
                "published_at": "2026-08-11T05:00:00Z",
            },
            {"tag_name": "v0.0.34", "draft": False, "published_at": "2026-08-11T13:00:00Z"},
        ]
        candidates = release_tool.select_candidates(
            self.upstream,
            downstream,
            self.config,
            limit=10,
            requested_tag=None,
            commit_resolver=lambda _repository, _tag: self.fail("fixture commit was ignored"),
        )
        self.assertEqual(candidates, [])

    def test_manual_tag_can_still_build_a_superseded_nightly(self) -> None:
        candidates = release_tool.select_candidates(
            self.upstream,
            self.downstream,
            self.config,
            limit=1,
            requested_tag="v0.0.34-nightly.20260810.1062",
            commit_resolver=lambda _repository, _tag: self.fail("fixture commit was ignored"),
        )
        self.assertEqual(
            [candidate.tag for candidate in candidates],
            ["v0.0.34-nightly.20260810.1062"],
        )

    def test_ignores_unrelated_upstream_release_tags(self) -> None:
        upstream = [
            *self.upstream,
            {
                "tag_name": "desktop-preview",
                "draft": False,
                "prerelease": True,
                "published_at": "2026-08-10T17:00:00Z",
            },
            {
                "tag_name": "v0.0.34-desktop-preview",
                "draft": False,
                "prerelease": True,
                "published_at": "2026-08-10T18:00:00Z",
            },
        ]
        candidates = release_tool.select_candidates(
            upstream,
            self.downstream,
            self.config,
            limit=10,
            requested_tag=None,
            commit_resolver=lambda _repository, _tag: self.fail("fixture commit was ignored"),
        )
        self.assertEqual(
            [candidate.tag for candidate in candidates],
            ["v0.0.34", "v0.0.34-nightly.20260811.1063"],
        )

    def test_configures_native_x64_and_arm64_runners(self) -> None:
        architectures = release_tool.architectures_from_config(self.config)
        self.assertEqual(
            [(architecture.electron, architecture.runner) for architecture in architectures],
            [("x64", "ubuntu-24.04"), ("arm64", "ubuntu-24.04-arm")],
        )

    def test_scheduled_workflow_does_not_depend_on_a_webhook_repository_payload(self) -> None:
        workflow = (REPOSITORY_ROOT / ".github/workflows/mirror.yml").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("github.event.repository.visibility", workflow)
        self.assertIn(
            "if: github.repository == 'bgmulinari/t3code-linux-packages'", workflow
        )

    def test_upstream_checkouts_avoid_broken_submodule_cleanup(self) -> None:
        workflows = "\n".join(
            (REPOSITORY_ROOT / workflow_path).read_text(encoding="utf-8")
            for workflow_path in (
                ".github/workflows/ci.yml",
                ".github/workflows/mirror.yml",
            )
        )
        self.assertNotIn("repository: pingdotgg/t3code", workflows)
        self.assertIn("https://github.com/pingdotgg/t3code.git", workflows)
        self.assertIn("git -C upstream checkout --detach FETCH_HEAD", workflows)
        self.assertIn("git -C source checkout --detach FETCH_HEAD", workflows)

    def test_discovery_emits_one_release_and_two_builds(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            github_output = Path(temporary_directory) / "github-output"
            release_tool.discover_command(
                argparse.Namespace(
                    config=REPOSITORY_ROOT / "config/mirror.json",
                    upstream_file=REPOSITORY_ROOT / "tests/fixtures/upstream-releases.json",
                    downstream_file=REPOSITORY_ROOT / "tests/fixtures/downstream-releases.json",
                    downstream_repository=None,
                    limit=None,
                    tag=None,
                    github_output=github_output,
                )
            )
            outputs = dict(
                line.split("=", 1)
                for line in github_output.read_text(encoding="utf-8").splitlines()
            )
            release_matrix = json.loads(outputs["release_matrix"])
            build_matrix = json.loads(outputs["build_matrix"])
            self.assertEqual(len(release_matrix["include"]), 1)
            self.assertEqual(
                [entry["arch"] for entry in build_matrix["include"]],
                ["x64", "arm64"],
            )

    def test_limit_keeps_pending_stable_release_first(self) -> None:
        candidates = release_tool.select_candidates(
            self.upstream,
            self.downstream,
            self.config,
            limit=1,
            requested_tag=None,
            commit_resolver=lambda _repository, _tag: self.fail("fixture commit was ignored"),
        )
        self.assertEqual([candidate.tag for candidate in candidates], ["v0.0.34"])

    def test_downstream_draft_does_not_mark_release_complete(self) -> None:
        downstream = [
            *self.downstream,
            {
                "tag_name": "v0.0.34-nightly.20260810.1062",
                "draft": True,
                "published_at": None,
            }
        ]
        candidates = release_tool.select_candidates(
            self.upstream,
            downstream,
            self.config,
            limit=1,
            requested_tag=None,
            commit_resolver=lambda _repository, _tag: self.fail("fixture commit was ignored"),
        )
        self.assertEqual([candidate.tag for candidate in candidates], ["v0.0.34"])

    def test_manual_tag_must_be_inside_configured_history(self) -> None:
        with self.assertRaises(release_tool.MirrorError):
            release_tool.select_candidates(
                self.upstream,
                self.downstream,
                self.config,
                limit=1,
                requested_tag="v0.0.32",
                commit_resolver=lambda _repository, _tag: "a" * 40,
            )

    def test_manifest_records_package_checksums(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            artifacts = root / "artifacts"
            artifacts.mkdir()
            (artifacts / "t3code.deb").write_bytes(b"deb")
            (artifacts / "t3code.rpm").write_bytes(b"rpm")
            output = root / "manifest.json"

            release_tool.manifest_command(
                argparse.Namespace(
                    upstream_repository="pingdotgg/t3code",
                    tag="v0.0.33",
                    commit="b" * 40,
                    published_at="2026-08-10T11:59:22Z",
                    version="0.0.33",
                    channel="stable",
                    arch=["x64", "arm64"],
                    artifacts=artifacts,
                    output=output,
                )
            )

            manifest = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(manifest["schema"], 3)
            self.assertEqual(manifest["upstream"]["commit"], "b" * 40)
            self.assertEqual(manifest["package"]["architectures"], ["x64", "arm64"])
            self.assertEqual(
                {artifact["name"] for artifact in manifest["artifacts"]},
                {"t3code.deb", "t3code.rpm"},
            )
            self.assertTrue(all(len(artifact["sha256"]) == 64 for artifact in manifest["artifacts"]))

    def test_merges_apt_history_without_replacing_versions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            existing = root / "existing"
            incoming = root / "incoming"
            output = root / "output"
            existing.write_text(
                "Package: t3code\nVersion: 1.0.0-1\nArchitecture: amd64\n"
                "Filename: ../v1.0.0/t3code-amd64.deb\nSHA256: aaa\n",
                encoding="utf-8",
            )
            incoming.write_text(
                "Package: t3code\nVersion: 1.1.0-1\nArchitecture: arm64\n"
                "Filename: ../v1.1.0/t3code-arm64.deb\nSHA256: bbb\n",
                encoding="utf-8",
            )
            release_tool.merge_apt_command(
                argparse.Namespace(existing=existing, incoming=incoming, output=output)
            )
            merged = output.read_text(encoding="utf-8")
            self.assertIn("Version: 1.0.0-1", merged)
            self.assertIn("Version: 1.1.0-1", merged)

    def test_refuses_to_replace_same_apt_package_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            existing = root / "existing"
            incoming = root / "incoming"
            existing.write_text(
                "Package: t3code\nVersion: 1.0.0-1\nArchitecture: amd64\n"
                "Filename: ../v1.0.0/t3code-amd64.deb\nSHA256: aaa\n",
                encoding="utf-8",
            )
            incoming.write_text(
                "Package: t3code\nVersion: 1.0.0-1\nArchitecture: amd64\n"
                "Filename: ../v1.0.0/t3code-amd64.deb\nSHA256: changed\n",
                encoding="utf-8",
            )
            with self.assertRaises(release_tool.MirrorError):
                release_tool.merge_apt_command(
                    argparse.Namespace(existing=existing, incoming=incoming, output=root / "out")
                )

    def test_extracts_apt_architectures_into_independent_indexes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            combined = root / "Packages"
            combined.write_text(
                "Package: t3code\nVersion: 1.0.0-1\nArchitecture: amd64\n"
                "Filename: ../v1.0.0/t3code-amd64.deb\nSHA256: aaa\n"
                "Package: t3code\nVersion: 1.0.0-1\nArchitecture: arm64\n"
                "Filename: ../v1.0.0/t3code-arm64.deb\nSHA256: bbb\n",
                encoding="utf-8",
            )

            amd64 = root / "amd64" / "Packages"
            arm64 = root / "arm64" / "Packages"
            for architecture, output in (("amd64", amd64), ("arm64", arm64)):
                release_tool.extract_apt_architecture_command(
                    argparse.Namespace(
                        input=combined,
                        architecture=architecture,
                        output=output,
                    )
                )

            self.assertIn("Architecture: amd64", amd64.read_text(encoding="utf-8"))
            self.assertNotIn("Architecture: arm64", amd64.read_text(encoding="utf-8"))
            self.assertIn("Architecture: arm64", arm64.read_text(encoding="utf-8"))
            self.assertNotIn("Architecture: amd64", arm64.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
