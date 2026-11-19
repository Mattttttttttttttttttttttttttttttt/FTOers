#!/usr/bin/env bash
# Works from any current directory. Node handles config, builds and portable links.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/scripts/update-subwebsites.mjs" "$@"
