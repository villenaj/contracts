# XON Vending — Runbook

How to run the full XON-for-USDT vending system end to end: the local test network, the
`XonVendingMachine`/`EthUsdtGateway` contracts, and the standalone `xon-relayer` service that
connects Xode, AssetHub, and Ethereum deposits to XON payouts.

## 1. What this system is

A buyer pays USDT and receives native XON on Xode. USDT can come from three places:

| Source | Mechanism | Trust model |
|---|---|---|
| **Xode itself** | USDT is a `pallet_assets` `TrustBackedAsset` with an ERC20 precompile. Buyer calls `buy()` (approve + buy) or just `usdt.transfer()` directly (relayer settles it). | Fully verified on-chain — the contract checks its own real USDT balance before paying out. A compromised relayer key can misattribute a deposit, never invent one. |
| **AssetHub** | AssetHub now runs `pallet-revive` (governance-enacted ~January 2026), so this works exactly like the Ethereum leg below: a `UsdtGateway` contract deployed on AssetHub itself. | Relayer-trusted / **custodial**, same as Ethereum — see below. |
| **Ethereum** | A real Solidity contract (`EthUsdtGateway.sol` — chain-agnostic, the same contract is deployed to both Ethereum and AssetHub), pulls USDT via `transferFrom` and records the depositor's intended Xode beneficiary address. | Relayer-trusted / **custodial** — USDT sits under the gateway contract's owner key until manually moved. There's no live Snowbridge connection (for the Ethereum leg specifically), so that one is not a trustless bridge; the AssetHub leg has no such bridge dependency but is equally relayer-trusted since there's still no local balance on Xode to verify it against. |

What a compromised relayer key can take through the two custodial legs is capped on-chain by
`XonVendingMachine`'s external limits (`setExternalLimits`, §5.1): at most one day's allowance
before the owner pauses the contract.

All three settle through one contract, `XonVendingMachine` (on Xode), and one relayer process
(`xon-relayer`, a separate repo) that watches all three sources and calls `settlePurchase` /
`settleExternalPurchase` accordingly.

Repos:
- `contracts/` (sibling repo, `github.com/villenaj/contracts`) — `XonVendingMachine.sol`,
  `EthUsdtGateway.sol`, Foundry tests. The scripts in `xode-blockchain/client/` read its build
  output from `../../contracts/out/`, so it must be checked out next to `xode-blockchain/` and
  built with `forge build`.
- `xon-relayer/` (sibling repo) — the standalone relayer service

## 2. Prerequisites

- **Foundry** (`forge`, `cast`, `anvil`) — install via `curl -L https://foundry.paradigm.xyz | bash && foundryup`
- **Node.js** (v20+) and `npm`
- The zombienet binaries already vendored at `xode-blockchain/zombienet/bin2/` (`zombienet-linux-x64`,
  `polkadot`, `polkadot-parachain`, `eth-rpc`) — these are large (~775MB) and deliberately not
  committed to git, so if they're missing on a fresh checkout you'll need to fetch/build them
  separately.
- **~4GB of free RAM** before starting the local network. The relay chain (3 validators) + 2
  parachain collators + `eth-rpc` + `anvil` together are heavy; see the Troubleshooting section if
  things crash or hang.

## 3. Build the contracts

```bash
cd contracts        # the sibling repo, next to xode-blockchain/
forge build
forge test        # 30 tests, should all pass - no network needed
```

## 4. Start the local test network

Only start the pieces you actually need:
- **Xode only** (native USDT path): relay + Xode collator + Xode's `eth-rpc`
- **+ AssetHub path**: also needs the AssetHub collator (already in the same zombienet config) and
  AssetHub's own separate `eth-rpc` instance
- **+ Ethereum path**: also needs `anvil` standing in for Ethereum

The AssetHub parachain entry in `zombienet.toml` uses `chain = "asset-hub-westend-dev"`, not
`asset-hub-rococo-local` — this project's vendored `polkadot-parachain` binary's Rococo AssetHub
preset predates AssetHub's `pallet-revive` rollout and doesn't include it, but its Westend preset
does. The relay chain itself is still `rococo-local` — mixing relay/parachain chain flavors like
this is unusual but works fine for local testing.

