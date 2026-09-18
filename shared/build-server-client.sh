# Renamed to shared/build-client.sh — shim so older checkouts/paths don't break; delete once downstream checkouts bump.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-client.sh"
