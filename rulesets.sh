#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SOURCE_FILE="${1:-${SCRIPT_DIR}/meta-rules-data}"
readonly QX_OUTPUT_DIR="${SCRIPT_DIR}/QX"
readonly SHADOWROCKET_OUTPUT_DIR="${SCRIPT_DIR}/ShadowRocket"

if [[ ! -f "${SOURCE_FILE}" ]]; then
  echo "Source file not found: ${SOURCE_FILE}" >&2
  exit 1
fi

stage_dir="$(mktemp -d)"
trap 'rm -rf -- "${stage_dir}"' EXIT
mkdir -p "${stage_dir}/QuantumultX" "${stage_dir}/Shadowrocket"

convert_rules() {
  local input_file="$1"
  local qx_file="$2"
  local shadowrocket_file="$3"
  local qx_policy="$4"

  awk -v qx_file="${qx_file}" \
    -v shadowrocket_file="${shadowrocket_file}" \
    -v qx_policy="${qx_policy}" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }

    {
      sub(/\r$/, "")
      rule = trim($0)

      if (rule == "" || rule ~ /^#/) {
        next
      }

      if (rule ~ /^regexp:/ || rule ~ /^keyword:/) {
        print "Skipping unsupported rule: " rule > "/dev/stderr"
        next
      }

      if (rule ~ /^full:/) {
        sub(/^full:/, "", rule)
        qx_type = "HOST"
        shadowrocket_type = "DOMAIN"
      } else if (rule ~ /^domain:/) {
        sub(/^domain:/, "", rule)
        qx_type = "HOST-SUFFIX"
        shadowrocket_type = "DOMAIN-SUFFIX"
      } else if (rule ~ /^\+\./) {
        sub(/^\+\./, "", rule)
        qx_type = "HOST-SUFFIX"
        shadowrocket_type = "DOMAIN-SUFFIX"
      } else {
        qx_type = "HOST"
        shadowrocket_type = "DOMAIN"
      }

      if (rule != "") {
        print qx_type "," rule "," qx_policy >> qx_file
        print shadowrocket_type "," rule >> shadowrocket_file
      }
    }
  ' "${input_file}"
}

add_qx_header() {
  local rules_file="$1"
  local output_file="$2"
  local name="$3"
  local source_url="$4"
  local host_count
  local host_suffix_count
  local total_count

  host_count="$(awk -F, '$1 == "HOST" { count++ } END { print count + 0 }' "${rules_file}")"
  host_suffix_count="$(awk -F, '$1 == "HOST-SUFFIX" { count++ } END { print count + 0 }' "${rules_file}")"
  total_count="$(wc -l < "${rules_file}")"
  total_count="${total_count//[[:space:]]/}"

  {
    echo "# NAME: ${name}"
    echo "# SOURCE: ${source_url}"
    echo "# HOST: ${host_count}"
    echo "# HOST-SUFFIX: ${host_suffix_count}"
    echo "# TOTAL: ${total_count}"
    cat "${rules_file}"
  } > "${output_file}"
}

url_count=0
while IFS= read -r source_url || [[ -n "${source_url}" ]]; do
  source_url="${source_url%$'\r'}"
  [[ -z "${source_url}" || "${source_url}" == \#* ]] && continue

  if [[ ! "${source_url}" =~ ^https?:// ]]; then
    echo "Skipping invalid URL: ${source_url}" >&2
    continue
  fi

  file_name="${source_url%%\?*}"
  file_name="${file_name##*/}"
  if [[ -z "${file_name}" || "${file_name}" != *.list ]]; then
    echo "URL must end with a .list filename: ${source_url}" >&2
    exit 1
  fi

  upstream_file="${stage_dir}/upstream-${url_count}.list"
  qx_policy="${file_name%.list}"
  qx_rules_file="${stage_dir}/QuantumultX/${file_name}.rules"
  echo "Downloading ${source_url}"
  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 \
    --output "${upstream_file}" "${source_url}"

  : > "${qx_rules_file}"
  : > "${stage_dir}/Shadowrocket/${file_name}"
  convert_rules \
    "${upstream_file}" \
    "${qx_rules_file}" \
    "${stage_dir}/Shadowrocket/${file_name}" \
    "${qx_policy}"
  add_qx_header \
    "${qx_rules_file}" \
    "${stage_dir}/QuantumultX/${file_name}" \
    "${qx_policy}" \
    "${source_url}"
  rm -- "${qx_rules_file}"

  url_count=$((url_count + 1))
done < "${SOURCE_FILE}"

if ((url_count == 0)); then
  echo "No valid URLs found in ${SOURCE_FILE}" >&2
  exit 1
fi

mkdir -p "${QX_OUTPUT_DIR}" "${SHADOWROCKET_OUTPUT_DIR}"
find "${QX_OUTPUT_DIR}" "${SHADOWROCKET_OUTPUT_DIR}" -type f -name '*.list' -delete
cp "${stage_dir}/QuantumultX/"*.list "${QX_OUTPUT_DIR}/"
cp "${stage_dir}/Shadowrocket/"*.list "${SHADOWROCKET_OUTPUT_DIR}/"

echo "Generated ${url_count} Quantumult X and ${url_count} Shadowrocket rulesets."
