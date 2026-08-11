# Architecture

## Sources of truth

- Application source and release tags: `pingdotgg/t3code`.
- Temporary native-package implementation: the local patch derived from
  [PR #5139](https://github.com/pingdotgg/t3code/pull/5139) by
  [`@bigpod98`](https://github.com/bigpod98).
- Mirror completion ledger and permanent package archive: immutable GitHub Releases in this
  repository.
- Package repository state: signed, incrementally retained APT and RPM metadata.

The contributor fork behind PR 5139 is never used as a moving build source. Its work is carried as a
reviewable patch and applied to an official upstream tag. A patch conflict stops the build so an
upstream change cannot silently produce a differently patched package.

## Channels and architectures

Tags containing `nightly` enter the nightly channel; other published releases enter stable. Each
channel has an explicit first tag in `config/mirror.json`, so earlier history is not backfilled by
accident.

Both channels build on native standard GitHub runners:

| Electron | Debian | RPM | Rust target | Runner |
| --- | --- | --- | --- | --- |
| `x64` | `amd64` | `x86_64` | `x86_64-unknown-linux-gnu` | `ubuntu-24.04` |
| `arm64` | `arm64` | `aarch64` | `aarch64-unknown-linux-gnu` | `ubuntu-24.04-arm` |

The ARM build is native rather than cross-compiled. Upstream already locks the ARM64 Electron, SWC,
Lightning CSS, Rollup, and Rust-side dependencies required by the desktop build.

## Trust boundary

The build jobs execute upstream source and receive no signing or publishing secrets. They have
read-only repository permissions and emit one-day unsigned workflow artifacts.

The protected publishing job checks out only this repository, combines and revalidates both build
outputs, signs both RPMs, creates checksums and provenance, and generates signed repository
metadata. The GPG private key belongs to the protected `package-signing` environment.

The deployment job receives signed metadata, not the signing key. It deploys RPM metadata to GitHub
Pages and updates the fixed APT metadata and retained-state releases. APT clients authenticate
`InRelease`; RPM clients authenticate both package signatures and `repomd.xml`.

## Storage and retention

Each upstream version becomes a same-tag GitHub Release containing two Debian and two RPM packages.
These version releases are append-only and are never overwritten. GitHub does not automatically
expire ordinary release assets; they remain until a maintainer deletes the asset, release, or
repository.

Large package files never enter GitHub Pages. The Pages site contains only RPM `repodata`, all APT
and DNF configuration files, and the public key. APT metadata lives in separate fixed releases for
each channel and Debian architecture, such as `apt-stable-amd64` and `apt-nightly-arm64`. Metadata
references packages in immutable version releases.

The fixed `repository-state` release contains a signed compressed snapshot of metadata only. A run
verifies that snapshot, merges one new version, and replaces the snapshot. This retains every
package entry without redownloading the package archive or exceeding runner disk limits.

Actions artifacts are transport only: one day of retention on failure and explicit deletion after a
successful deployment. The configuration hard-limits discovery to one release per run and rejects a
build pair larger than 240 MB per architecture.

## Failure behavior

- Missing or moved upstream tag: fail.
- Tag-to-commit mismatch after checkout: fail.
- Packaging patch does not apply: fail.
- Missing or duplicate architecture package: fail.
- Unexpected package identity, launcher, dependencies, license notice, or signature: fail.
- Existing version with different APT hashes: fail rather than replace history.
- Missing retained state after any version release exists: fail rather than publish incomplete
  history.
- Existing mirror release: discovery skips it and publication refuses to overwrite it.
- Metadata deployment failure: retained Actions artifacts allow the failed job to be rerun for one
  day; no version package is overwritten.
