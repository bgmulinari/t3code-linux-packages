#!/usr/bin/env python3
"""Release discovery and provenance helpers for the T3 Code package mirror."""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Iterable


STABLE_TAG_PATTERN = re.compile(r"^v(?P<version>\d+\.\d+\.\d+)$")
NIGHTLY_TAG_PATTERN = re.compile(
    r"^(?:nightly-)?v(?P<version>\d+\.\d+\.\d+-nightly\.\d{8}\.\d+)$"
)
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")


class MirrorError(RuntimeError):
    """A user-facing, fail-closed mirror error."""


@dataclasses.dataclass(frozen=True)
class Architecture:
    electron: str
    debian: str
    rpm: str
    rust_target: str
    runner: str


@dataclasses.dataclass(frozen=True)
class Candidate:
    tag: str
    version: str
    channel: str
    commit: str
    published_at: str
    prerelease: bool

    def as_release_matrix_entry(self) -> dict[str, Any]:
        return {
            "tag": self.tag,
            "version": self.version,
            "channel": self.channel,
            "commit": self.commit,
            "published_at": self.published_at,
            "prerelease": self.prerelease,
        }

    def as_build_matrix_entry(self, architecture: Architecture) -> dict[str, Any]:
        return {
            **self.as_release_matrix_entry(),
            "arch": architecture.electron,
            "deb_arch": architecture.debian,
            "rpm_arch": architecture.rpm,
            "rust_target": architecture.rust_target,
            "runner": architecture.runner,
        }


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MirrorError(f"Unable to read JSON from {path}: {error}") from error


def load_config(path: Path) -> dict[str, Any]:
    config = read_json(path)
    if not isinstance(config, dict):
        raise MirrorError(f"Configuration root must be an object: {path}")

    required = ("upstream_repository", "channels", "architectures")
    missing = [key for key in required if key not in config]
    if missing:
        raise MirrorError(f"Configuration is missing: {', '.join(missing)}")

    architectures_from_config(config)

    maximum = config.get("max_releases_per_run", 1)
    if not isinstance(maximum, int) or maximum != 1:
        raise MirrorError(
            "max_releases_per_run must be 1 so temporary artifacts remain within the "
            "GitHub Actions free allowance"
        )
    return config


def parse_supported_tag(tag: str) -> tuple[str, str]:
    for channel, pattern in (
        ("stable", STABLE_TAG_PATTERN),
        ("nightly", NIGHTLY_TAG_PATTERN),
    ):
        match = pattern.fullmatch(tag)
        if match:
            return channel, match.group("version")
    raise MirrorError(f"Unsupported upstream release tag: {tag}")


def classify_tag(tag: str) -> str:
    channel, _ = parse_supported_tag(tag)
    return channel


def tag_to_version(tag: str) -> str:
    _, version = parse_supported_tag(tag)
    return version


def is_supported_tag(tag: str) -> bool:
    try:
        tag_to_version(tag)
    except MirrorError:
        return False
    return True


def parse_timestamp(value: str) -> dt.datetime:
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise MirrorError(f"Invalid GitHub release timestamp: {value}") from error


