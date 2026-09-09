# T3 Code Linux Packages

> [!IMPORTANT]
> **This mirror is discontinued.** It is no longer updated with new upstream releases.
>
> Fedora users: [T3 Code is packaged in Terra](https://github.com/terrapkg/packages/tree/frawhide/anda/devs/t3code)
> as `t3code` (stable) and `t3code-nightly`, for both x86-64 and ARM64. Use that instead.
>
> Debian and Ubuntu users: upstream does not currently publish `.deb` packages. Use the official
> AppImage from the [T3 Code releases](https://github.com/pingdotgg/t3code/releases) page.

This repository provided unofficial `.deb` and `.rpm` packages for
[T3 Code](https://github.com/pingdotgg/t3code) while no trusted RPM source existed. Since Terra now
packages it, there is no reason to keep a second, slower build pipeline around.

The last releases built here, T3 Code 0.0.40 and 0.0.41-nightly.20260909.1439, remain downloadable
from the [Releases](https://github.com/bgmulinari/t3code-linux-packages/releases) page and the
signed repository metadata still resolves, so existing installations keep working. They will not
receive updates.

## Switching to Terra on Fedora

```bash
# Remove this repository
sudo rm -f /etc/yum.repos.d/t3code.repo
sudo rpmkeys --delete 19be90fac87c520f2b963993a901f52b7dca570b

# Enable Terra (skip if already enabled)
sudo dnf install --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' \
  --setopt='terra.gpgkey=https://repos.fyralabs.com/terra$releasever/key.asc' terra-release

# Install T3 Code (or t3code-nightly)
sudo dnf install t3code
```

## Removing this repository on Debian and Ubuntu

```bash
sudo rm -f /etc/apt/sources.list.d/t3code.sources /etc/apt/keyrings/t3code-archive-keyring.gpg
sudo apt remove t3code
sudo apt update
```

## About the packaging

The Debian and RPM packaging was carried as a local patch applied to official upstream release
tags. The patch originated in [PR #5139](https://github.com/pingdotgg/t3code/pull/5139) by
[`@bigpod98`](https://github.com/bigpod98), which upstream closed without merging. The build and
publishing pipeline is documented in [`docs/`](./docs).

## Disclaimer

These packages are not affiliated with or endorsed by T3 Tools. Report upstream application issues
to [`pingdotgg/t3code`](https://github.com/pingdotgg/t3code).
