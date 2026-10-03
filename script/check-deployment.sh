#!/usr/bin/env bash
# Rebuild FloorHook from this repo and compare it with its deployment on Robinhood Chain: the deployment
# transaction went through the deterministic CREATE2 deployer (0x4e59...956C), so its input is a 32-byte
# salt followed by FloorHook's init code and constructor arguments. They must match byte for byte.
#   ./script/check-deployment.sh [rpc-url]
set -euo pipefail
cd "$(dirname "$0")/.."
RPC="${1:-https://rpc.mainnet.chain.robinhood.com}"
TX=0x6cb55ed6f41a0391eb705699d2a1fd6f2c6572d814c2d7e4315e40fe58e27155
ARGS=000000000000000000000000b67abe49d5cb1ea6cb7672e59bbcbb0333c932bf0000000000000000000000008366a39cc670b4001a1121b8f6a443a643e40951000000000000000000000000e64a3fd6b7006751d8ef01e5893a42b16e61a161
forge build --force --skip test --skip script >/dev/null 2>&1
INIT=$(jq -r '.bytecode.object' out/FloorHook.sol/FloorHook.json | sed 's/^0x//')
INPUT=$(cast tx "$TX" input --rpc-url "$RPC" | sed 's/^0x//')
if [ "${INPUT:64}" = "${INIT}${ARGS}" ]; then
  echo "MATCH: this repo's FloorHook is byte for byte the code deployed at 0x7d309A342f12e7f788CCF992740E5C482D4B6044"
else
  echo "MISMATCH"; exit 1
fi
