#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo "usage: scripts/retry-collection-mainnet.sh" >&2
  exit 64
fi

export RETRY_NETWORK=mainnet
exec acton script scripts/retry-collection-deployment.tolk --net mainnet
