// End-to-end check of XonVendingMachine.settleExternalSwap on a Chopsticks fork of Xode mainnet
// running spec 17 (the XCM AssetExchanger from xode-blockchain's dex-swap branch). It deploys the
// forge-built contract, funds USDT inventory, swaps through the real XON/USDT pool via the XCM
// precompile, and checks refusals (minimum not met, swaps paused in TxPause).
//
// From the contracts repo root, with xode-blockchain checked out next to it and its runtime built
// (`cargo build --release -p xode-runtime`):
//   forge build
//   (cd test/fork && npm install)
//   npx --prefix test/fork chopsticks --config=test/fork/xode-spec17.yml      # in one terminal
//   node test/fork/settleExternalSwap.e2e.mjs                                   # in another
// Restart Chopsticks for each run: it funds //Alice with exactly enough USDT for one run.
import { ApiPromise, WsProvider } from '@polkadot/api';
import { ethers } from 'ethers';
import { readFileSync } from 'node:fs';

const ARTIFACT = process.env.VENDING_ARTIFACT ?? new URL('../../out/XonVendingMachine.sol/XonVendingMachine.json', import.meta.url);
const ALICE = '15oF4uVJwmo4TdGW7VfQxNLavjCXviqxT9S1MgbjMNHr6Sp5';
const USDT_PRECOMPILE = '0x000007c0000000000000000000000000' + '01200000'; // asset 1984, prefix 0x0120
const USDT_DEX = { parents: 0, interior: { X2: [{ PalletInstance: 50 }, { GeneralIndex: 1984 }] } };
const XON_DEX = { parents: 1, interior: 'Here' };
const RATIO = 1_000_000n; // NativeToEthRatio
const WEIGHT = { refTime: 50_000_000_000n, proofSize: 2_000_000n };
const DEPOSIT_LIMIT = 1_000_000_000_000_000n;