```bash
cd xode-blockchain/zombienet
rm -rf data zombienet.log eth-rpc-xode.log eth-rpc-assethub.log anvil.log   # clean slate

# 1. Relay chain + both collators (Xode + AssetHub)
./launch-ubuntu.sh

# Wait until both are producing blocks before continuing:
#   curl -s -d '{"id":1,"jsonrpc":"2.0","method":"chain_getHeader","params":[]}' \
#     -H "Content-Type: application/json" http://127.0.0.1:9977   # Xode, should show number > 0
#   ...same against http://127.0.0.1:9955 for AssetHub

# 2. Both pallet-revive EVM bridges - Xode's and AssetHub's own, separate instance. They're
#    different runtimes with independent contract state even though both run pallet-revive, so
#    one eth-rpc process per chain is required - a single process can't bridge two chains at once
#    (--node-rpc-url takes one value, and the chain a JSON-RPC port serves is implicit in which
#    port you're talking to - there's no "switch chains" parameter in the protocol itself).
./eth-rpc.sh

# 3. Only if testing the Ethereum leg: a local stand-in for Ethereum
./anvil.sh
```

To stop everything: `./process-kill.sh` (kills zombienet, both `eth-rpc` instances, and `anvil`).

Default local endpoints used throughout this doc:

| Thing | Endpoint |
|---|---|
| Xode (Substrate RPC) | `ws://127.0.0.1:9977` |
| Xode (EVM/contracts, via its own eth-rpc) | `http://127.0.0.1:8546` |
| AssetHub (Substrate RPC) | `ws://127.0.0.1:9955` |
| AssetHub (EVM/contracts, via its own eth-rpc) | `http://127.0.0.1:8547` |
| Ethereum stand-in (anvil) | `http://127.0.0.1:8545` |

Note the ports don't follow the "obvious" ordering — `anvil` (Ethereum) ended up on `8545` and
Xode's `eth-rpc` on `8546`, simply because of the order things were wired up locally. Double-check
`eth-rpc.sh`/`anvil.sh` against this table before assuming which port is which on a given checkout.

## 5. Deploy the contracts

There's no single "deploy everything" script checked in — the demo/test scripts under
`xode-blockchain/client/` and `xon-relayer/test/` create fresh throwaway contracts with random dev
keys every run, which is fine for local testing but not what you'd use for a real deployment.
Deployment is really three separate activities, only two of which involve an actual contract:

| | Contract deployed? | Who deploys | What that identity controls afterward |
|---|---|---|---|
| **Xode** | Yes — `XonVendingMachine` | Anyone with XON for gas | Nothing — the deployer's identity isn't stored anywhere and has no ongoing privilege |
| **Ethereum** | Yes — `EthUsdtGateway` | Anyone with ETH for gas | Nothing, same reason |
| **AssetHub** | Yes — the same `EthUsdtGateway.sol` contract, redeployed here (its logic is chain-agnostic) | Anyone with AssetHub's native token for gas | Nothing, same reason |

**The deployer is a disposable, one-time identity.** Whoever submits the `CREATE` transaction isn't
recorded in the contract and gains no ongoing power — only the `owner_` and `relayer_` addresses
you pass into the constructor matter after that. It's fine (and simplest) to deploy from the same
key you'll later use as `owner_`, but it doesn't have to be — a CI pipeline's throwaway key, a
teammate's personal wallet, whatever's convenient. Decide `owner_` and `relayer_` *before*
deploying, since changing them later means either calling `transferOwnership`/`setRelayer`
(possible) or — if you got the `usdtToken` address wrong — redeploying from scratch (`usdt` is
`immutable`).

### 5.1 Xode — `XonVendingMachine`

```solidity
constructor(address usdtToken, address owner_, uint256 initialRate, address relayer_)
```

