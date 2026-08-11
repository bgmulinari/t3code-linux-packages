#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: build-package-repositories.sh \
  --packages DIR --tag TAG --channel stable|nightly --output DIR \
  --release-repository OWNER/REPO --metadata-base-url URL \
  [--existing DIR] [--signing-key FINGERPRINT]
EOF
}

package_dir=""
tag=""
channel=""
output_dir=""
release_repository=""
metadata_base_url=""
existing_dir=""
signing_key=""

while (($# > 0)); do
  case "$1" in
    --packages)
      package_dir="${2:-}"
      shift 2
      ;;
    --tag)
      tag="${2:-}"
      shift 2
      ;;
    --channel)
      channel="${2:-}"
      shift 2
      ;;
    --output)
      output_dir="${2:-}"
      shift 2
      ;;
    --release-repository)
      release_repository="${2:-}"
      shift 2
      ;;
    --metadata-base-url)
      metadata_base_url="${2:-}"
      shift 2
      ;;
    --existing)
      existing_dir="${2:-}"
      shift 2
      ;;
    --signing-key)
      signing_key="${2:-}"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$package_dir" || -z "$tag" || -z "$channel" || -z "$output_dir" \
  || -z "$release_repository" || -z "$metadata_base_url" ]]; then
  usage
  exit 2
fi
if [[ "$channel" != stable && "$channel" != nightly ]]; then
  echo "Unsupported channel: $channel" >&2
  exit 2
