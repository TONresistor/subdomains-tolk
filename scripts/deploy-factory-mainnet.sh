#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo "usage: scripts/deploy-factory-mainnet.sh" >&2
  exit 64
fi

export DEPLOY_NETWORK=mainnet
exec acton script scripts/deploy-factory.tolk --net mainnet
