#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PORT="${PORT:-8471}"
echo "build-server ready on port $PORT (repo $REPO_ROOT)"
exec python3 "$SCRIPT_DIR/server.py"
