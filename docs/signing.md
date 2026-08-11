# Package signing

Create a dedicated RPM/repository signing key for this mirror. The key should not be used for source
commits or any unrelated package repository.

The mirror workflow expects a protected GitHub environment named `package-signing` with this secret:

- `PACKAGE_SIGNING_PRIVATE_KEY`: ASCII-armored private key. The current unattended workflow expects
  a dedicated key without an interactive passphrase; access is protected by GitHub's encrypted
  secret store and environment controls.

The build job never receives this secret. Only the publishing job imports it, and that job never
executes the checked-out upstream source tree.

The same key signs RPM packages, RPM repository metadata, APT repository metadata, and the retained
metadata-state archive. The publisher verifies the previous state signature before merging anything
into it.

The exported binary public key is published as `KEY.gpg` on the GitHub Pages metadata site. Both APT
and DNF installation instructions use this single bootstrap location. The rolling technical releases
contain no private material.

## Repository setup

Before the first mirror run:

1. Create a protected GitHub environment named `package-signing` and add the
   `PACKAGE_SIGNING_PRIVATE_KEY` secret described above.
2. In the repository's Pages settings, select **GitHub Actions** as the deployment source.

GitHub automatically disables scheduled workflows in public repositories after 60 days without
repository activity. If that happens, re-enable the mirror workflow from the repository's Actions
page.