class GitHubClient:
    def __init__(self, token: str | None = None, api_url: str = "https://api.github.com"):
        self.token = token
        self.api_url = api_url.rstrip("/")

    def request(self, path: str) -> Any:
        request = urllib.request.Request(
            f"{self.api_url}{path}",
            headers={
                "Accept": "application/vnd.github+json",
                "User-Agent": "t3code-linux-packages",
                "X-GitHub-Api-Version": "2022-11-28",
                **({"Authorization": f"Bearer {self.token}"} if self.token else {}),
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
            raise MirrorError(f"GitHub API request failed for {path}: {error}") from error

    def releases(self, repository: str) -> list[dict[str, Any]]:
        releases: list[dict[str, Any]] = []
        page = 1
        while True:
            payload = self.request(f"/repos/{repository}/releases?per_page=100&page={page}")
            if not isinstance(payload, list):
                raise MirrorError(f"Unexpected releases response for {repository}")
            releases.extend(payload)
            if len(payload) < 100:
                return releases
            page += 1

    def resolve_tag_commit(self, repository: str, tag: str) -> str:
        encoded_tag = urllib.parse.quote(tag, safe="")
        reference = self.request(f"/repos/{repository}/git/ref/tags/{encoded_tag}")
        try:
            target = reference["object"]
            target_type = target["type"]
            target_sha = target["sha"]
        except (KeyError, TypeError) as error:
            raise MirrorError(f"Malformed tag reference for {repository}@{tag}") from error

        for _ in range(8):
            if target_type == "commit":
                if not SHA_PATTERN.fullmatch(target_sha):
                    raise MirrorError(f"Malformed commit SHA for {repository}@{tag}: {target_sha}")
                return target_sha
            if target_type != "tag":
                raise MirrorError(
                    f"Unsupported Git object type for {repository}@{tag}: {target_type}"
                )
            annotated = self.request(f"/repos/{repository}/git/tags/{target_sha}")
            try:
                target = annotated["object"]
                target_type = target["type"]
                target_sha = target["sha"]
            except (KeyError, TypeError) as error:
                raise MirrorError(f"Malformed annotated tag for {repository}@{tag}") from error

        raise MirrorError(f"Annotated tag chain is too deep for {repository}@{tag}")


def eligible_releases(
    upstream_releases: Iterable[dict[str, Any]], config: dict[str, Any]
) -> list[dict[str, Any]]:
    published = [
        release
        for release in upstream_releases
        if not release.get("draft")
        and isinstance(release.get("tag_name"), str)
        and is_supported_tag(release["tag_name"])
        and isinstance(release.get("published_at"), str)
    ]

    selected: list[dict[str, Any]] = []
    channels = config["channels"]
    for channel in ("stable", "nightly"):
        try:
            first_tag = channels[channel]["first_tag"]
        except (KeyError, TypeError) as error:
            raise MirrorError(f"Missing first_tag configuration for {channel}") from error

        channel_releases = sorted(
            (release for release in published if classify_tag(release["tag_name"]) == channel),
            key=lambda release: parse_timestamp(release["published_at"]),
        )
        start_index = next(
            (index for index, release in enumerate(channel_releases) if release["tag_name"] == first_tag),
            None,
        )
        if start_index is None:
            raise MirrorError(
                f"Configured first {channel} tag is not present upstream: {first_tag}"
            )
        selected.extend(channel_releases[start_index:])

    return sorted(selected, key=lambda release: parse_timestamp(release["published_at"]))


def architectures_from_config(config: dict[str, Any]) -> list[Architecture]:
    raw_architectures = config.get("architectures")
    if not isinstance(raw_architectures, list) or not raw_architectures:
        raise MirrorError("At least one build architecture must be configured")

    architectures: list[Architecture] = []
    for raw in raw_architectures:
        try:
            architecture = Architecture(
                electron=raw["electron"],
                debian=raw["debian"],
                rpm=raw["rpm"],
                rust_target=raw["rust_target"],
                runner=raw["runner"],
            )
        except (KeyError, TypeError) as error:
            raise MirrorError("Malformed architecture configuration") from error
        if not all(
            isinstance(value, str) and value
            for value in dataclasses.astuple(architecture)
        ):
            raise MirrorError("Architecture values must be non-empty strings")
        architectures.append(architecture)

    for field in ("electron", "debian", "rpm"):
        values = [getattr(architecture, field) for architecture in architectures]
        if len(values) != len(set(values)):
            raise MirrorError(f"Architecture field must be unique: {field}")
    return architectures


def select_candidates(
    upstream_releases: list[dict[str, Any]],
    downstream_releases: list[dict[str, Any]],
    config: dict[str, Any],
    *,
    limit: int,
    requested_tag: str | None,
    commit_resolver: Any,
) -> list[Candidate]:
    if limit < 1:
        raise MirrorError("Release limit must be at least 1")

    eligible = eligible_releases(upstream_releases, config)
    if requested_tag:
        eligible = [release for release in eligible if release["tag_name"] == requested_tag]
        if not eligible:
            raise MirrorError(f"Requested tag is not eligible for mirroring: {requested_tag}")

    existing_tags = {
        release.get("tag_name")
        for release in downstream_releases
        if not release.get("draft")
        and isinstance(release.get("tag_name"), str)
        and isinstance(release.get("published_at"), str)
    }
    repository = config["upstream_repository"]

    candidates: list[Candidate] = []
    for release in eligible:
        tag = release["tag_name"]
        if tag in existing_tags:
            continue
        commit = release.get("resolved_commit") or commit_resolver(repository, tag)
        if not isinstance(commit, str) or not SHA_PATTERN.fullmatch(commit):
            raise MirrorError(f"Unable to resolve immutable commit for {repository}@{tag}")
        candidates.append(
            Candidate(
                tag=tag,
                version=tag_to_version(tag),
                channel=classify_tag(tag),
                commit=commit,
                published_at=release["published_at"],
                prerelease=bool(release.get("prerelease")),
            )
        )
        if len(candidates) == limit:
            break
    return candidates


def write_github_outputs(values: dict[str, str], output_path: Path) -> None:
    try:
        with output_path.open("a", encoding="utf-8") as output:
            for key, value in values.items():
                if "\n" in value or "\r" in value:
                    raise MirrorError(f"GitHub output contains a newline: {key}")
                output.write(f"{key}={value}\n")
    except OSError as error:
        raise MirrorError(f"Unable to write GitHub outputs to {output_path}: {error}") from error


def discover_command(args: argparse.Namespace) -> None:
    config = load_config(args.config)
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    client = GitHubClient(token=token, api_url=os.environ.get("GITHUB_API_URL", "https://api.github.com"))

    if args.upstream_file:
        upstream = read_json(args.upstream_file)
    else:
        upstream = client.releases(config["upstream_repository"])

    downstream_repository = args.downstream_repository or os.environ.get("GITHUB_REPOSITORY")
    if args.downstream_file:
        downstream = read_json(args.downstream_file)
    elif downstream_repository:
        downstream = client.releases(downstream_repository)
    else:
        raise MirrorError("A downstream repository or fixture file is required")

    if not isinstance(upstream, list) or not isinstance(downstream, list):
        raise MirrorError("Release inputs must be JSON arrays")

    default_limit = int(config["max_releases_per_run"])
    release_limit = args.limit or default_limit
    if release_limit > default_limit:
        raise MirrorError(
            f"Release limit {release_limit} exceeds configured maximum {default_limit}"
        )
    candidates = select_candidates(
        upstream,
        downstream,
        config,
        limit=release_limit,
        requested_tag=args.tag,
        commit_resolver=client.resolve_tag_commit,
    )
    architectures = architectures_from_config(config)
    release_matrix = {
        "include": [candidate.as_release_matrix_entry() for candidate in candidates]
    }
    build_matrix = {
        "include": [
            candidate.as_build_matrix_entry(architecture)
            for candidate in candidates
            for architecture in architectures
        ]
    }
    payload = {
        "has_releases": bool(candidates),
        "count": len(candidates),
        "release_matrix": release_matrix,
        "build_matrix": build_matrix,
    }

    if args.github_output:
        write_github_outputs(
            {
                "has_releases": "true" if candidates else "false",
                "count": str(len(candidates)),
                "release_matrix": json.dumps(release_matrix, separators=(",", ":")),
                "build_matrix": json.dumps(build_matrix, separators=(",", ":")),
            },
            args.github_output,
        )
    print(json.dumps(payload, indent=2, sort_keys=True))


def classify_command(args: argparse.Namespace) -> None:
    print(
        json.dumps(
            {
                "tag": args.tag,
                "channel": classify_tag(args.tag),
                "version": tag_to_version(args.tag),
            },
            indent=2,
            sort_keys=True,
        )
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def manifest_command(args: argparse.Namespace) -> None:
    artifacts = sorted(
        path
        for path in args.artifacts.iterdir()
        if path.is_file() and path.suffix in {".deb", ".rpm"}
    )
    suffixes = {path.suffix for path in artifacts}
    if suffixes != {".deb", ".rpm"}:
        raise MirrorError(
            f"Expected at least one .deb and one .rpm in {args.artifacts}; found {sorted(suffixes)}"
        )
    if not SHA_PATTERN.fullmatch(args.commit):
        raise MirrorError(f"Invalid upstream commit: {args.commit}")

    generated_at = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )
    payload = {
        "schema": 2,
        "upstream": {
            "repository": args.upstream_repository,
            "tag": args.tag,
            "commit": args.commit,
            "published_at": args.published_at,
        },
        "package": {
            "version": args.version,
            "channel": args.channel,
            "architectures": args.arch,
            "packaging_proposal": "https://github.com/pingdotgg/t3code/pull/5139",
        },
        "generated_at": generated_at,
        "artifacts": [
            {
                "name": path.name,
                "size": path.stat().st_size,
                "sha256": sha256(path),
            }
            for path in artifacts
        ],
    }
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(args.output)


def package_stanzas(path: Path) -> dict[tuple[str, str, str], str]:
    if not path.exists():
        return {}
    try:
        content = path.read_text(encoding="utf-8").strip()
    except OSError as error:
        raise MirrorError(f"Unable to read APT package metadata from {path}: {error}") from error
    if not content:
        return {}

    result: dict[tuple[str, str, str], str] = {}
    for raw_stanza in re.split(
        r"\n[ \t]*\n|(?=^Package:[ \t])", content, flags=re.MULTILINE
    ):
        if not raw_stanza.strip():
            continue
        stanza = raw_stanza.strip() + "\n"
        fields: dict[str, str] = {}
        for line in stanza.splitlines():
            if line[:1].isspace() or ":" not in line:
                continue
            name, value = line.split(":", 1)
            fields[name] = value.strip()
        try:
            key = (fields["Package"], fields["Version"], fields["Architecture"])
            fields["Filename"]
        except KeyError as error:
            raise MirrorError(f"Malformed APT package stanza in {path}: missing {error.args[0]}") from error
        previous = result.get(key)
        if previous is not None and previous != stanza:
            raise MirrorError(f"Conflicting duplicate APT package stanza in {path}: {key}")
        result[key] = stanza
    return result


def write_package_stanzas(
    stanzas: dict[tuple[str, str, str], str], output: Path
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    content = "\n\n".join(stanzas[key].rstrip() for key in sorted(stanzas))
    output.write_text(f"{content}\n" if content else "", encoding="utf-8")


def merge_apt_command(args: argparse.Namespace) -> None:
    merged = package_stanzas(args.existing) if args.existing else {}
    incoming = package_stanzas(args.incoming)
    for key, stanza in incoming.items():
        previous = merged.get(key)
        if previous is not None and previous != stanza:
            raise MirrorError(f"Refusing to replace existing APT package metadata: {key}")
        merged[key] = stanza

    write_package_stanzas(merged, args.output)
    print(args.output)


def extract_apt_architecture_command(args: argparse.Namespace) -> None:
    selected = {
        key: stanza
        for key, stanza in package_stanzas(args.input).items()
        if key[2] == args.architecture
    }
    write_package_stanzas(selected, args.output)
    print(args.output)


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    classify = subparsers.add_parser("classify", help="Classify an upstream tag")
    classify.add_argument("tag")
    classify.set_defaults(handler=classify_command)

    discover = subparsers.add_parser("discover", help="Find unseen eligible upstream releases")
    discover.add_argument("--config", type=Path, default=Path("config/mirror.json"))
    discover.add_argument("--downstream-repository")
    discover.add_argument("--upstream-file", type=Path)
    discover.add_argument("--downstream-file", type=Path)
    discover.add_argument("--tag", help="Only consider this eligible tag")
    discover.add_argument("--limit", type=int)
    discover.add_argument("--github-output", type=Path)
    discover.set_defaults(handler=discover_command)

    manifest = subparsers.add_parser("manifest", help="Create a package provenance manifest")
    manifest.add_argument("--upstream-repository", default="pingdotgg/t3code")
    manifest.add_argument("--tag", required=True)
    manifest.add_argument("--commit", required=True)
    manifest.add_argument("--published-at", required=True)
    manifest.add_argument("--version", required=True)
    manifest.add_argument("--channel", choices=("stable", "nightly"), required=True)
    manifest.add_argument("--arch", action="append", required=True)
    manifest.add_argument("--artifacts", type=Path, required=True)
    manifest.add_argument("--output", type=Path, required=True)
    manifest.set_defaults(handler=manifest_command)

    merge_apt = subparsers.add_parser(
        "merge-apt", help="Append new package stanzas to retained APT metadata"
    )
    merge_apt.add_argument("--existing", type=Path)
    merge_apt.add_argument("--incoming", type=Path, required=True)
    merge_apt.add_argument("--output", type=Path, required=True)
    merge_apt.set_defaults(handler=merge_apt_command)

    extract_apt_architecture = subparsers.add_parser(
        "extract-apt-architecture",
        help="Extract one architecture from an APT Packages index",
    )
    extract_apt_architecture.add_argument("--input", type=Path, required=True)
    extract_apt_architecture.add_argument(
        "--architecture", choices=("amd64", "arm64"), required=True
    )
    extract_apt_architecture.add_argument("--output", type=Path, required=True)
    extract_apt_architecture.set_defaults(handler=extract_apt_architecture_command)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = create_parser()
    args = parser.parse_args(argv)
    try:
        args.handler(args)
    except MirrorError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
