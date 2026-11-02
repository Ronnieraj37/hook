# Sepolia deployment

Everything here is on **Ethereum Sepolia** (chain id 11155111). The JSON files next to this README are written by the deploy scripts and read by the frontend (`frontend/scripts/sync.mjs`).

## Contracts

| Contract | Address |
|---|---|
| RuleHook (hook: pool table + limit orders) | [`0x9D4E651bb9a27a9b1406151b3f12Bb1a61B090c0`](https://sepolia.etherscan.io/address/0x9D4E651bb9a27a9b1406151b3f12Bb1a61B090c0) |
| ConditionalOrders (LP positions with rules) | [`0xf2b46cb234E2A901cb8F48e3589B4fB2F2AFcA6f`](https://sepolia.etherscan.io/address/0xf2b46cb234E2A901cb8F48e3589B4fB2F2AFcA6f) |
| Uniswap v4 PoolManager | [`0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`](https://sepolia.etherscan.io/address/0xE03A1074c86CFeDd5C142C4F04F1a1536e203543) |
| Uniswap v4 PositionManager | [`0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4`](https://sepolia.etherscan.io/address/0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4) |
| Swap router (hookmate) | [`0xf13D190e9117920c703d79B5F33732e10049b115`](https://sepolia.etherscan.io/address/0xf13D190e9117920c703d79B5F33732e10049b115) |

Deployed at block 12048765.

## Test tokens

Open mint: anyone can call `mint(to, amount)`. No value. Reuse them; do not redeploy.

Faucet (all six tokens in one transaction: 100 tWETH, 5 tWBTC, 500k tUSDC/tUSDT/tDAI, 20k tLINK): `drip()` on
[`0xE991cFD1A6EF2f42CdD2A1633a5605D5ea5d18fF`](https://sepolia.etherscan.io/address/0xE991cFD1A6EF2f42CdD2A1633a5605D5ea5d18fF).

| Token | Decimals | Address |
|---|---|---|
| tWETH | 18 | [`0x4119A4dab16764aD6056DD6C7f744F6cd8d9B4Ca`](https://sepolia.etherscan.io/address/0x4119A4dab16764aD6056DD6C7f744F6cd8d9B4Ca) |
| tWBTC | 8 | [`0x3630EEB9719BCabC532f049Ef663991f4E110E74`](https://sepolia.etherscan.io/address/0x3630EEB9719BCabC532f049Ef663991f4E110E74) |
| tUSDC | 6 | [`0x5B7E3901456fEd7158D583FBaA9736fff611Fc5b`](https://sepolia.etherscan.io/address/0x5B7E3901456fEd7158D583FBaA9736fff611Fc5b) |
| tUSDT | 6 | [`0x9289d26a4B38d3CBCc25471f1e69cbbc8d4a8121`](https://sepolia.etherscan.io/address/0x9289d26a4B38d3CBCc25471f1e69cbbc8d4a8121) |
| tDAI | 18 | [`0x58e283AFE1Db9704EB73cFBB0032b8DEBeC9b719`](https://sepolia.etherscan.io/address/0x58e283AFE1Db9704EB73cFBB0032b8DEBeC9b719) |
| tLINK | 18 | [`0xCe340f6faE8c61787f4Af123a97e344b53122510`](https://sepolia.etherscan.io/address/0xCe340f6faE8c61787f4Af123a97e344b53122510) |

## Pools

Started at the Sepolia Chainlink prices at deploy time (USDT has no feed there and starts at $1). Liquidity added by the deployer as a normal LP.

| Index | Pool | Fee | Spacing | Hook | Liquidity |
|---|---|---|---|---|---|
| 1 | WETH / USDC | 0.3% | 60 | RuleHook | full range $5M/side + ±5% $2M/side |
| 2 | WBTC / USDC | 0.3% | 60 | RuleHook | full range $5M/side + ±10% $2M/side |
| 3 | WBTC / WETH | 0.05% | 10 | RuleHook | ±2% $2M/side |
| 4 | USDC / USDT | 0.01% | 1 | RuleHook | ±0.2% $5M/side |
| 5 | WETH / LINK | 1.0% | 200 | RuleHook | full range $2M/side |
| 6 | DAI / USDC | 0.01% | 1 | RuleHook | ±0.5% $3M/side |
| 7 | WETH / USDC | 0.05% | 10 | none (in the pool table for price checks and swaps) | full range $5M/side |
| 8 | ETH / USDC | 0.3% | 60 | RuleHook | full range + ±5%, ~$10/side each (real Sepolia ETH) |

## Re-running

The deployer key is read from `.env` (`PRIVATE_KEY`, never committed). Sepolia now charges far more gas for creating
contracts and storage than Foundry's local simulation assumes, so every command adds `--gas-estimate-multiplier 1000`
(gas is ~17 wei there, so this costs nothing). Without it, deployments run out of gas. Sepolia also caps one
transaction at about 16.7M gas, so for calls with a large estimate (the trial's `keep` phase) use
`--gas-estimate-multiplier 300` instead, or the transaction is refused before it is sent.

```bash
forge script script/sepolia/01_DeployTokens.s.sol --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast --slow --gas-estimate-multiplier 1000
forge script script/sepolia/02_DeployCore.s.sol   --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast --slow --gas-estimate-multiplier 1000
forge script script/sepolia/03_CreatePools.s.sol  --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY --broadcast --slow --gas-estimate-multiplier 1000
```

Trial of every order type (`script/sepolia/04_Trial.s.sol`), one phase per run: `PHASE=orders`, `up`, `keep`, `down`,
`keep`. Run the `keep` phase with `--isolate` so each execution is its own transaction (an execution right after a swap
in the same transaction is refused on purpose).

After a new deployment: `cd frontend && npm run sync`.

## Trial results (2026-11-02, real Sepolia)

| Order | Rule | Result |
|---|---|---|
| #1 | Take profit: exit when WETH leaves the range upward | Executed after the price rose |
| #2 | Stop loss: exit below the range and convert to USDC | Executed after the price fell, swap within the 1% limit |
| #3 | Follow the price: re-range just below the new price, repeating | Re-ranged once, still open |
| #4 | Compound fees every minute | Ran three times, still open |
| #5 | WBTC position exits when WETH drops 3% in the hookless pool | Executed (cross-pool check) |
| #6 | Native ETH pool take profit (keeper paid exact gas) | Executed |
| Limit sell | Sell $2,000 of WETH just above the price | Filled inside a swap, claimed 2,038 USDC |
| Limit buy | Buy WETH with $2,000 just below the price | Filled inside a swap, claimed 0.8948 WETH |
