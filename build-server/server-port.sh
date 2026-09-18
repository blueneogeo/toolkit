# Per-project build-server port derivation (hash repo dir into 8471-8570).
[[ -n "${_BUILDER_PORT_SOURCED:-}" ]] && return 0; _BUILDER_PORT_SOURCED=1

BUILDER_PORT_LO=8471
BUILDER_PORT_HI=8570

_builder_port_for() {
    local sum
    sum=$(printf '%s' "$1" | cksum | awk '{print $1}')
    printf '%s\n' "$((BUILDER_PORT_LO + sum % 100))"
}
