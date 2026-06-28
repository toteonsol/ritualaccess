# Ritual Genesis 1000 — deploy a sovereign agent (free)

Be one of the **first 1,000 wallets** to deploy a sovereign agent on Ritual testnet and claim a permanent, numbered Genesis spot. Keyless, no API keys, no cost beyond free testnet RITUAL. This repo is the one-command deploy. Works on a **phone** too.

> ### ▶ Full walkthrough + the access-code video
> Most people think Ritual testnet is invite-only. It is not. The video and the complete, hand-held guide live here:
> **https://deployr.airdropsea.com/ritual**

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/toteonsol/ritualaccess)

> ## ⚠️ Use a brand-new burner wallet — never one with real funds
> You paste this wallet's private key into the deploy tool (encrypted locally, never sent anywhere). Create a fresh wallet just for this, fund it only with free testnet RITUAL, and never send it money from a wallet that holds real assets.

---

## What your computer needs

**No-hassle way (recommended — works on any device, even a phone):** nothing to install. [GitHub Codespaces](https://codespaces.new/toteonsol/ritualaccess) gives you a ready-made Linux terminal in your browser with `git`, `bash`, and the toolchain available. You only need a free GitHub account. This is the smoothest path, especially on Windows.

**Prefer to run it locally? Install Git first:**
- **Mac:** run `xcode-select --install` in Terminal (one time). The deploy script auto-installs the rest (Foundry + uv).
- **Windows:** install [Git for Windows](https://git-scm.com/download/win) — it includes **Git Bash**. Run everything in **Git Bash**, *not* PowerShell (PowerShell has no `git`/`bash` and says "not recognized"). If the toolchain misbehaves, switch to Codespaces.
- **Linux:** install Git (`sudo apt install git`, or your distro's equivalent). The script auto-installs the rest.

You also need a **wallet + a little testnet RITUAL** either way (see below).

## Quick start

**Phone (no PC):** click the **Open in Codespaces** button above, wait for the terminal, then run:

```bash
bash run.sh
```

**Mac / Linux (or Windows "Git Bash"):**

```bash
git clone https://github.com/toteonsol/ritualaccess
cd ritualaccess
bash run.sh
```

That single command deploys your agent contract, funds it, and arms it. It auto-installs what it needs (Foundry + uv).

> **Windows:** run these in **Git Bash**, not PowerShell — see [What your computer needs](#what-your-computer-needs) above. Or skip it entirely with Codespaces.

## Before you run it

1. A **burner wallet** (MetaMask or Rabby) — never one with real funds.
2. **Testnet RITUAL** in it. First get an **access code in the [Ritual Discord](https://discord.gg/ritual-net)** (join, follow the steps in the access channel — the [video](https://deployr.airdropsea.com/ritual) shows every click), then enter that code at the faucet: https://faucet.ritualfoundation.org

When the script asks: press Enter at the name prompt, **paste your burner private key** (hidden, encrypted into a local keystore, never sent anywhere), set a password. That is the only secret step and it stays on your device.

When it prints `Your sovereign agent contract address: 0x…`, you are deployed. Watch it appear in the live [Agent Scanner](https://agents.ritualfoundation.org).

## Claim your Genesis card

Slots are matched from on-chain deploy data on a weekly sync, so give it a day or two. Then in the [Ritual Discord](https://discord.gg/ritual-net):

1. Go to the **!rank** channel and run `/genesis_claim` (it only works in that channel).
2. If you made the cut you will have the **Genesis 1000** role and be asked to describe your agent in one line.
3. Your numbered card generates instantly — share it on X.

## Security

- **Burner wallet only.** The key is imported into an encrypted Foundry keystore (`~/.foundry/keystores`) and never leaves your machine.
- **Keyless:** uses Ritual's own LLM gateway, so there is no external API key to leak or drain.
- Deploying multiple wallets from gifted/shared access codes can muddy your eligibility — use your own.

## Credits

Built on Ritual's official [`ritual-dapp-skills`](https://github.com/ritual-foundation/ritual-dapp-skills) factory flow and [docs](https://docs.ritualfoundation.org). Deploy script based on the MIT-licensed [zunmax/ritual-agent-deployment](https://github.com/zunmax/ritual-agent-deployment) (see `LICENSE`). Guide and packaging by [DEPLOYR](https://deployr.airdropsea.com).

*Airdrops and rewards are never guaranteed. You are positioning, not buying a payout.*