fi
if [[ ! "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Unsafe release tag: $tag" >&2
  exit 2
fi
if [[ ! "$release_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Expected --release-repository in OWNER/REPO form." >&2
  exit 2
fi
if [[ ! "$metadata_base_url" =~ ^https:// ]]; then
  echo "Metadata base URL must use HTTPS." >&2
  exit 2
fi

for command in apt-ftparchive createrepo_c dpkg-deb dpkg-scanpackages gzip \
  mergerepo_c rpm; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is missing: $command" >&2
    exit 1
  fi
done
if [[ -n "$signing_key" ]] && ! command -v gpg >/dev/null 2>&1; then
  echo "GPG is required when --signing-key is used." >&2
  exit 1
fi

package_dir="$(realpath "$package_dir")"
output_parent="$(dirname "$output_dir")"
mkdir -p "$output_parent"
output_dir="$(realpath -m "$output_dir")"
metadata_base_url="${metadata_base_url%/}"
if [[ -n "$existing_dir" ]]; then
  existing_dir="$(realpath "$existing_dir")"
fi

if [[ ! -d "$package_dir" ]]; then
  echo "Package directory does not exist: $package_dir" >&2
  exit 1
fi
if [[ -n "$existing_dir" && ! -d "$existing_dir" ]]; then
  echo "Existing metadata state does not exist: $existing_dir" >&2
  exit 1
fi
if [[ -e "$output_dir" ]]; then
  echo "Output must not already exist: $output_dir" >&2
  exit 1
fi
if [[ "$output_dir" == / || "$output_dir" == "$package_dir" \
  || (-n "$existing_dir" && "$output_dir" == "$existing_dir") ]]; then
  echo "Unsafe repository output path: $output_dir" >&2
  exit 1
fi

temporary_dir="$(mktemp -d)"
cleanup() {
  rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

mkdir -p "$output_dir"
if [[ -n "$existing_dir" ]]; then
  for retained_tree in apt pages; do
    if [[ -d "$existing_dir/$retained_tree" ]]; then
      cp -a "$existing_dir/$retained_tree" "$output_dir/"
    fi
  done
fi
mkdir -p "$output_dir/apt/$channel" "$output_dir/pages/rpm/$channel"
for bootstrap_channel in stable nightly; do
  rm -f \
    "$output_dir/apt/$bootstrap_channel/KEY.gpg" \
    "$output_dir/apt/$bootstrap_channel/t3code-$bootstrap_channel.sources"
done

mapfile -d '' deb_files < <(find "$package_dir" -maxdepth 1 -type f -name '*.deb' -print0)
mapfile -d '' rpm_files < <(find "$package_dir" -maxdepth 1 -type f -name '*.rpm' -print0)
if ((${#deb_files[@]} == 0 || ${#rpm_files[@]} == 0)); then
  echo "The release must contain at least one .deb and one .rpm package." >&2
  exit 1
fi

declare -A deb_arches=()
declare -A rpm_arches=()
for deb_file in "${deb_files[@]}"; do
  deb_arch="$(dpkg-deb --field "$deb_file" Architecture)"
  case "$deb_arch" in
    amd64|arm64) ;;
    *) echo "Unsupported Debian architecture in $deb_file: $deb_arch" >&2; exit 1 ;;
  esac
  [[ -z "${deb_arches[$deb_arch]:-}" ]]
  deb_arches[$deb_arch]="$deb_file"
done
for rpm_file in "${rpm_files[@]}"; do
  rpm_arch="$(rpm -qp --queryformat '%{ARCH}' "$rpm_file")"
  case "$rpm_arch" in
    x86_64|aarch64) ;;
    *) echo "Unsupported RPM architecture in $rpm_file: $rpm_arch" >&2; exit 1 ;;
  esac
  [[ -z "${rpm_arches[$rpm_arch]:-}" ]]
  rpm_arches[$rpm_arch]="$rpm_file"
done
if [[ (-n "${deb_arches[amd64]:-}" && -z "${rpm_arches[x86_64]:-}") \
  || (-z "${deb_arches[amd64]:-}" && -n "${rpm_arches[x86_64]:-}") \
  || (-n "${deb_arches[arm64]:-}" && -z "${rpm_arches[aarch64]:-}") \
  || (-z "${deb_arches[arm64]:-}" && -n "${rpm_arches[aarch64]:-}") ]]; then
  echo "Debian and RPM architecture sets do not match." >&2
  exit 1
fi

apt_scan_root="$temporary_dir/apt-scan"
mkdir -p "$apt_scan_root/$tag"
cp -p "${deb_files[@]}" "$apt_scan_root/$tag/"
(
  cd "$apt_scan_root"
  dpkg-scanpackages --multiversion "$tag" /dev/null > "$temporary_dir/Packages.incoming.raw"
)
awk -v prefix="$tag/" '
  $1 == "Filename:" {
    if (index($2, prefix) != 1) exit 42
    $2 = "../" $2
  }
  { print }
' "$temporary_dir/Packages.incoming.raw" > "$temporary_dir/Packages.incoming"

apt_channel="$output_dir/apt/$channel"
merge_args=(
  merge-apt
  --incoming "$temporary_dir/Packages.incoming"
  --output "$temporary_dir/Packages.merged"
)
if [[ -f "$apt_channel/Packages" ]]; then
  merge_args+=(--existing "$apt_channel/Packages")
fi
python3 "$(dirname "$0")/release_tool.py" "${merge_args[@]}"
mv "$temporary_dir/Packages.merged" "$apt_channel/Packages"
gzip -9n -c "$apt_channel/Packages" > "$apt_channel/Packages.gz"

release_download_url="https://github.com/$release_repository/releases/download"
printf '%s\n' \
  'Types: deb' \
  "URIs: $release_download_url/apt-$channel" \
  'Suites: ./' \
  'Architectures: amd64 arm64' \
  'Signed-By: /etc/apt/keyrings/t3code-archive-keyring.gpg' \
  > "$output_dir/pages/t3code-$channel.sources"

for rpm_arch in x86_64 aarch64; do
  rpm_file="${rpm_arches[$rpm_arch]:-}"
  if [[ -z "$rpm_file" ]]; then
    continue
  fi

  new_repository="$temporary_dir/rpm-new-$rpm_arch"
  mkdir -p "$new_repository/$tag"
  cp -p "$rpm_file" "$new_repository/$tag/"
  createrepo_c \
    --no-database \
    --checksum sha256 \
    --baseurl "$release_download_url/" \
    "$new_repository"

  rpm_destination="$output_dir/pages/rpm/$channel/$rpm_arch"
  merged_repository="$temporary_dir/rpm-merged-$rpm_arch"
  if [[ -f "$rpm_destination/repodata/repomd.xml" ]]; then
    mergerepo_c \
      --all \
      --no-database \
      --repo "$rpm_destination" \
      --repo "$new_repository" \
      --outputdir "$merged_repository"
  else
    mkdir -p "$merged_repository"
    cp -a "$new_repository/repodata" "$merged_repository/"
  fi
  mkdir -p "$rpm_destination"
  find "$rpm_destination" -mindepth 1 -delete
  cp -a "$merged_repository/repodata" "$rpm_destination/"
done

printf '%s\n' \
  "[t3code-$channel]" \
  "name=T3 Code ($channel, unofficial)" \
  "baseurl=$metadata_base_url/rpm/$channel/\$basearch" \
  'enabled=1' \
  'gpgcheck=1' \
  'repo_gpgcheck=1' \
  "gpgkey=$metadata_base_url/KEY.gpg" \
  'metadata_expire=1h' \
  > "$output_dir/pages/t3code-$channel.repo"

if [[ -n "$signing_key" ]]; then
  gpg --batch --yes --export "$signing_key" > "$temporary_dir/KEY.gpg"
  cp -p "$temporary_dir/KEY.gpg" "$output_dir/pages/KEY.gpg"

  for rpm_arch in x86_64 aarch64; do
    repomd="$output_dir/pages/rpm/$channel/$rpm_arch/repodata/repomd.xml"
    if [[ -f "$repomd" ]]; then
      gpg --batch --yes --default-key "$signing_key" --armor --detach-sign \
        --output "$repomd.asc" "$repomd"
    fi
  done
else
  rm -f "$output_dir/pages/KEY.gpg"
fi

rm -f "$apt_channel/Release" "$apt_channel/InRelease" "$apt_channel/Release.gpg"
(
  cd "$apt_channel"
  apt-ftparchive \
    -o 'APT::FTPArchive::Release::Origin=T3 Code Linux Packages' \
    -o "APT::FTPArchive::Release::Label=T3 Code Linux Packages ($channel)" \
    -o "APT::FTPArchive::Release::Suite=$channel" \
    -o "APT::FTPArchive::Release::Codename=$channel" \
    -o 'APT::FTPArchive::Release::Architectures=amd64 arm64' \
    release . > Release
)
if [[ -n "$signing_key" ]]; then
  gpg --batch --yes --default-key "$signing_key" --clearsign \
    --output "$apt_channel/InRelease" "$apt_channel/Release"
  gpg --batch --yes --default-key "$signing_key" --armor --detach-sign \
    --output "$apt_channel/Release.gpg" "$apt_channel/Release"
fi

echo "Updated retained package metadata at $output_dir"
