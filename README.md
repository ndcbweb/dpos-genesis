# dpos-genesis

Docker image that creates a fresh BNB Smart Chain style (Parlia) DPoS network for Nadcab Console trial fleets.
It wraps [bnb-chain/node-deploy](https://github.com/bnb-chain/node-deploy) and the BSC genesis contracts.

The `latest` release holds `dpos-genesis.tar.gz` (`docker save` output), rebuilt on every push to `main`.

```bash
curl -fsSL https://github.com/ndcbweb/dpos-genesis/releases/download/latest/dpos-genesis.tar.gz | docker load
docker run --rm -v /opt/dpos:/out \
  -e CHAIN_ID=7714001 -e MINT=0xYourWallet -e SUPPLY=1000000000 -e VALIDATORS=3 -e BLOCK_TIME=3 \
  nadcab/dpos-genesis nadcab-dpos-genesis.sh
```

Output in `/out`: `genesis.json`, `network.json` (validators and node enode ids), `password.txt` and
`node<i>/` with each validator's keystore, BLS wallet and node key.

`BLOCK_TIME` picks the fork set: 3 s (pre-Lorentz), 1.5 s (Lorentz) or 0.75 s (Maxwell).
Validators are funded out of `SUPPLY` with `STAKE + 10` coins each so they can self-delegate in StakeHub
with `create-validator`.
