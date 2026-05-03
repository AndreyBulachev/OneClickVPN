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
