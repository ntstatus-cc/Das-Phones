# phone-miner

One-command cpuminer-opt setup for Android phones in **Termux** (no proot/Ubuntu needed).
Builds the newest [tpfuemp/cpuminer-opt](https://github.com/tpfuemp/cpuminer-opt) from source on the phone,
installs a `miner` command, and starts mining on boot.

## Phone prep (once)
1. Install **Termux** and **Termux:Boot** from F-Droid (not the Play Store versions). Open Termux:Boot once.
2. In Android settings, set Termux battery usage to **Unrestricted**.

## Install
Replace `YOU/REPO` with this repo, then paste into Termux:

**One coin, settings on the phone**
```
curl -fsSL https://raw.githubusercontent.com/YOU/REPO/main/install.sh -o install.sh && bash install.sh yespoweradvc stratum+tcp://POOL:PORT YOUR_WALLET x 8
```
(arguments: algo, pool, wallet, password, threads)

**Whole fleet follows `fleet.conf` in this repo**
```
curl -fsSL https://raw.githubusercontent.com/YOU/REPO/main/install.sh -o install.sh && bash install.sh --remote https://raw.githubusercontent.com/YOU/REPO/main/fleet.conf
```
Then give each phone a name: `miner set WORKER moto1`

The first build takes 5–20 minutes.

## Everyday commands
| Command | What it does |
|---|---|
| `miner log` | watch the miner (Ctrl+A then D leaves it running) |
| `miner status` | running or not, active coin, exact command |
| `miner add ytn yespowerr16 stratum+tcp://POOL:PORT WALLET` | save another coin |
| `miner use ytn` | switch coins |
| `miner set THREADS 6` | per-phone thread count |
| `miner set AFFINITY 0xf0` | pin to the big cores |
| `miner update` | rebuild from the newest cpuminer-opt source |
| `miner stop` / `miner start` | stop / start |
| `miner algos` | list supported algorithms |

To pin a known-good source version: `SRC_REF=<commit> miner update`.
