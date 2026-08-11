# T3 Code Linux Packages

Unofficial `.deb` and `.rpm` packages for
[T3 Code](https://github.com/pingdotgg/t3code), available for x86-64 and ARM64 Linux.

This repository exists to make upstream T3 Code releases installable and updatable through APT and
DNF while upstream does not provide those package repositories. Its Debian and RPM packaging is
based on [PR #5139](https://github.com/pingdotgg/t3code/pull/5139) by
[`@bigpod98`](https://github.com/bigpod98), applied to official upstream release tags.

> [!IMPORTANT]
> Choose either the **stable** or **nightly** channel. Do not enable both at the same time.

## Debian-based distributions

Stable:

```bash
# Add the GPG key
curl -fsSL https://bgmulinari.github.io/t3code-linux-packages/KEY.gpg \
  | sudo tee /etc/apt/keyrings/t3code-archive-keyring.gpg >/dev/null

# Add the repository
curl -fsSL https://bgmulinari.github.io/t3code-linux-packages/t3code-stable.sources \
  | sudo tee /etc/apt/sources.list.d/t3code.sources >/dev/null

# Install T3 Code
sudo apt update
sudo apt install t3code
```

Nightly:

```bash
# Add the GPG key
curl -fsSL https://bgmulinari.github.io/t3code-linux-packages/KEY.gpg \
  | sudo tee /etc/apt/keyrings/t3code-archive-keyring.gpg >/dev/null

# Add the repository
curl -fsSL https://bgmulinari.github.io/t3code-linux-packages/t3code-nightly.sources \
  | sudo tee /etc/apt/sources.list.d/t3code.sources >/dev/null

# Install T3 Code
sudo apt update
sudo apt install t3code
```

## Fedora and other RPM-based distributions

Stable:

```bash
# Add the repository
sudo curl -fsSL https://bgmulinari.github.io/t3code-linux-packages/t3code-stable.repo \
  -o /etc/yum.repos.d/t3code.repo

# Install T3 Code
sudo dnf install t3code
```

Nightly:

```bash
# Add the repository
sudo curl -fsSL https://bgmulinari.github.io/t3code-linux-packages/t3code-nightly.repo \
  -o /etc/yum.repos.d/t3code.repo

# Install T3 Code
sudo dnf install t3code
```

## Disclaimer

These packages are not affiliated with or endorsed by T3 Tools. Report upstream application issues
to [`pingdotgg/t3code`](https://github.com/pingdotgg/t3code); report packaging or repository issues
here.
