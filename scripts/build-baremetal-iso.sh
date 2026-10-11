#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LITEEDGE_ISO_VARIANT=baremetal
exec "$ROOT/scripts/build-vm-iso.sh" "$@"