- **`usdtToken`** — the ERC20 precompile address for the real USDT asset on Xode. For a
  `TrustBackedAsset` with id `N`, this is deterministic: bytes
  `[N as 4-byte BE][12 zero bytes][0x01,0x20][2 zero bytes]`. Don't guess `N` — confirm it against
  the live chain first:
  ```js
  // via polkadot.js against the Xode WS endpoint
  const assetId = 1984; // replace with whatever Xode's governance actually registered USDT as
  const metadata = await api.query.assets.metadata(assetId);
  console.log(metadata.symbol.toHuman(), metadata.decimals.toHuman()); // sanity-check it says "USDT", 6
  ```
  Then compute the address the same way `trustBackedAssetPrecompileAddress()` does in
  `xode-blockchain/client/deployXonVendingMachine.js`.
- **`owner_`** — controls `setRate`, `setRelayer`, `setExternalLimits`, `withdrawXon`,
  `withdrawUsdt`, `setPaused`, `transferOwnership`. Use a multisig or otherwise well-secured key — this address can drain the
  entire XON reserve and the accumulated USDT via `withdrawXon`/`withdrawUsdt`.
- **`initialRate`** — XON paid per 1 whole USDT, in **18-decimal "ether" units** regardless of
  Xode's actual 12-decimal native `Balance` type (see the contract's own doc comment for why —
  `pallet_revive`'s `NativeToEthRatio` rescales it). `ethers.parseEther("5")` = 5 XON/USDT.
- **`relayer_`** — the address `xon-relayer` will sign settlement transactions with. Make this a
  **separate, dedicated hot key**, not `owner_` — it has to live on a server and sign unattended, so
  its blast radius should be limited to what `settlePurchase`/`settleExternalPurchase` can do (which
  is bounded for the native path by the contract's own USDT balance, and for the other two paths
  only by the external limits below - see the custodial-trust note in §1).

**To deploy:** the most direct route, and the one already proven to work in this project, is
Polkadot's Remix (point its Injected Provider / External HTTP Provider at your `eth-rpc` endpoint,
chain ID `3417` for this Xode deployment) — compile with the optimizer **on** (Shanghai's
`EIP-3860` 49KB init-code limit will reject an unoptimized build), then deploy with the three
constructor args above. Alternatively, adapt
`xode-blockchain/client/deployXonVendingMachine.js`'s `ethers.ContractFactory(...).deploy(...)` call
to use real keys read from the environment instead of `ethers.Wallet.createRandom()`.

**After deploying:**
1. Fund the XON reserve — a plain native-value transfer to the contract address (triggers
   `receive()`, no calldata needed).
2. Verify `vending.usdt()` matches the precompile address you computed, and `vending.relayer()`
   matches the key `xon-relayer` will actually run with.
3. Set the external limits, if you run the AssetHub or Ethereum legs. They start at 0, which pays
   nothing for those deposits (they're held in the relayer's ledger until you do):
   ```bash
   # raw USDT units (6 decimals): here 5,000 USDT per deposit, 50,000 per 24h
   cast send $VENDING "setExternalLimits(uint256,uint256)" 5000000000 50000000000 --rpc-url $XODE_ETH_RPC --private-key $OWNER_KEY
   ```
   `maxExternalPerDay` is the most a stolen relayer key can take in a day before you pause the
   contract, so size it to real volume, not "high enough to never matter". Set `xon-relayer`'s
   `MAX_EXTERNAL_DEPOSIT_USDT` / `MAX_EXTERNAL_DAILY_USDT` at or below these - the relayer warns at
   startup if they aren't. Check what's left today with `externalAvailable()`.

### 5.2 Ethereum and AssetHub — `EthUsdtGateway` (one deployment per leg you use)

The same contract is deployed once per chain you want to support — there's nothing Ethereum- or
AssetHub-specific about its logic, only the `usdtToken` address differs per deployment.

```solidity
constructor(address usdtToken, address owner_)
```

