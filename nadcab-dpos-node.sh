#!/usr/bin/env bash
# Runs one BSC geth node from a nadcab-dpos-genesis.sh bundle.
# Env: BUNDLE (dir with genesis.json/network.json/password.txt), DATADIR, VALIDATOR_INDEX (empty = full node),
#      P2P_PORT, HTTP_PORT, HTTP_ADDR, GCMODE, EXTIP, PEERS (comma separated enode URLs), APIS
set -euo pipefail
: "${BUNDLE:?}" "${DATADIR:?}"
P2P_PORT=${P2P_PORT:-30303}
HTTP_PORT=${HTTP_PORT:-8545}
HTTP_ADDR=${HTTP_ADDR:-0.0.0.0}
GCMODE=${GCMODE:-full}
APIS=${APIS:-eth,net,web3,txpool,parlia}
CHAIN_ID=$(jq -r .chainId "$BUNDLE/network.json")

mkdir -p "$DATADIR/geth"
if [ -n "${VALIDATOR_INDEX:-}" ]; then
  src="$BUNDLE/node$VALIDATOR_INDEX"
  [ -d "$DATADIR/keystore" ] || cp -r "$src/keystore" "$src/bls" "$DATADIR/"
  cp "$src/geth/nodekey" "$DATADIR/geth/nodekey"
fi
[ -f "$DATADIR/geth/nodekey" ] || openssl rand -hex 32 | tr -d '\n' > "$DATADIR/geth/nodekey"
[ -d "$DATADIR/geth/chaindata" ] || geth --datadir "$DATADIR" init --state.scheme hash "$BUNDLE/genesis.json"

peers=$(echo "${PEERS:-}" | tr ',' '\n' | sed '/^$/d' | jq -R . | jq -sc .)
cat > "$DATADIR/config.toml" <<EOF
[Node.P2P]
StaticNodes = $peers
EOF

args=(
  --config "$DATADIR/config.toml"
  --datadir "$DATADIR" --nodekey "$DATADIR/geth/nodekey"
  --networkid "$CHAIN_ID" --port "$P2P_PORT"
  --syncmode full --gcmode "$GCMODE" --state.scheme hash --cache 128
  --http --http.addr "$HTTP_ADDR" --http.port "$HTTP_PORT" --http.vhosts '*' --http.corsdomain '*' --http.api "$APIS"
  --ws --ws.addr "$HTTP_ADDR" --ws.port "$((HTTP_PORT + 1))" --ws.origins '*' --ws.api "$APIS"
  --rpc.allow-unprotected-txs
)
[ -n "${EXTIP:-}" ] && args+=(--nat "extip:$EXTIP")
if [ -n "${VALIDATOR_INDEX:-}" ]; then
  addr="0x$(jq -r .address "$DATADIR"/keystore/*)"
  args+=(--mine --vote --unlock "$addr" --miner.etherbase "$addr"
    --password "$BUNDLE/password.txt" --blspassword "$BUNDLE/password.txt" --allow-insecure-unlock)
fi
exec geth "${args[@]}"
