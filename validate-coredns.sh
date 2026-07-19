#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
COREDNS_CONFIG="$REPO_ROOT/clusters/pibox/apps/coredns-custom/configmap.yaml"

ingress_hosts=$(grep -rl 'kind: Ingress' "$REPO_ROOT"/clusters/pibox/apps/ \
    | xargs grep -h 'host:' \
    | sed 's/.*host:\s*//' \
    | grep 'paas\.lsedlar\.cz$' \
    | sort -u)

coredns_hosts=$(grep -oE '[a-z0-9.-]+\.paas\.lsedlar\.cz' "$COREDNS_CONFIG" | sort -u)

missing=()
for host in $ingress_hosts; do
    if ! echo "$coredns_hosts" | grep -qxF "$host"; then
        missing+=("$host")
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "FAIL: the following ingress hosts are missing from coredns-custom:"
    for host in "${missing[@]}"; do
        echo "  - $host"
    done
    exit 1
fi

echo "OK: all ingress hosts are present in coredns-custom"
