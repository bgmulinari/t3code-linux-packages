#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: build-package-repositories.sh \
  --packages DIR --tag TAG --channel stable|nightly --output DIR \
  --release-repository OWNER/REPO --metadata-base-url URL \
  [--existing DIR] [--signing-key FINGERPRINT]

       build-package-repositories.sh \
  --metadata-only --existing DIR --output DIR \
  --release-repository OWNER/REPO --metadata-base-url URL \
  [--signing-key FINGERPRINT]
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
metadata_only=false

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
    --metadata-only)
      metadata_only=true
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$output_dir" || -z "$release_repository" || -z "$metadata_base_url" ]]; then
  usage
  exit 2
fi
if [[ "$metadata_only" == false \
  && (-z "$package_dir" || -z "$tag" || -z "$channel") ]]; then
  usage
  exit 2
fi
if [[ "$metadata_only" == true && -z "$existing_dir" ]]; then
  echo "--metadata-only requires --existing." >&2
  exit 2
fi
if [[ "$metadata_only" == false && "$channel" != stable && "$channel" != nightly ]]; then
  echo "Unsupported channel: $channel" >&2
  exit 2
fi
if [[ "$metadata_only" == false && ! "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
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

if [[ "$metadata_only" == false ]]; then
  package_dir="$(realpath "$package_dir")"
fi
output_parent="$(dirname "$output_dir")"
mkdir -p "$output_parent"
output_dir="$(realpath -m "$output_dir")"
metadata_base_url="${metadata_base_url%/}"
if [[ -n "$existing_dir" ]]; then
  existing_dir="$(realpath "$existing_dir")"
fi

if [[ "$metadata_only" == false && ! -d "$package_dir" ]]; then
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
if [[ "$output_dir" == / \
  || ("$metadata_only" == false && "$output_dir" == "$package_dir") \
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
mkdir -p "$output_dir/apt" "$output_dir/pages/rpm"
release_tool="$(dirname "$0")/release_tool.py"
release_download_url="https://github.com/$release_repository/releases/download"

# Migrate the original mixed-architecture flat indexes into independent repositories.
for repository_channel in stable nightly; do
  legacy_directory="$output_dir/apt/$repository_channel"
  legacy_packages="$legacy_directory/Packages"
  if [[ -f "$legacy_packages" ]]; then
    for deb_arch in amd64 arm64; do
      extracted_packages="$temporary_dir/$repository_channel-$deb_arch.Packages"
      python3 "$release_tool" extract-apt-architecture \
        --input "$legacy_packages" \
        --architecture "$deb_arch" \
        --output "$extracted_packages"
      if [[ ! -s "$extracted_packages" ]]; then
        continue
      fi

      apt_destination="$legacy_directory/$deb_arch"
      mkdir -p "$apt_destination"
      merge_args=(
        merge-apt
        --incoming "$extracted_packages"
        --output "$temporary_dir/$repository_channel-$deb_arch.merged"
      )
      if [[ -f "$apt_destination/Packages" ]]; then
        merge_args+=(--existing "$apt_destination/Packages")
      fi
      python3 "$release_tool" "${merge_args[@]}"
      mv "$temporary_dir/$repository_channel-$deb_arch.merged" \
        "$apt_destination/Packages"
    done
    rm -f \
      "$legacy_directory/Packages" \
      "$legacy_directory/Packages.gz" \
      "$legacy_directory/Release" \
      "$legacy_directory/InRelease" \
      "$legacy_directory/Release.gpg"
  fi
  rm -f \
    "$legacy_directory/KEY.gpg" \
    "$legacy_directory/t3code-$repository_channel.sources"
done

if [[ "$metadata_only" == false ]]; then
  mkdir -p "$output_dir/apt/$channel" "$output_dir/pages/rpm/$channel"
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
    dpkg-scanpackages --multiversion "$tag" /dev/null \
      > "$temporary_dir/Packages.incoming.raw"
  )
  awk -v prefix="$tag/" '
    $1 == "Filename:" {
      if (index($2, prefix) != 1) exit 42
      $2 = "../" $2
    }
    { print }
  ' "$temporary_dir/Packages.incoming.raw" > "$temporary_dir/Packages.incoming"

  for deb_arch in amd64 arm64; do
    if [[ -z "${deb_arches[$deb_arch]:-}" ]]; then
      continue
    fi
    incoming_packages="$temporary_dir/Packages.incoming.$deb_arch"
    python3 "$release_tool" extract-apt-architecture \
      --input "$temporary_dir/Packages.incoming" \
      --architecture "$deb_arch" \
      --output "$incoming_packages"
    test -s "$incoming_packages"

    apt_destination="$output_dir/apt/$channel/$deb_arch"
    mkdir -p "$apt_destination"
    merge_args=(
      merge-apt
      --incoming "$incoming_packages"
      --output "$temporary_dir/Packages.merged.$deb_arch"
    )
    if [[ -f "$apt_destination/Packages" ]]; then
      merge_args+=(--existing "$apt_destination/Packages")
    fi
    python3 "$release_tool" "${merge_args[@]}"
    mv "$temporary_dir/Packages.merged.$deb_arch" "$apt_destination/Packages"
  done

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
fi

for bootstrap_channel in stable nightly; do
  sources_file="$output_dir/pages/t3code-$bootstrap_channel.sources"
  rm -f "$sources_file"
  stanza_written=false
  for deb_arch in amd64 arm64; do
    if [[ ! -f "$output_dir/apt/$bootstrap_channel/$deb_arch/Packages" ]]; then
      continue
    fi
    if [[ "$stanza_written" == true ]]; then
      printf '\n' >> "$sources_file"
    fi
    printf '%s\n' \
      'Types: deb' \
      "URIs: $release_download_url/apt-$bootstrap_channel-$deb_arch" \
      'Suites: ./' \
      "Architectures: $deb_arch" \
      'Signed-By: /etc/apt/keyrings/t3code-archive-keyring.gpg' \
      >> "$sources_file"
    stanza_written=true
  done

  rpm_metadata_found=false
  for rpm_arch in x86_64 aarch64; do
    if [[ -f "$output_dir/pages/rpm/$bootstrap_channel/$rpm_arch/repodata/repomd.xml" ]]; then
      rpm_metadata_found=true
    fi
  done
  if [[ "$rpm_metadata_found" == true ]]; then
    printf '%s\n' \
      "[t3code-$bootstrap_channel]" \
      "name=T3 Code ($bootstrap_channel, unofficial)" \
      "baseurl=$metadata_base_url/rpm/$bootstrap_channel/\$basearch" \
      'enabled=1' \
      'gpgcheck=1' \
      'repo_gpgcheck=1' \
      "gpgkey=$metadata_base_url/KEY.gpg" \
      'metadata_expire=1h' \
      > "$output_dir/pages/t3code-$bootstrap_channel.repo"
  fi
done

if [[ -n "$signing_key" ]]; then
  gpg --batch --yes --export "$signing_key" > "$temporary_dir/KEY.gpg"
  cp -p "$temporary_dir/KEY.gpg" "$output_dir/pages/KEY.gpg"
  for repository_channel in stable nightly; do
    for rpm_arch in x86_64 aarch64; do
      repomd="$output_dir/pages/rpm/$repository_channel/$rpm_arch/repodata/repomd.xml"
      if [[ -f "$repomd" ]]; then
        gpg --batch --yes --default-key "$signing_key" --armor --detach-sign \
          --output "$repomd.asc" "$repomd"
      fi
    done
  done
else
  rm -f "$output_dir/pages/KEY.gpg"
  find "$output_dir/pages/rpm" -type f -name 'repomd.xml.asc' -delete
fi

for repository_channel in stable nightly; do
  for deb_arch in amd64 arm64; do
    apt_directory="$output_dir/apt/$repository_channel/$deb_arch"
    if [[ ! -f "$apt_directory/Packages" ]]; then
      continue
    fi
    if ! awk -v expected="$deb_arch" \
      '$1 == "Architecture:" && $2 != expected { exit 1 }' \
      "$apt_directory/Packages"; then
      echo "APT index contains the wrong architecture: $apt_directory/Packages" >&2
      exit 1
    fi
    gzip -9n -c "$apt_directory/Packages" > "$apt_directory/Packages.gz"
    rm -f "$apt_directory/Release" "$apt_directory/InRelease" \
      "$apt_directory/Release.gpg"
    (
      cd "$apt_directory"
      apt-ftparchive \
        -o 'APT::FTPArchive::Release::Origin=T3 Code Linux Packages' \
        -o "APT::FTPArchive::Release::Label=T3 Code Linux Packages ($repository_channel, $deb_arch)" \
        -o "APT::FTPArchive::Release::Suite=$repository_channel" \
        -o "APT::FTPArchive::Release::Codename=$repository_channel" \
        -o "APT::FTPArchive::Release::Architectures=$deb_arch" \
        release . > Release
    )
    if [[ -n "$signing_key" ]]; then
      gpg --batch --yes --default-key "$signing_key" --clearsign \
        --output "$apt_directory/InRelease" "$apt_directory/Release"
      gpg --batch --yes --default-key "$signing_key" --armor --detach-sign \
        --output "$apt_directory/Release.gpg" "$apt_directory/Release"
    fi
  done
done

echo "Updated retained package metadata at $output_dir"
