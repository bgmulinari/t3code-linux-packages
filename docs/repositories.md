# APT and RPM repositories

## APT

Stable and nightly have independent flat metadata releases. A stable setup is:

```bash
curl -fsSL \
  https://bgmulinari.github.io/t3code-linux-packages/KEY.gpg \
  | sudo tee /etc/apt/keyrings/t3code-archive-keyring.gpg >/dev/null
curl -fsSL \
  https://bgmulinari.github.io/t3code-linux-packages/t3code-stable.sources \
  | sudo tee /etc/apt/sources.list.d/t3code.sources >/dev/null
sudo apt update
sudo apt install t3code
```

For nightly, use `t3code-nightly.sources` instead. Do not install both source definitions at once.

The `Packages` index contains all retained versions and both Debian architectures. Each `Filename`
uses `../UPSTREAM_TAG/PACKAGE.deb`, which resolves from the fixed metadata release to the immutable
same-tag version release.

## DNF/YUM

GitHub Pages serves small repository metadata. A stable setup is:

```bash
sudo curl -fsSL \
  https://bgmulinari.github.io/t3code-linux-packages/t3code-stable.repo \
  -o /etc/yum.repos.d/t3code.repo
sudo dnf install t3code
```

Use `t3code-nightly.repo` instead for nightly. Each architecture has its own metadata path, selected
through DNF's `$basearch`. The metadata stores an external base URL for each RPM, so DNF downloads
the package from its immutable GitHub Release while Pages serves metadata and bootstrap files rather
than package binaries.

## Incremental metadata builder

The publisher updates one channel with one already-signed release at a time:

```bash
scripts/build-package-repositories.sh \
  --packages packages \
  --tag v0.0.33 \
  --channel stable \
  --existing previous-state/repository \
  --output repository \
  --release-repository bgmulinari/t3code-linux-packages \
  --metadata-base-url https://bgmulinari.github.io/t3code-linux-packages \
  --signing-key FULL_GPG_FINGERPRINT
```

Omit `--existing` only for the first mirrored release. The builder copies retained metadata, rejects
conflicting duplicate APT versions, appends new APT stanzas, merges RPM metadata with `mergerepo_c
--all`, regenerates hashes, and signs the updated indexes.

The output separates deployment targets:

```text
repository/
  apt/
    stable/                       # signed indexes for release apt-stable
    nightly/                      # signed indexes for release apt-nightly
  pages/
    rpm/stable/{x86_64,aarch64}/repodata/
    rpm/nightly/{x86_64,aarch64}/repodata/
    t3code-stable.sources
    t3code-nightly.sources
    t3code-stable.repo
    t3code-nightly.repo
    KEY.gpg
```

GitHub Pages is the single bootstrap location for `KEY.gpg` and all `.sources` and `.repo` files.
The fixed APT releases contain only signed APT indexes. The workflow signs and compresses this
metadata-only directory into the rolling `repository-state` release. Historical package binaries
are never copied into that state.
