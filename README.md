# BaseMiner Frontend

A multichain dApp frontend for the BaseMiner game contracts. Single-file, zero build step.

## Features

- **Mine bBall** — click to mine, watch your tool upgrade in real-time
- **Token panel** — transfer, approve, check allowances
- **Badges panel** — claim Common / Rare / Legendary NFTs with eligibility gating
- **Leaderboard** — top-10 miners with live data
- **Admin panel** — pause/unpause, minter management, ownership transfer (two-step)
- **Multichain** — Base Mainnet, Base Sepolia, Celo Mainnet, Ethereum, Polygon, and more
- **Persistent config** — contract addresses saved to localStorage per browser

## Deployment

### GitHub Pages
1. Push `index.html` to a repo.
2. Settings → Pages → Source: `main` branch, `/ (root)`.
3. Visit `https://<user>.github.io/<repo>/`.

### Netlify
1. Drag the folder to [netlify.com/drop](https://app.netlify.com/drop), or connect your repo.
2. `netlify.toml` handles redirects and headers automatically.

### Vercel
1. `vercel --prod` from the folder, or connect your GitHub repo in the Vercel dashboard.
2. `vercel.json` handles rewrites and security headers automatically.

## Usage

1. Open the app and connect MetaMask (or any EIP-1193 wallet).
2. The app auto-loads Base Mainnet addresses once you've deployed and pasted them into `CHAINS`.
3. Select the correct network from the chain badge in the top-right.
4. Start mining!

## Contract Addresses

After running `deploy_baseminer.py`, paste the three addresses from `deployment.json` into
the `contracts` field of the `8453` (Base Mainnet) entry in `CHAINS` inside `index.html`:

| Field       | Contract    |
|-------------|-------------|
| bBall Token | `bBall`     |
| BaseMiner   | `BaseMiner` |
| MinerBadge  | `MinerBadge`|

## Deploy

```bash
# Dry-run (estimate gas, check balance — no transactions sent):
python deploy_baseminer.py --keystore ./UTC-keystore.json --dry-run

# Live deployment:
python deploy_baseminer.py --keystore ./UTC-keystore.json
```

## Security Notes

- All write operations require wallet signature — no private keys are ever handled by the frontend.
- The frontend is fully client-side with no backend.
- Admin functions (pause, minter management, ownership transfer) revert on-chain if called from a non-owner address.
