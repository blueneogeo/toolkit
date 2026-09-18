#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/server-port.sh"
PORT="${PORT:-$(_builder_port_for "$REPO_ROOT")}"
echo "build-server ready on port $PORT (repo $REPO_ROOT)"
exec python3 "$SCRIPT_DIR/server.py"
