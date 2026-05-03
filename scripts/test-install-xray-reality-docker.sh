#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

docker run --rm \
  -v "${repo_root}:/work:ro" \
  -w /work \
  ubuntu:24.04 \
  bash -lc '
    set -Eeuo pipefail
    bash -n core/ubuntu/install-xray-reality.sh
    bash core/ubuntu/install-xray-reality.sh --self-test
  '

if [[ "${LIVE_XRAY_TEST:-0}" == "1" ]]; then
  docker run --rm \
    -v "${repo_root}:/work:ro" \
    -w /work \
    ubuntu:24.04 \
    bash -lc '
      set -Eeuo pipefail
      export DEBIAN_FRONTEND=noninteractive
      apt-get update >/dev/null
      apt-get install -y --no-install-recommends ca-certificates curl unzip >/dev/null
      curl -fsSL https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip -o /tmp/xray.zip
      unzip -q /tmp/xray.zip -d /tmp/xray
      chmod +x /tmp/xray/xray
      source core/ubuntu/install-xray-reality.sh
      output="$(/tmp/xray/xray x25519)"
      private_key="$(extract_x25519_key "privatekey" <<<"$output")"
      public_key="$(extract_x25519_key "publickey" <<<"$output")"
      [[ -n "$private_key" ]] || { printf "%s\n" "$output"; exit 1; }
      [[ -n "$public_key" ]] || { printf "%s\n" "$output"; exit 1; }
      printf "OK: live xray x25519 parser test passed.\n"
    '
fi
