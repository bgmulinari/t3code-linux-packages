#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --source DIR --patch FILE --output DIR --version VERSION --arch ARCH --commit SHA" >&2
}

source_dir=""
patch_file=""
output_dir=""
version=""
arch=""
expected_commit=""

while (($# > 0)); do
  case "$1" in
    --source)
      source_dir="${2:-}"
      shift 2
      ;;
    --patch)
      patch_file="${2:-}"
      shift 2
      ;;
    --output)
      output_dir="${2:-}"
      shift 2
      ;;
    --version)
      version="${2:-}"
      shift 2
      ;;
    --arch)
      arch="${2:-}"
      shift 2
      ;;
    --commit)
      expected_commit="${2:-}"
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$source_dir" || -z "$patch_file" || -z "$output_dir" || -z "$version" || -z "$arch" || -z "$expected_commit" ]]; then
  usage
  exit 2
fi

source_dir="$(realpath "$source_dir")"
patch_file="$(realpath "$patch_file")"
mkdir -p "$output_dir"
output_dir="$(realpath "$output_dir")"

if [[ ! -d "$source_dir/.git" ]]; then
  echo "Source is not a Git checkout: $source_dir" >&2
  exit 1
fi
if [[ ! -f "$patch_file" ]]; then
  echo "Packaging patch does not exist: $patch_file" >&2
  exit 1
fi
if [[ ! "$expected_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Expected commit is not a full SHA: $expected_commit" >&2
  exit 1
fi
if [[ "$arch" != "x64" && "$arch" != "arm64" ]]; then
  echo "Unsupported Electron architecture: $arch" >&2
  exit 1
fi

actual_commit="$(git -C "$source_dir" rev-parse HEAD)"
if [[ "$actual_commit" != "$expected_commit" ]]; then
  echo "Upstream checkout mismatch: expected $expected_commit, found $actual_commit" >&2
  exit 1
fi
if ! git -C "$source_dir" diff --quiet || ! git -C "$source_dir" diff --cached --quiet; then
  echo "Upstream checkout must be clean before applying the packaging patch." >&2
  exit 1
fi

git -C "$source_dir" apply --check "$patch_file"
git -C "$source_dir" apply "$patch_file"

if [[ -e "$source_dir/.env" ]]; then
  echo "Unexpected .env already exists in the temporary upstream checkout." >&2
  exit 1
fi
cp "$source_dir/.env.example" "$source_dir/.env"

export T3CODE_DESKTOP_UPDATE_REPOSITORY="pingdotgg/t3code"

(
  cd "$source_dir"
  node scripts/update-release-package-versions.ts "$version"
  vp run dist:desktop:artifact \
    --platform linux \
    --target deb,rpm \
    --arch "$arch" \
    --build-version "$version" \
    --output-dir "$output_dir" \
    --verbose
)

mapfile -d '' deb_files < <(find "$output_dir" -maxdepth 1 -type f -name '*.deb' -print0)
mapfile -d '' rpm_files < <(find "$output_dir" -maxdepth 1 -type f -name '*.rpm' -print0)

if ((${#deb_files[@]} != 1 || ${#rpm_files[@]} != 1)); then
  echo "Expected exactly one .deb and one .rpm; found ${#deb_files[@]} and ${#rpm_files[@]}." >&2
  exit 1
fi

echo "Built ${deb_files[0]}"
echo "Built ${rpm_files[0]}"