const api = await ApiPromise.create({ provider: new WsProvider('ws://127.0.0.1:8001'), noInitWarn: true });
const artifact = JSON.parse(readFileSync(ARTIFACT, 'utf8'));
const vendingIface = new ethers.Interface(artifact.abi);
const erc20 = new ethers.Interface(['function approve(address,uint256) returns (bool)', 'function balanceOf(address) view returns (uint256)']);
const signer = { signPayload: async () => ({ id: 1, signature: '0x01deadbeef' + 'cd'.repeat(60) }) };
const fmt = (v, d) => ethers.formatUnits(v, d);
let failures = 0;
const check = (ok, label) => { console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}`); if (!ok) failures++; };

async function submit(tx, label) {
  const events = await new Promise((resolve, reject) => tx.signAndSend(ALICE, { signer }, (r) => {
    if (r.status.isInBlock) resolve(r.events);
  }).catch(reject));
  const failed = events.find(({ event }) => api.events.system.ExtrinsicFailed.is(event));
  if (failed) {
    const err = failed.event.data[0];
    const msg = err.isModule ? (({ section, name }) => `${section}.${name}`)(api.registry.findMetaError(err.asModule)) : err.toString();
    return { ok: false, error: msg, events };
  }
  return { ok: true, events };
}

// Dry-runs a contract call from Alice; returns { reverted, data, decoded error if any }.
async function dryRun(dest, data) {
  // Same limits as the real transaction: with `null` limits, nested asset transfers fail in dry-runs.
  const r = (await api.call.reviveApi.call(ALICE, dest, 0, WEIGHT, DEPOSIT_LIMIT, data)).toJSON();
  const res = r.result;
  if (res.err) return { failed: true, error: JSON.stringify(res.err) };
  const reverted = (res.ok.flags.bits ?? res.ok.flags) & 1;
  let reason = null;
  if (reverted) {
    try { reason = vendingIface.parseError(res.ok.data)?.name; } catch { /* not a vending error */ }
    reason ??= res.ok.data;
  }
  return { reverted: !!reverted, data: res.ok.data, reason };
}

async function read(dest, iface, fn, args = []) {
  const r = await dryRun(dest, iface.encodeFunctionData(fn, args));
  if (r.failed || r.reverted) throw new Error(`${fn} read failed: ${r.error ?? r.reason}`);
  return iface.decodeFunctionResult(fn, r.data)[0];
}

async function contractCall(dest, iface, fn, args, label) {
  const data = iface.encodeFunctionData(fn, args);
  const dry = await dryRun(dest, data);
  if (dry.failed || dry.reverted) return { ok: false, error: dry.error ?? dry.reason };
  const r = await submit(api.tx.revive.call(dest, 0, WEIGHT, DEPOSIT_LIMIT, data), label);
  return r;
}

const reserves = async () => (await api.call.assetConversionApi.getReserves(XON_DEX, USDT_DEX)).unwrap().map((x) => x.toBigInt());

// --- 1. Alice gets an EVM address, deploys the vending contract -------------------------------
console.log('spec', api.runtimeVersion.specVersion.toNumber());
const mapped = await submit(api.tx.revive.mapAccount(), 'mapAccount'); // AccountAlreadyMapped is fine
console.log('mapAccount:', mapped.ok ? 'ok' : mapped.error);
const alice = (await api.call.reviveApi.address(ALICE)).toHex();
console.log('Alice EVM address', alice);

// EVM constructor args go after the init code, as on Ethereum (`data` must be empty).
const ctorArgs = vendingIface.encodeDeploy([USDT_PRECOMPILE, alice, ethers.parseEther('5'), alice]);
const deploy = await submit(api.tx.revive.instantiateWithCode(0, WEIGHT, DEPOSIT_LIMIT, ethers.concat([artifact.bytecode.object, ctorArgs]), '0x', null), 'deploy');
const inst = deploy.events.find(({ event }) => event.section === 'revive' && event.method === 'Instantiated');
if (!deploy.ok || !inst) throw new Error(`deploy failed: ${deploy.error}`);
const vending = inst.event.data.contract.toHex();
console.log('XonVendingMachine at', vending);
check((await read(vending, vendingIface, 'owner')).toLowerCase() === alice.toLowerCase(), 'constructor ran: owner is Alice');

const vendingAccount = (await api.call.reviveApi.accountId(vending)).toHex();
check(vendingAccount === vending.toLowerCase() + 'ee'.repeat(12), `contract's AccountId32 is address ++ 0xEE*12 (${vendingAccount})`);

// --- 2. Inventory and limits ----------------------------------------------------------------
for (const [dest, iface, fn, args] of [
  [USDT_PRECOMPILE, erc20, 'approve', [vending, 50_000_000n]],
  [vending, vendingIface, 'fundUsdtInventory', [50_000_000n]],
  [vending, vendingIface, 'setExternalLimits', [100_000_000n, 1_000_000_000n]],
]) {
  const r = await contractCall(dest, iface, fn, args, fn);
  check(r.ok, `${fn}${r.ok ? '' : ` (${r.error})`}`);
}
check((await read(vending, vendingIface, 'accountedUsdt')) === 50_000_000n, 'inventory: accountedUsdt = 50 USDT');

// --- 3. The swap ----------------------------------------------------------------------------
const buyer = ethers.Wallet.createRandom().address;
const [xonBefore, usdtBefore] = await reserves();
const quotePlanck = (await api.call.assetConversionApi.quotePriceExactTokensForTokens(USDT_DEX, XON_DEX, 2_000_000, true)).unwrap().toBigInt();
const minXonOut = (quotePlanck * RATIO * 99n) / 100n; // 1% slippage, in 18-decimal units
console.log(`pool ${fmt(xonBefore, 12)} XON / ${fmt(usdtBefore, 6)} USDT; quote for 2 USDT: ${fmt(quotePlanck, 12)} XON; min ${fmt(minXonOut, 18)}`);

// Cross-chain payouts need a quorum of attesters' votes first; here the one relayer is the only
// attester (threshold 1), so its own vote is enough.
const vote = async (args) => {
  const v = await contractCall(vending, vendingIface, 'attestExternalSwap', args, 'attest');
  check(v.ok, `attester voted for ${args[4].slice(0, 10)}…${v.ok ? '' : ` (${v.error})`}`);
};

