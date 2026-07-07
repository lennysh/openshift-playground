#!/usr/bin/env bash
# Thin wrapper around generate-aap-cr-examples.py
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "${SCRIPT_DIR}/generate-aap-cr-examples.py" "$@"
