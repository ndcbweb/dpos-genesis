#!/usr/bin/env bash
# Builds a fresh BSC (Parlia) DPoS network: validator + BLS keys, node keys and genesis.json.
# Env: CHAIN_ID, MINT (0x address), SUPPLY (whole coins), VALIDATORS (default 3),
#      BLOCK_TIME (seconds, default 3), STAKE (self-delegation per validator, default 20001), OUT (default /out)
set -euo pipefail
: "${CHAIN_ID:?}" "${MINT:?}" "${SUPPLY:?}"
N=${VALIDATORS:-3}
BLOCK_TIME=${BLOCK_TIME:-3}
STAKE=${STAKE:-20001}
OUT=${OUT:-/out}
GENESIS_DELAY=${GENESIS_DELAY:-60}
G=/node-deploy/genesis
PY="$G/.venv/bin/python"
[ -x "$PY" ] || PY="poetry run python"
MINT=$(echo "$MINT" | tr 'A-F' 'a-f')

mkdir -p "$OUT"
[ -f "$OUT/password.txt" ] || openssl rand -hex 16 > "$OUT/password.txt"
PW="$OUT/password.txt"

cd "$G"
rm -rf contracts && cp -r /node-deploy/contracts.pristine contracts
sed -i -e 's/alreadyInit = true;/turnLength = 16;alreadyInit = true;/' contracts/BSCValidatorSet.sol
rm -f validators.conf

VALS=()
for ((i = 0; i < N; i++)); do
  d="$OUT/node$i"
  mkdir -p "$d/geth"
  if [ ! -d "$d/keystore" ]; then
    geth account new --datadir "$d" --password "$PW" >/dev/null 2>&1
    geth bls wallet create --datadir "$d" --blspassword "$PW" >/dev/null 2>&1
    geth bls account new --datadir "$d" --blspassword "$PW" >/dev/null 2>&1
    openssl rand -hex 32 | tr -d '\n' > "$d/geth/nodekey"
  fi
  addr="0x$(jq -r .address "$d"/keystore/*)"
  vote="0x$(jq -r .pubkey "$d"/bls/keystore/*.json)"
  VALS+=("$addr")
  echo "${addr},${addr},${addr},0x000001d1a94a2000,${vote}" >> validators.conf
done

# Validators are funded out of the total supply so their self-delegation can be staked.
python3 - "$MINT" "$SUPPLY" "$STAKE" "${VALS[@]}" > scripts/init_holders.js <<'PY'
import sys
mint, supply, stake, vals = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4:]
wei = 10**18
fund = (stake + 10) * wei
rest = supply * wei - fund * len(vals)
if rest <= 0:
    sys.exit(f"total supply {supply} is too small: validators need {(stake + 10) * len(vals)}")
rows = [(mint, rest)] + [(v, fund) for v in vals]
print("const init_holders = [")
for addr, bal in rows:
    print(f"  {{ address: '{addr}', balance: BigInt('{bal}').toString(16) }},")
print("];\nexports = module.exports = init_holders;")
PY

$PY -m scripts.generate generate-validators >/dev/null
$PY -m scripts.generate dev \
  --dev-chain-id "$(( CHAIN_ID <= 65535 ? CHAIN_ID : 714 ))" \
  --init-burn-ratio "1000" \
  --init-felony-slash-scope "60" \
  --breathe-block-interval "1 days" \
  --block-interval "3 seconds" \
  --stake-hub-protector "${MINT}" \
  --unbond-period "7 days" \
  --downtime-jail-time "2 days" \
  --felony-jail-time "30 days" \
  --misdemeanor-threshold "50" \
  --felony-threshold "150" \
  --init-voting-period "7 days / BLOCK_INTERVAL" \
  --init-min-period-after-quorum "uint64(1 days / BLOCK_INTERVAL)" \
  --governor-protector "${MINT}" \
  --init-minimal-delay "24 hours" \
  --token-recover-portal-protector "${MINT}" >/tmp/generate.log 2>&1 || { tail -40 /tmp/generate.log; exit 1; }

# Genesis sits slightly in the future so every validator is peered before block 1 is sealed;
# otherwise each one seals its own block 1 and the forks never converge.
# System.sol keeps a uint16 cross-chain id; the EVM chain id lives only in the genesis config.
# No BNB Beacon Chain bridge reserve on a custom chain. Block interval: 3s pre-Lorentz,
# 1.5s with Lorentz, 0.75s with Maxwell.
jq --argjson bt "$BLOCK_TIME" --argjson cid "$CHAIN_ID" --arg ts "$(printf '0x%x' $(( $(date +%s) + GENESIS_DELAY )))" '
  .config.chainId = $cid
  | .timestamp = $ts
  | .alloc["0x0000000000000000000000000000000000001004"].balance = "0x0"
  | if $bt >= 3 then del(.config.lorentzTime)
    elif $bt >= 1.5 then .config.lorentzTime = 0
    else .config.lorentzTime = 0 | .config.maxwellTime = 0 end
' genesis-dev.json > "$OUT/genesis.json"

ENODES=$(for ((i = 0; i < N; i++)); do
  $PY -c 'import sys;from eth_keys import keys;print(keys.PrivateKey(bytes.fromhex(open(sys.argv[1]).read().strip())).public_key.to_hex()[2:])' "$OUT/node$i/geth/nodekey"
done | jq -R . | jq -sc .)
jq -n --argjson enodes "$ENODES" --arg vals "${VALS[*]}" --arg mint "$MINT" --argjson chainId "$CHAIN_ID" \
  '{chainId: $chainId, mint: $mint, validators: ($vals | split(" ")), enodes: $enodes}' > "$OUT/network.json"
cat "$OUT/network.json"
