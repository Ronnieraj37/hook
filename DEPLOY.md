# Deploying Alucard (free)

| Piece | Where | Cost |
|---|---|---|
| Frontend (`frontend/`) | Vercel, Hobby plan | free |
| Backtest API (`frontend/api/backtest.py`) | the same Vercel project (Python function) | free |
| Keeper bot (`frontend/scripts/keeper.ts`) | GitHub Actions schedule (`.github/workflows/keeper.yml`) | free (public repo; private: 2,000 min/month) |
| Contracts | already on Sepolia (`deployments/README.md`) | Sepolia gas only |

Keys live only in git-ignored files (`.env`, `frontend/.env.local`) or in the hosts' secret settings.

## 0. Before anything: put the code on GitHub

```bash
cd /Users/roshanrajsingh/Documents/v4-template
git add -A
git status          # check .env, frontend/.env.local and frontend/.venv are NOT listed
git commit -m "Alucard: contracts, Sepolia deployment, frontend, backtest API, keeper"
```

Create an empty GitHub repository, then `git remote add origin <url>` and `git push -u origin <branch>`.
`frontend/api/_data/` (~23 MB of swap history) must be committed: the backtest needs it.

## 1. Vercel (frontend + backtest)

1. vercel.com, New Project, import the GitHub repo.
2. **Root Directory: `frontend`**. Framework preset: Next.js (detected).
3. Environment variable (Production and Preview): `NEXT_PUBLIC_RPC_URL` = your Alchemy Sepolia URL
   (`https://eth-sepolia.g.alchemy.com/v2/<key>`).
4. Deploy. Vercel builds the Next.js app and, from the same folder, the Python function `api/backtest.py`
   (`requirements.txt` installs numpy; `vercel.json` bundles `api/_data` and allows 60 s per request).
5. Check after the first deploy:
   - `https://<your-app>.vercel.app/api/backtest` answers `{"ok":true,"pools":[...]}`
   - Pool, New position, turn on rules, pick a template, **Backtest**: results appear in about a second.
6. In the Alchemy dashboard, restrict the key to your Vercel domain (it is visible in the browser).

Every push to the main branch redeploys. After a new contract deployment: `cd frontend && npm run sync`, commit, push.

## 2. Keeper bot (GitHub Actions)

Off until you switch it on.

1. GitHub repo, Settings, Secrets and variables, Actions:
   - Secret `KEEPER_PRIVATE_KEY`: the deployer key for now (`PRIVATE_KEY` in `.env`).
   - Secret `SEPOLIA_RPC_URL`: an RPC URL (the Alchemy URL works; a separate server-side key is better).
   - Variable `KEEPER_ENABLED` = `true`.
2. It runs every 5 minutes (GitHub sometimes starts late). Actions tab: logs, and "Run workflow" to run it now.
3. Private repo: change the cron in `.github/workflows/keeper.yml` to `*/15 * * * *` or slower.

Try it locally without sending anything: `cd frontend && DRY_RUN=1 npx tsx scripts/keeper.ts`

## 3. Verify the contracts on Etherscan (optional)

```bash
set -a; source .env; set +a
PM=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
forge verify-contract --chain sepolia --watch 0x9D4E651bb9a27a9b1406151b3f12Bb1a61B090c0 src/RuleHook.sol:RuleHook \
  --constructor-args $(cast abi-encode "constructor(address)" $PM)
forge verify-contract --chain sepolia --watch 0xf2b46cb234E2A901cb8F48e3589B4fB2F2AFcA6f src/ConditionalOrders.sol:ConditionalOrders \
  --constructor-args $(cast abi-encode "constructor(address,address)" $PM 0x9D4E651bb9a27a9b1406151b3f12Bb1a61B090c0)
```

## Local development

```bash
cd frontend
npm install
npm run setup:api     # once: Python venv with numpy for the backtest API
npm run dev:api       # terminal 1: backtest API on 127.0.0.1:8787
npm run dev           # terminal 2: app on localhost:3000 (forwards /api/backtest to terminal 1)
```

## The backtest

- **Data**: every swap of mainnet ETH/USDC 0.30% (96k) and 0.05% (1M), 2026-04-05 to 2026-10-03, exported from
  `Uniswap-Ext/lp_study` by `export_backtest.py` into `frontend/api/_data/*.npz`.
- **Engine**: `frontend/api/_engine.py` (numpy only) runs the rules the way `ConditionalOrders.sol` does: conditions,
  keeper delay, remove, keeper reserve, kept or paid-out fees, swap with slippage limit, re-add or follow, repeat,
  close, and the WouldRefire refusal. Fees use lp_study's validated swap replay.
- **Checks**: `cd Uniswap-Ext/lp_study && .venv/bin/python -m pytest tests/test_rules_backtest.py` (23 tests: fees equal
  lp_sim's replay to 1e-9, exits at the swap the contract implies, encoding equal to the frontend's for both token
  orders, repeats, value conserved, fee share never above the whole fee).
- **Newer dates**: rerun `lp_study/fetch.py` for a new window, then `export_backtest.py`, commit, push.
- **Caching**: requests are GETs, answered with a one-year CDN cache header; the history never changes, so a repeated
  backtest costs nothing.