- **`usdtToken`** — the real USDT token address on whichever chain you're deploying to:
  - **Ethereum**: e.g. `0xdAC17F958D2ee523a2206206994597C13D831ec7` on mainnet — verify this
    against a trusted source yourself before using it, don't take it on faith from any single
    document. For testing, this is `anvil`'s locally-deployed `MockUSDT` address instead.
  - **AssetHub**: the ERC20 precompile address for USDT's `TrustBackedAsset` id there — computed
    the same deterministic way as the Xode-side `usdtToken` in §5.1 (confirm the asset id and
    decimals against AssetHub's own RPC first, don't assume it's the same id as on Xode).
- **`owner_`** — controls `withdraw` (pulls the entire custodied USDT balance) and `setPaused`.
  Given this key can drain real USDT deposited by buyers, treat it with at least as much care as an
  exchange hot-wallet owner key — a multisig (e.g. Gnosis Safe, or AssetHub's own multisig pallet
  wrapped the same way) is strongly preferable to a single EOA here.

**To deploy:** standard EVM tooling applies unmodified on either chain — Foundry (`forge create`),
Remix against an injected wallet, or `ethers.ContractFactory` from a script. For AssetHub, point
your tooling at its own `eth-rpc` endpoint (§4) rather than Xode's — they're separate runtimes with
separate contract state, even though both run `pallet-revive`.

`Deposited.usdtAmount` is what actually reached the gateway, not what the depositor asked to send,
so if Ethereum USDT's transfer fee is ever switched on, XON is paid only for what arrived. The
gateway also works with tokens whose `transfer`/`transferFrom` return nothing, which Ethereum USDT's
do.

**After deploying:** no reserve to seed on either chain (the gateway only custodies incoming USDT,
it doesn't pay anything out itself) — just record the deployed address(es) for `xon-relayer`'s
`ETH_GATEWAY_ADDRESS` / `ASSETHUB_GATEWAY_ADDRESS`. On Ethereum, make one small real deposit and
check the `Deposited` event before announcing the address.

### 5.3 Post-deployment checklist

- [ ] `vending.usdt()` (Xode) resolves to the correct, verified USDT precompile address
- [ ] `vending.relayer()` matches the key `xon-relayer`'s `RELAYER_PRIVATE_KEY` will use
- [ ] `vending.owner()` is a key/multisig you actually control and trust long-term
- [ ] XON reserve seeded with enough to cover expected near-term volume at `initialRate`
- [ ] (AssetHub/Ethereum legs) `setExternalLimits` called; `maxExternalPerDeposit()` /
      `maxExternalPerDay()` read back as intended, and the relayer's caps are at or below them
- [ ] (Ethereum leg) `EthUsdtGateway.owner()` on Ethereum is similarly secured
- [ ] (AssetHub leg) `EthUsdtGateway.owner()` on AssetHub is similarly secured, and its `usdtToken`
      was verified against AssetHub's own real USDT asset id, not assumed from Xode's

### 5.4 Upgrading an existing deployment

Contracts can't be changed once deployed, so picking up a contract fix means deploying new ones
and moving over. The version with on-chain external limits and the gateway USDT fixes needs:

| Contract | Redeploy? | Why |
|---|---|---|
| `XonVendingMachine` (Xode) | Yes | On-chain external limits. Without them a stolen relayer key can drain the whole XON reserve. |
| `EthUsdtGateway` (Ethereum) | Yes | The old one can't take deposits from real Ethereum USDT at all: USDT's `transferFrom` returns nothing, which the old code reverts on. It also recorded the requested amount, not what arrived. |
| `EthUsdtGateway` (AssetHub) | Optional | AssetHub's USDT precompile returns `bool` and charges no fee, so the old one works. Redeploy to run the same code everywhere. |

Plan for a short pause in payouts, and tell buyers the new addresses before step 5, because
anything still sent to an old address afterwards has to be refunded by hand.

1. **Deploy and set up the new contracts** as in §5.1–§5.3: same `usdtToken`, `owner_`,
   `initialRate` and `relayer_` as before. Seed the new vending contract's reserve, call
   `setExternalLimits`, and leave it unannounced for now.
2. **Clear the relayer's open items on the old contracts.** Release or refund every `held`
   deposit (`settle-held`, `refunds`) and refund every `skipped` one. After the switch,
   `settle-held` and `refunds` only look at the new gateways. Then run `reconcile`. It should
   report no problems.
3. **Stop the relayer** (`systemctl stop xon-relayer`). It finishes any settle in flight first.
4. **Pause the old contracts** with their owner keys: `setPaused(true)` on the old vending contract
   and on each gateway being replaced. From here the old vending contract can't pay anything, so any
   deposit it didn't settle is safe to settle on the new one. A paused old gateway turns new
   deposits away instead of taking USDT nobody watches.
5. **Point the relayer at the new contracts.** In `/etc/xon-relayer.env`:
   - Set `VENDING_ADDRESS`, plus `ETH_GATEWAY_ADDRESS` / `ASSETHUB_GATEWAY_ADDRESS` for each
     redeployed gateway.
   - Set `XODE_START_BLOCK`, `ETHEREUM_START_BLOCK` / `ASSETHUB_START_BLOCK` to each new contract's
     deployment block.
   - Keep `MAX_EXTERNAL_*` at or below the new on-chain limits.

   Move aside (don't delete) the checkpoint of every adapter whose contract changed:
   `xode.json` always, and `ethereum.json` / `assethub.json` for each redeployed gateway. A
   checkpoint belongs to one contract, and the relayer refuses to start on a mismatched one. Keep
   `ledger.jsonl`, because it's the audit trail and the 24h cap window.
6. **Start the relayer** and check its startup log. It should show the new addresses and print
   `On-chain external limits: ...` with no warnings.
7. **Make one small deposit on each leg** and confirm it's paid, then announce the new addresses.
8. **Empty the old contracts** with their owner keys:
   - On the old vending contract, call `withdrawXon(newVending, amount)`, which tops up the new
     reserve, and `withdrawUsdt(treasury, amount)` for USDT it collected.
   - On each old gateway, call `withdraw(treasury, amount)`.

   If USDT keeps arriving at an old address, refund it by hand from these same calls.

If an AssetHub gateway isn't redeployed, leave its checkpoint and start block as they are. Its
adapter carries on where it stopped. Never move an external adapter's checkpoint back to blocks
before the switch: the new vending contract has no record of deposits the old one paid, so
rescanning them would pay them again.

## 6. Configure and run the relayer

```bash
cd xon-relayer
npm install
cp .env.example .env
```

Edit `.env`:
```bash
XODE_ETH_RPC=http://127.0.0.1:8546          # or your real eth-rpc endpoint
VENDING_ADDRESS=0x...                        # from step 5
RELAYER_PRIVATE_KEY=0x...                    # must match XonVendingMachine's on-chain `relayer`

ENABLE_XODE_ADAPTER=true
ENABLE_ASSETHUB_ADAPTER=true                 # false if you don't need this leg
ENABLE_ETHEREUM_ADAPTER=true                 # false if you don't need this leg

# AssetHub leg only - note this is AssetHub's *own* eth-rpc endpoint (port 8547 above), not Xode's:
ASSETHUB_EVM_RPC=http://127.0.0.1:8547
ASSETHUB_GATEWAY_ADDRESS=0x...                # from step 5

# Ethereum leg only:
ETHEREUM_RPC=http://127.0.0.1:8545           # or a real Ethereum RPC endpoint
ETH_GATEWAY_ADDRESS=0x...                     # from step 5
```

```bash
node src/index.js
```

It logs each deposit it notices and each settlement it submits, per adapter (`[xode]`,
`[assethub]`, `[ethereum]` prefixes). Leave it running — see §8 for a real server setup.

**Bootstrapping against a contract that might already have deposits on it:** each adapter only
starts scanning from "now" unless told otherwise. Set `XODE_START_BLOCK` / `ASSETHUB_START_BLOCK` /
`ETHEREUM_START_BLOCK` to the relevant deployment/funding block if you need it to catch up on
history on its very first run (after that, its on-disk checkpoint takes over automatically).

## 7. Testing

```bash
cd xon-relayer
node test/e2e.manual.js          # all three adapters settling one deposit each
node test/poisonPill.manual.js   # a permanently-invalid deposit must not block real ones behind it
node test/multiBuyer.manual.js   # multiple distinct buyers depositing concurrently
```

These need the network from §4 already running (`e2e.manual.js` needs all three legs — Xode's
`eth-rpc`, AssetHub's own separate `eth-rpc`, and `anvil`; the other two only need Xode + its
`eth-rpc`). They deploy fresh throwaway contracts each run, so they're safe to re-run freely, and
they print a clear `SUCCESS`/`FAILURE` line at the end.

## 8. Running on a server

See `xon-relayer/systemd/xon-relayer.service` for an example unit file, and `xon-relayer/README.md`
for the full walkthrough. Key points:
- Secrets (`RELAYER_PRIVATE_KEY`, etc.) go in an `EnvironmentFile`, `chmod 600`, owned by a
  dedicated no-login service user — never inline in the unit file or shell history.
- `Restart=always` — the service is designed to resume safely after a crash (checkpointed progress
  per adapter, idempotent settlement calls).
- Bump `CONFIRMATIONS` above the `0`/`1` used for local testing once real value is at stake.

## 9. Troubleshooting (real issues hit building this)

- **`eth-rpc` rejects `null`/`[]` as a topic wildcard in `eth_getLogs`**, unlike standard Ethereum
  nodes (confirmed directly against it — both are either rejected outright or silently match
  nothing). The adapters work around this by filtering only on `topic0` and matching the rest
  client-side — if you're writing new log-watching code against this bridge, do the same.
- **`eth-rpc` restart needed after `SqlxError: UNIQUE constraint failed`**: its internal
  transaction-hash index can wedge itself (seen under heavy system load). It uses an in-memory DB
  by default, so killing and restarting the process clears it. Its transaction cache is also
  bounded (`--cache-size`, default 256 blocks) — a transaction older than that becomes
  `tx not found` even if it was perfectly valid.
- **Custom Solidity errors won't decode unless the ABI you hand `ethers` declares them.** A
  minimal hand-written ABI with just functions/events will make `interface.parseError()` silently
  return `null` for every custom error — see `xon-relayer/src/abi/XonVendingMachine.json`, which
  lists every `error ...()` from the contract for exactly this reason.
- **Use `ethers.NonceManager`, not a plain `Wallet`, for any signer sending multiple transactions
  in a process.** A plain `Wallet` re-queries the "pending" nonce on every send, which races when
  sending rapidly (several adapters settling around the same moment, or several buyers' deposits in
  one batch) — the loser's transaction silently gets dropped with a `tx.wait()` that then hangs
  forever. `xon-relayer/src/settlement.js` wraps its one shared signer this way for exactly this
  reason.
- **A reverted-but-mined transaction's `tx.wait()` error carries no usable revert data against this
  bridge**, unlike a plain `eth_call`/`estimateGas` failure (which does). `settlement.js` replays
  the exact call via `provider.call()` at the block it was mined in to recover a decodable reason
  when this happens.
- **AssetHub and Ethereum each need their own, separate `eth-rpc` instance.** They're different
  runtimes with independent contract state even though both run `pallet-revive` — one `eth-rpc`
  process per chain, each pointed at that chain's own Substrate RPC (or, for Ethereum, there's no
  such bridge needed at all — it's already natively EVM). Mixing these up (e.g. pointing the
  AssetHub adapter at Xode's `eth-rpc`) will make it watch the wrong contract address's logs
  entirely, with no error — it'll just never see any deposits.
- **Both the Ethereum and AssetHub adapters are the same code** (`evmGatewayAdapter.js`), just
  invoked with different chain config — `ethereumAdapter.js`/`assetHubAdapter.js` are thin wrappers.
  If you need to debug one, the logic to read is in the shared file, not the wrapper.
- **Running the full stack (3 relay validators + 2 collators + `eth-rpc` + `anvil`) is genuinely
  memory-heavy.** On a constrained machine, expect occasional OOM kills of the whole stack, or
  transactions timing out/reverting under swap pressure rather than for a real logic reason — check
  `free -h` before concluding a test failure is a real bug.
- **Not every AssetHub chain-spec preset embedded in a given `polkadot-parachain` build has
  `pallet-revive`, even on the same binary.** Confirmed directly: this project's vendored binary's
  `asset-hub-rococo-local` preset predates the rollout and has no `revive` pallet at all
  (`api.query.revive` is `undefined` against it), while its `asset-hub-westend-dev` preset does —
  hence `zombienet.toml` using the Westend preset for AssetHub specifically. If you ever swap in a
  different/newer binary, re-check this rather than assuming — query
  `api.runtimeMetadata.asLatest.pallets` against the running chain for a pallet named `revive`.