const deposit1 = ethers.id('ethereum-deposit-1');
await vote([buyer, 2_000_000n, minXonOut, 'ethereum', deposit1]);
const swap = await contractCall(vending, vendingIface, 'settleExternalSwap', [buyer, 2_000_000n, minXonOut, 'ethereum', deposit1], 'settleExternalSwap');
check(swap.ok, `settleExternalSwap${swap.ok ? '' : ` (${swap.error})`}`);
if (swap.ok) {
  const swapEvent = swap.events.find(({ event }) => event.section === 'assetConversion' && event.method === 'SwapCreditExecuted');
  check(!!swapEvent, 'the real pool executed it (assetConversion.SwapCreditExecuted)');
  const buyerWei = (await api.call.reviveApi.balance(buyer)).toBigInt();
  console.log(`buyer ${buyer} now has ${fmt(buyerWei, 18)} XON`);
  check(buyerWei === quotePlanck * RATIO, 'buyer received exactly the quoted swap output');
  const [xonAfter, usdtAfter] = await reserves();
  check(usdtAfter - usdtBefore === 2_000_000n && xonBefore - xonAfter === quotePlanck, 'pool moved by +2 USDT / -quoted XON');
  check((await read(vending, vendingIface, 'accountedUsdt')) === 48_000_000n, 'inventory: accountedUsdt = 48 USDT');
  check((await read(USDT_PRECOMPILE, erc20, 'balanceOf', [vending])) === 48_000_000n, "contract's real USDT balance = 48");
  check((await api.call.reviveApi.balance(vending)).toBigInt() === 0n, 'no XON left behind in the contract');
  check(await read(vending, vendingIface, 'externalSettledDeposits', [deposit1]), 'deposit marked settled');
  const again = await contractCall(vending, vendingIface, 'settleExternalSwap', [buyer, 2_000_000n, minXonOut, 'ethereum', deposit1], 'replay');
  check(!again.ok && /AlreadyExternallySettled/.test(again.error), `replaying the deposit is refused (${again.error})`);
}

// --- 4. A minimum the pool can't meet -------------------------------------------------------
const deposit2 = ethers.id('ethereum-deposit-2');
await vote([buyer, 2_000_000n, ethers.parseEther('1000'), 'ethereum', deposit2]);
const greedy = await contractCall(vending, vendingIface, 'settleExternalSwap', [buyer, 2_000_000n, ethers.parseEther('1000'), 'ethereum', deposit2], 'greedy');
// The XCM precompile reverts with the same generic message for every XCM failure, so the reason
// (minimum not met, swaps paused, pool pending) has to be worked out off-chain.
check(!greedy.ok, `minimum above what the pool gives is refused (${greedy.error})`);
check(!(await read(vending, vendingIface, 'externalSettledDeposits', [deposit2])), '...and the deposit is not marked settled');
check((await read(vending, vendingIface, 'accountedUsdt')) === 48_000_000n, '...and no inventory was spent');

// --- 5. Governance pause on DEX swaps also stops the contract path ---------------------------
const name = (s) => api.createType('Bytes', s);
const key = api.query.txPause.pausedCalls.key([name('AssetConversion'), name('swap_exact_tokens_for_tokens')]);
await api.rpc('dev_setStorage', [[key, '0x00']]);
const deposit3 = ethers.id('ethereum-deposit-3');
await vote([buyer, 2_000_000n, 1n, 'ethereum', deposit3]);
const paused = await contractCall(vending, vendingIface, 'settleExternalSwap', [buyer, 2_000_000n, 1n, 'ethereum', deposit3], 'paused');
check(!paused.ok, `with swaps paused in TxPause, the contract can't swap either (${paused.error})`);
await api.rpc('dev_setStorage', [[key, null]]);

console.log(failures === 0 ? '\nALL CHECKS PASSED' : `\n${failures} CHECK(S) FAILED`);
await api.disconnect();
process.exit(failures === 0 ? 0 : 1);
