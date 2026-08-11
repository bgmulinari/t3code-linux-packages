#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --directory DIR --deb-arch ARCH... --rpm-arch ARCH... [--require-rpm-signature]" >&2
}

package_dir=""
deb_arches=()
rpm_arches=()
require_rpm_signature=false

while (($# > 0)); do
  case "$1" in
    --directory)
      package_dir="${2:-}"
      shift 2
      ;;
    --deb-arch)
      deb_arches+=("${2:-}")
      shift 2
      ;;
    --rpm-arch)
      rpm_arches+=("${2:-}")
      shift 2
      ;;
    --require-rpm-signature)
      require_rpm_signature=true
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$package_dir" || ${#deb_arches[@]} -eq 0 || ${#rpm_arches[@]} -eq 0 ]]; then
  usage
  exit 2
fi

for command in rpm grep find; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Required command is missing: $command" >&2
    exit 1
  fi
done

if ! command -v dpkg-deb >/dev/null 2>&1; then
  for command in ar tar; do
    if ! command -v "$command" >/dev/null 2>&1; then
      echo "Required command is missing: $command (needed when dpkg-deb is unavailable)" >&2
      exit 1
    fi
  done
fi

deb_archive_stream() {
  local deb_file="$1"
  local archive_prefix="$2"
  local member

  member="$(ar t "$deb_file" | grep -E "^${archive_prefix}\\.tar(\\..+)?$" | head -n 1)"
  if [[ -z "$member" ]]; then
    echo "Missing ${archive_prefix} archive in $deb_file" >&2
    return 1
  fi

  case "$member" in
    *.gz) ar p "$deb_file" "$member" | tar -xzO "$3" ;;
    *.xz) ar p "$deb_file" "$member" | tar -xJO "$3" ;;
    *.bz2) ar p "$deb_file" "$member" | tar -xjO "$3" ;;
    *.zst) ar p "$deb_file" "$member" | tar --zstd -xO "$3" ;;
    *) ar p "$deb_file" "$member" | tar -xO "$3" ;;
  esac
}

deb_archive_list() {
  local deb_file="$1"
  local archive_prefix="$2"
  local member

  member="$(ar t "$deb_file" | grep -E "^${archive_prefix}\\.tar(\\..+)?$" | head -n 1)"
  if [[ -z "$member" ]]; then
    echo "Missing ${archive_prefix} archive in $deb_file" >&2
    return 1
  fi

  case "$member" in
    *.gz) ar p "$deb_file" "$member" | tar -tz ;;
    *.xz) ar p "$deb_file" "$member" | tar -tJ ;;
    *.bz2) ar p "$deb_file" "$member" | tar -tj ;;
    *.zst) ar p "$deb_file" "$member" | tar --zstd -t ;;
    *) ar p "$deb_file" "$member" | tar -t ;;
  esac
}

deb_field() {
  local deb_file="$1"
  local field="$2"

  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb --field "$deb_file" "$field"
    return
  fi

  deb_archive_stream "$deb_file" control ./control | awk -v field="$field" '
    index($0, field ":") == 1 {
      value = substr($0, length(field) + 2)
      sub(/^[[:space:]]+/, "", value)
      found = 1
      next
    }
    found && /^[[:space:]]/ {
      continuation = $0
      sub(/^[[:space:]]+/, "", continuation)
      value = value " " continuation
      next
    }
    found { print value; exit }
    END { if (found) print value }
  ' | awk '!seen[$0]++'
}

deb_contents() {
  local deb_file="$1"

  if command -v dpkg-deb >/dev/null 2>&1; then
    dpkg-deb --contents "$deb_file"
    return
  fi

  deb_archive_list "$deb_file" data
}

mapfile -d '' deb_files < <(find "$package_dir" -maxdepth 1 -type f -name '*.deb' -print0)
mapfile -d '' rpm_files < <(find "$package_dir" -maxdepth 1 -type f -name '*.rpm' -print0)
if ((${#deb_files[@]} != ${#deb_arches[@]} || ${#rpm_files[@]} != ${#rpm_arches[@]})); then
  echo "Expected ${#deb_arches[@]} .deb and ${#rpm_arches[@]} .rpm files; found ${#deb_files[@]} and ${#rpm_files[@]}." >&2
  exit 1
fi

declare -A expected_deb_arches=()
declare -A expected_rpm_arches=()
declare -A found_deb_arches=()
declare -A found_rpm_arches=()
declare -A deb_versions=()
declare -A rpm_versions=()

for architecture in "${deb_arches[@]}"; do
  [[ -n "$architecture" && -z "${expected_deb_arches[$architecture]:-}" ]]
  expected_deb_arches[$architecture]=1
done
for architecture in "${rpm_arches[@]}"; do
  [[ -n "$architecture" && -z "${expected_rpm_arches[$architecture]:-}" ]]
  expected_rpm_arches[$architecture]=1
done

for deb_file in "${deb_files[@]}"; do
  architecture="$(deb_field "$deb_file" Architecture)"
  version="$(deb_field "$deb_file" Version)"
  [[ "$(deb_field "$deb_file" Package)" == "t3code" ]]
  [[ -n "${expected_deb_arches[$architecture]:-}" ]]
  [[ -z "${found_deb_arches[$architecture]:-}" ]]
  found_deb_arches[$architecture]=1
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
  deb_versions[$version]=1
  deb_field "$deb_file" Depends | grep -Fq 'libgbm1'
  deb_contents "$deb_file" | grep -E '/opt/.+/t3code$' >/dev/null
  deb_contents "$deb_file" | grep -E '/usr/share/applications/.+\.desktop$' >/dev/null
  deb_contents "$deb_file" | grep -E '/opt/.+/resources/LICENSE\.t3code$' >/dev/null
  echo "Validated Debian package: $deb_file"
done

for rpm_file in "${rpm_files[@]}"; do
  architecture="$(rpm -qp --queryformat '%{ARCH}' "$rpm_file")"
  version="$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$rpm_file")"
  [[ "$(rpm -qp --queryformat '%{NAME}' "$rpm_file")" == "t3code" ]]
  [[ "$(rpm -qp --queryformat '%{LICENSE}' "$rpm_file")" == "MIT" ]]
  [[ -n "${expected_rpm_arches[$architecture]:-}" ]]
  [[ -z "${found_rpm_arches[$architecture]:-}" ]]
  found_rpm_arches[$architecture]=1
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]
  rpm_versions[$version]=1
  rpm -qp --requires "$rpm_file" | grep -Fq 'mesa-libgbm'
  rpm -qlp "$rpm_file" | grep -E '/opt/.+/t3code$' >/dev/null
  rpm -qlp "$rpm_file" | grep -E '/usr/share/applications/.+\.desktop$' >/dev/null
  rpm -qlp "$rpm_file" | grep -E '/opt/.+/resources/LICENSE\.t3code$' >/dev/null
  if rpm -qlp "$rpm_file" | grep -Eq '^/usr/lib/\.build-id(/|$)'; then
    echo "RPM package contains global build-ID links: $rpm_file" >&2
    exit 1
  fi
  if [[ "$require_rpm_signature" == true ]]; then
    rpm --checksig --verbose "$rpm_file" | grep -Eiq 'signature.*OK|digests signatures OK'
  fi
  echo "Validated RPM package: $rpm_file"
done

if ((${#deb_versions[@]} != 1 || ${#rpm_versions[@]} != 1)); then
  echo "Packages for different architectures do not share one version." >&2
  exit 1
fi
