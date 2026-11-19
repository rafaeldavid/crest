// vault-buy: an agent buys from a seller on Crow and its company's Crest vault pays (Crest design record, section 5).
// The agent's own key is the deal's buyer and signs the agreement; the vault is the payment address and pays the hold
// through Crest's Holdback module, within the grant the principal gave that key. A helper key pays the gas and gains
// nothing: the call carries the agent's signed agreement, and the vault approves only the payment it has just checked.
// Test tokens only: it refuses a mainnet chain.
//
//   node client/vault-buy.ts <quote URL> <scope, as JSON> <the most you pay, base units> [<defaults URL>]
//       asks the seller for a quote with the vault as the payment address, reads the offer from every operator, asks the
//       vault in a dry run whether its limits allow this payment, prints all of it, and stops with exit status 3:
//       nothing is signed or paid. Its last line on stderr is the approve command.
//   node client/vault-buy.ts approve <commitment ID> <the most you pay, base units> [--stop-after-funding]
//       funds exactly the offer the stop showed, if every operator still serves it and the vault's limits allow it, then
//       follows the deal to its outcome and tells the vault the deal has ended. A refusal by a limit names the limit,
//       the grant and the numbers; nothing is sent.
//   node client/vault-buy.ts limits
//       the agent's grant and every grant above it: limits, what is used, state, and the vault's balance.
//   node client/vault-buy.ts resume [<commitment ID>]
//       follows each funded deal to its outcome again, after a restart.
//
// Environment, set by the company: HOLDBACK_ROOT (a Holdback checkout, for its buyer tools), HOLDBACK_OPERATORS,
// HOLDBACK_DEPLOYMENT (a test chain's deployment file, as JSON) or Sepolia's pin, CREST_RPC, CREST_VAULT, CREST_MODULE,
// CREST_KEY_FILE (the agent's key file: privateKey and encryptionSecretKey, kept where the agent cannot read it),
// CREST_STORE (a folder for each purchase's key store), CREST_GAS_KEY (the helper that pays gas), CROW_EXPECT as for
// Holdback's buy-with-signer. Exit status: 0 done, 1 error, 2 usage, 3 stopped for approval, 5 refused by the vault.
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { agentModule, buyerSigner, chains, crestAbi, encode, fundingErrors, verify, viem, type J } from './holdback.ts';

const USAGE = `vault-buy: buy from a seller on Crow, paid from your company's Crest vault within your grant's limits.
  vault-buy <quote URL> <scope, as JSON> <the most you pay, base units> [<defaults URL>]   quote, check, show; stops (exit 3) before paying
  vault-buy approve <commitment ID> <the most you pay, base units> [--stop-after-funding]    fund that offer from the vault, follow it to its outcome
  vault-buy limits                                                                           your grant's limits, what is used, and the vault's balance
  vault-buy resume [<commitment ID>]                                                         follow funded deals again
Example: vault-buy https://seller.example/quote '{"rows": 5}' 2000000`;

const MAX = { u128: (1n << 128n) - 1n, u32: (1n << 32n) - 1n };
const args = process.argv.slice(2);
const stopAfterFunding = args.includes('--stop-after-funding');
const pos = args.filter((a) => a !== '--stop-after-funding');
const say = (x: unknown) => console.error(JSON.stringify(x));
const out = (x: unknown) => console.log(JSON.stringify(x, (_k, v) => (typeof v === 'bigint' ? v.toString() : v)));
class Refused extends Error {}
const env = (k: string): string => { const v = process.env[k]; if (!v) throw new Error(`${k} is not set: your company sets it`); return v; };
const units = (n: bigint, decimals = 6) => { const s = n.toString().padStart(decimals + 1, '0'); const f = s.slice(-decimals).replace(/0+$/, ''); return `${s.slice(0, -decimals)}${f ? `.${f}` : ''}`; };
const limitText = (n: bigint, max: bigint, unit = ' tUSDC') => (n === max ? 'no limit' : `${units(n)}${unit}`);

// An RPC address can carry a provider key in its path: no message shows more of it than its origin.
const RPC_RAW = process.env['CREST_RPC'] ?? '';
const redact = (t: string) => { try { return RPC_RAW ? t.split(RPC_RAW).join(`${new URL(RPC_RAW).origin}/…`) : t; } catch { return t.split(RPC_RAW).join('<the RPC>'); } };
const die = (e: unknown) => { console.error(redact(String((e as Error)?.message ?? e)).replace(/[^\x20-\x7e\n]/g, '?').slice(0, 2000)); process.exit(e instanceof Refused ? 5 : 1); };
process.on('uncaughtException', die);
process.on('unhandledRejection', die);
if (pos[0] === '--help' || pos[0] === '-h') { console.log(USAGE); process.exit(0); }
if (!pos[0]) { console.error(USAGE); process.exit(2); }

const v = await viem();
const { BuyerSigner, printable } = await buyerSigner();
const { Agent } = await agentModule();
const { knownPins } = await verify();
const enc = await encode();
const { MAINNET_CHAIN_IDS } = await chains();
const VAULT = crestAbi('CrestVault'), MODULE = crestAbi('HoldbackModule');
const ERRORS = fundingErrors();

const rpc = env('CREST_RPC');
const publicClient = v.createPublicClient({ transport: v.http(rpc) });
const chainId = await publicClient.getChainId();
// Test chains only, by allow list: a local chain (31337) or Sepolia (11155111). The repository's mainnet list is checked too.
const TEST_CHAINS = [31337, 11155111];
if (MAINNET_CHAIN_IDS.includes(chainId) || !TEST_CHAINS.includes(chainId)) throw new Error(`the RPC answers chain ${chainId}: vault-buy runs only on a local chain (31337) or Sepolia (11155111)`);
const chain = v.defineChain({ id: chainId, name: `chain ${chainId}`, nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [rpc] } } });
const vault = env('CREST_VAULT').toLowerCase();
/**
 * Who the deal's buyer is: one setting. `agent` (today): the agent's key is the buyer and signs the agreement, and the vault
 * is only the payment address. `vault`: the vault itself is the buyer, so its owner can act on a funded deal; Crest's
 * next build, which Holdback's operators must also support (a contract buyer). The buyer is named in two places: the key
 * file each purchase writes (newPurchase: its key signs as the buyer) and the quote, which sends that key's address.
 */
const BUYER = (process.env['CREST_BUYER'] || 'agent') as 'agent' | 'vault';
if (BUYER !== 'agent' && BUYER !== 'vault') throw new Error(`CREST_BUYER is agent or vault, not ${BUYER}`);
if (BUYER === 'vault') { console.error('CREST_BUYER=vault: the vault as the buyer is not built yet (Crest\'s next build). Nothing is signed or paid.'); process.exit(2); }
const module = env('CREST_MODULE').toLowerCase();
const store = env('CREST_STORE');
const keyFile = JSON.parse(readFileSync(env('CREST_KEY_FILE'), 'utf8')) as { privateKey: string; encryptionSecretKey: string };
const agentAccount = v.accounts.privateKeyToAccount(keyFile.privateKey);
const me = agentAccount.address.toLowerCase();
const operators = env('HOLDBACK_OPERATORS').split(',').map((s: string) => s.trim()).filter(Boolean);
const expect = JSON.parse(process.env['CROW_EXPECT'] || '{}');
const read = (address: string, abi: J[], functionName: string, a: unknown[] = []) => publicClient.readContract({ address, abi, functionName, args: a });

/** Each purchase keeps its own key store, a folder holding a copy of the agent's one key, so its records never mix. */
function purchases(): Array<{ dir: string; saved: J }> {
  if (!existsSync(store)) return [];
  return readdirSync(store).filter((d) => d.startsWith('p-')).sort().map((d) => ({ dir: join(store, d), saved: JSON.parse(readFileSync(join(store, d, `${me}.json`), 'utf8')) }));
}
const signerOf = (p: { dir: string; saved: J }) => new BuyerSigner(p.dir, p.saved, { expect, operators });
const reload = (p: { dir: string }) => ({ dir: p.dir, saved: JSON.parse(readFileSync(join(p.dir, `${me}.json`), 'utf8')) });
function newPurchase(): { dir: string; saved: J } {
  mkdirSync(store, { recursive: true, mode: 0o700 });
  const dir = join(store, `p-${Date.now()}-${Math.random().toString(16).slice(2, 6)}`);
  mkdirSync(dir, { mode: 0o700 });
  const saved = { version: 1, address: me, privateKey: keyFile.privateKey, encryptionSecretKey: keyFile.encryptionSecretKey, createdAt: new Date().toISOString(), paymentAddress: vault };
  const file = join(dir, `${me}.json`);
  writeFileSync(file, `${JSON.stringify(saved, null, 2)}\n`, { mode: 0o600 });
  chmodSync(file, 0o600);
  return { dir, saved };
}

/** The counterparty the vault's approved-merchant list holds for these terms: the payout address and the three adjudicators. */
const counterpartyOf = (t: J) => read(module, MODULE, 'counterpartyOf', [t.sellerPayoutAddress, t.adjudication.adjudicator, t.adjudication.fallbackAdjudicator, t.adjudication.appealAdjudicator]) as Promise<string>;

/** The grant path from the agent's grant up to the root of the top vault: every level a payment is checked at. */
async function path(): Promise<Array<{ vault: string; id: bigint; g: J; isAgent: boolean }>> {
  const own = (await read(vault, VAULT, 'grantOf', [me])) as bigint;
  if (own === 0n) throw new Refused(`your key ${me} holds no grant in the vault ${vault}: ask your principal for one`);
  const outp: Array<{ vault: string; id: bigint; g: J; isAgent: boolean }> = [];
  let at = vault, id = own;
  for (let guard = 0; guard < 64; guard++) {
    const g = (await read(at, VAULT, 'getGrant', [id])) as J;
    outp.push({ vault: at, id, g, isAgent: at === vault && id === own });
    if (g.parent !== 0n) { id = g.parent; continue; }
    const parent = ((await read(at, VAULT, 'parent')) as string).toLowerCase();
    if (/^0x0{40}$/.test(parent)) break;
    id = (await read(at, VAULT, 'parentGrant')) as bigint;
    at = parent;
  }
  return outp;
}

/** A grant in plain words: the numbers the refusal sentences quote. */
async function grantWords(p: { vault: string; id: bigint; g: J; isAgent: boolean }) {
  const c = p.g.caps;
  const now = BigInt(Math.floor(Date.now() / 1000));
  const period = BigInt(c.period);
  const window = now / period;
  const inPeriod = BigInt(p.g.windowEnd) > window * period ? BigInt(p.g.inPeriod) : 0n; // a window counts until its end time
  return {
    grant: p.id.toString(), vault: p.vault, yours: p.isAgent, controller: p.g.controller, paused: p.g.paused, closed: p.g.closed,
    perPayment: limitText(BigInt(c.perSpend), MAX.u128),
    perPeriod: limitText(BigInt(c.perPeriod), MAX.u128), periodSec: Number(c.period), usedThisPeriod: `${units(inPeriod)} tUSDC`, nextPeriodStarts: new Date(Number((window + 1n) * period) * 1000).toISOString(),
    lifetime: limitText(BigInt(c.lifetime), MAX.u128), spent: `${units(BigInt(p.g.spent))} tUSDC`,
    openDeals: Number(p.g.open), openLimit: BigInt(c.maxOpen) === MAX.u32 ? 'no limit' : Number(c.maxOpen),
    expires: Number(c.expiresAt) === 0 ? 'never' : new Date(Number(c.expiresAt) * 1000).toISOString(),
    approvedSellers: /^0x0{40}$/i.test(String(c.list)) ? 'any seller' : `the list at ${String(c.list).toLowerCase()}`, mayDelegate: c.mayDelegate,
  };
}

/** A vault refusal as one plain sentence: which limit, at which grant, with the numbers. */
async function explain(name: string, grantId: bigint | undefined, amount: bigint, counterparty: string): Promise<string> {
  const levels = await path().catch(() => []);
  const at = levels.find((l) => l.id === grantId) ?? levels[0];
  const w = at ? await grantWords(at) : undefined;
  const short = (id: bigint) => (id <= 1n ? 'the root grant' : `grant 0x${id.toString(16).slice(0, 8)}…`);
  const whose = !at ? 'a grant' : at.isAgent ? 'your own grant' : `${short(at.id)} above yours${at.vault !== vault ? `, in the parent vault ${at.vault}` : ''}`;
  const tail = 'Nothing was signed or paid. Only your principal, or a grant above yours, can change this.';
  switch (name) {
    case 'OverPerSpend': return `The vault refused: ${units(amount)} tUSDC is above the most one payment may be for ${whose}, ${w?.perPayment}. ${tail}`;
    case 'OverPerPeriod': return `The vault refused: this payment of ${units(amount)} tUSDC would take ${whose} past its limit of ${w?.perPeriod} per ${w?.periodSec} s period (${w?.usedThisPeriod} used in this period). The next period starts at ${w?.nextPeriodStarts}. ${tail}`;
    case 'OverLifetime': return `The vault refused: this payment of ${units(amount)} tUSDC would take ${whose} past its lifetime total of ${w?.lifetime} (${w?.spent} spent). ${tail}`;
    case 'TooManyOpen': return `The vault refused: ${whose} has ${w?.openDeals} open deals, the most it may have at once (${w?.openLimit}). A deal stays open until it ends and anyone tells the vault so; this command does that for your own ended deals before each payment. ${tail}`;
    case 'CounterpartyNotAllowed': return `The vault refused: this seller is not on the approved list of ${whose}. The list names a seller's payout address together with the three adjudicators of the deal; for this offer that entry is ${counterparty}. ${tail}`;
    case 'Paused': return `The vault refused: ${whose} is paused. ${tail}`;
    case 'GrantClosed': return `The vault refused: ${whose} is closed for good. ${tail}`;
    case 'Expired': return `The vault refused: ${whose} expired at ${w?.expires}. ${tail}`;
    case 'ModuleNotEnabled': return `The vault refused: its principal has not enabled Crow's payment module (${module}) on this vault. ${tail}`;
    case 'NoGrant': return `The vault refused: your key holds no grant in this vault. ${tail}`;
    default: return `The funding reverted with ${name}. ${/Balance|Insufficient|exceeds balance/i.test(name) ? `The vault does not hold ${units(amount)} tUSDC that it could pay. ` : ''}${tail}`;
  }
}

/** The revert's name and its grant argument, from the error data, against every error the funding can raise. */
function decodeRevert(e: J): { name: string; grant?: bigint; raw: string } {
  let err = e;
  for (let i = 0; i < 8 && err; i++) {
    const data = err.data?.data ?? err.data ?? err.raw;
    if (typeof data === 'string' && data.startsWith('0x') && data.length >= 10) {
      try {
        const d = v.decodeErrorResult({ abi: ERRORS, data });
        return { name: d.errorName, ...(typeof d.args?.[0] === 'bigint' ? { grant: d.args[0] } : {}), raw: data };
      } catch { return { name: `unknown error ${data.slice(0, 10)}`, raw: data }; }
    }
    if (err.data?.errorName) return { name: err.data.errorName, ...(typeof err.data.args?.[0] === 'bigint' ? { grant: err.data.args[0] } : {}), raw: '' };
    err = err.cause;
  }
  const msg = String(e?.shortMessage ?? e?.message ?? e);
  const m = /reverted with the following reason:\s*(.+)/.exec(msg);
  return { name: m ? m[1]!.trim() : msg.slice(0, 200), raw: '' };
}

/** The module's funding call for these terms: the agent's agreement, the seller's signature and the adjudicator's acceptance. */
async function fundingCall(signer: J, p: { dir: string; saved: J }, id: string, total: bigint) {
  const pin = knownPins().find((x: J) => x.chain && x.domain.chainId === chainId);
  if (!pin) throw new Error(`no pinned deployment for chain ${chainId}: set HOLDBACK_DEPLOYMENT`);
  const agent = new Agent(operators, keyFile.privateKey, new Uint8Array(Buffer.from(keyFile.encryptionSecretKey, 'base64url')), pin.domain, pin.chain);
  const terms = p.saved.checked.terms;
  const nonces = p.saved.funding?.nonces;
  const { slots } = await agent.prepareAgreeAndFund(terms, total, { paymentAddress: vault, ...(nonces ? { nonces } : {}) });
  const mine = slots.filter((s: J) => s.signer === me);
  const agreeSlot = mine.find((s: J) => s.typed?.primaryType === 'Agree');
  if (!agreeSlot || mine.length !== 1) throw new Error(`the operators prepared ${mine.map((s: J) => `${s.slot} (${s.typed?.primaryType})`).join(', ') || 'nothing'} for this key to sign, not one agreement`);
  if (slots.some((s: J) => s.signer === vault && !/^fund/.test(s.slot))) throw new Refused('the operators prepared an operator fee for the vault to pay: the module pays the hold only, so this deal cannot be paid from the vault');
  const signature = await agentAccount.signTypedData(agreeSlot.typed);
  const agree = { nonce: agreeSlot.typed.message.nonce, expiresAt: BigInt(agreeSlot.typed.message.expiresAt), signature };
  // The seller's signature and the adjudicator's acceptance, from the operators' record of the deal. The rules contract
  // checks both signatures again, so an operator that served wrong ones only makes the funding revert.
  const events = (await (await fetch(`${operators[0]}/v1/commitments/${id}/events?limit=200`)).json()) as J;
  const items: J[] = events.items ?? [];
  const sellerSignature = items.find((e) => e.type === 'commitment.offered')?.payload?.sellerSignature;
  const acceptance = items.find((e) => e.type === 'adjudicator.accepted')?.payload?.acceptance;
  if (!sellerSignature || !acceptance) throw new Error(`the operators' record of ${id} has no ${!sellerSignature ? "seller's signature" : "adjudicator's acceptance"} yet`);
  const fundingSignature = `0x${'00'.repeat(65)}`; // the module passes it on; the vault answers the token itself (ERC-1271)
  return { terms, args: [enc.termsView(terms), sellerSignature, enc.acceptanceView(acceptance), agree, { signature: fundingSignature }], signer };
}

const gas = () => v.createWalletClient({ account: v.accounts.privateKeyToAccount(env('CREST_GAS_KEY')), chain, transport: v.http(rpc) });

/** Tells the vault that each of this agent's ended deals has ended, so its open count falls. Anyone may; the helper pays. */
async function closeEnded(except?: string): Promise<Array<{ commitmentId: string; tx: string }>> {
  const done: Array<{ commitmentId: string; tx: string }> = [];
  for (const p of purchases()) {
    const id = p.saved.commitmentId;
    if (!id || id === except || !p.saved.paid || !p.saved.checked) continue;
    const open = (await read(vault, VAULT, 'getOpen', [id])) as J;
    if (open.grant === 0n) continue;
    try {
      await publicClient.simulateContract({ address: module, abi: MODULE, functionName: 'close', args: [enc.termsView(p.saved.checked.terms)], account: gas().account });
    } catch { continue; } // not ended yet
    const tx = await gas().writeContract({ address: module, abi: MODULE, functionName: 'close', args: [enc.termsView(p.saved.checked.terms)] });
    await publicClient.waitForTransactionReceipt({ hash: tx });
    done.push({ commitmentId: id, tx });
  }
  return done;
}

async function untilHeld(id: string, timeoutMs = 90_000): Promise<void> {
  const end = Date.now() + timeoutMs;
  for (;;) {
    const states = await Promise.all(operators.map(async (o: string) => { try { return ((await (await fetch(`${o}/v1/commitments/${id}`)).json()) as J).escrowState; } catch { return null; } }));
    if (states.every((s) => s === 'Held' || s === 'Delivered' || s === 'Released' || s === 'Refunded' || s === 'Settled')) return;
    if (Date.now() > end) throw new Error(`the funding is on chain, but after ${timeoutMs / 1000} s the operators report ${states.join(', ')}`);
    await new Promise((r) => setTimeout(r, 500));
  }
}

async function follow(p: { dir: string; saved: J }, extra: J = {}) {
  const signer = signerOf(p);
  const done = await signer.openDelivery(p.saved.commitmentId, { onReport: say });
  const closed = await closeEnded().catch((e: Error) => [{ error: e.message }]);
  out({ commitmentId: p.saved.commitmentId, buyer: me, paidFrom: vault, paid: signer.paid?.total, outcome: done.outcome, ...(done.settlement ? { settlement: done.settlement } : {}), work: done.work, transactions: done.transactions, ...extra, vaultTold: closed });
}

try {
  if (pos[0] === 'limits') {
    const levels = await path();
    const token = (await read(vault, VAULT, 'token')) as string;
    const balance = (await publicClient.readContract({ address: token, abi: v.erc20Abi, functionName: 'balanceOf', args: [vault] })) as bigint;
    out({ vault, balance: `${units(balance)} tUSDC`, yourKey: me, path: await Promise.all(levels.map(grantWords)), note: 'Every payment is checked at your grant and at every grant above it. Only your principal or a grant above yours can change a limit.' });
  } else if (pos[0] === 'resume') {
    const list = purchases().filter((p) => p.saved.paid && (!pos[1] || p.saved.commitmentId === pos[1].toLowerCase()));
    if (list.length === 0) console.error('No funded deal to follow.');
    for (const p of list) await follow(p);
  } else if (pos[0] === 'approve') {
    const [, idRaw, maxRaw] = pos;
    if (!/^0x[0-9a-fA-F]{64}$/.test(idRaw ?? '') || !/^[0-9]{1,30}$/.test(maxRaw ?? '')) { console.error(`approve takes <commitment ID> <the most you pay, base units>\n${USAGE}`); process.exit(2); }
    const id = idRaw!.toLowerCase();
    let p = purchases().find((x) => x.saved.commitmentId === id);
    if (!p || !p.saved.shown) throw new Refused(`no stop showed ${id} with your key: run vault-buy with the quote URL first; nothing is approved`);
    const signer = signerOf(p);
    const shown = signer.shownOffer;
    const total = BigInt(shown.fees.total.amount);
    if (total > BigInt(maxRaw!)) throw new Refused(`the offer costs ${shown.fees.total.amount} base units, above ${maxRaw}: nothing is signed or paid`);
    if (signer.paid) { await follow(p); process.exit(0); }
    // A run that funded and then stopped before it saved: the operators record the funding, so save it and follow the deal.
    const state = String(((await (await fetch(`${operators[0]}/v1/commitments/${id}`)).json()) as J)?.escrowState ?? '');
    if (p.saved.funding && ['Held', 'Delivered', 'Released', 'Refunded', 'Settled'].includes(state)) { await signer.agreeAndFund(id); await follow(reload(p)); process.exit(0); }
    await signer.checkOffer(id, shown); // every operator still serves exactly this offer, and the adjudicator accepted it
    const closed = await closeEnded(id); // tells the vault about this agent's ended deals; it moves no money
    await signer.fundingFiles(id); // records the funding nonces the operators prepared; the vault signs nothing
    p = reload(p);
    const { terms, args: callArgs } = await fundingCall(signer, p, id, total);
    const hold = BigInt(terms.price.amount) + BigInt(terms.adjudication.fee.amount);
    const counterparty = await counterpartyOf(terms);
    const helper = gas();
    try {
      await publicClient.simulateContract({ address: module, abi: [...MODULE, ...ERRORS], functionName: 'agreeAndFund', args: callArgs, account: helper.account });
    } catch (e) {
      const r = decodeRevert(e);
      const sentence = await explain(r.name, r.grant, hold, counterparty);
      out({ refused: r.name, grant: r.grant?.toString() ?? null, commitmentId: id, amount: hold.toString(), counterparty, said: sentence, sent: false, ...(closed.length ? { vaultTold: closed } : {}) });
      console.error(printable(sentence));
      process.exit(5);
    }
    const tx = await helper.writeContract({ address: module, abi: MODULE, functionName: 'agreeAndFund', args: callArgs, gas: 3_000_000n });
    const receipt = await publicClient.waitForTransactionReceipt({ hash: tx });
    if (receipt.status !== 'success') {
      out({ refused: 'reverted on chain', commitmentId: id, tx, gasUsed: receipt.gasUsed, sent: true });
      console.error(`The funding transaction ${tx} reverted on chain after the dry run passed: nothing was paid.`);
      process.exit(5);
    }
    say({ funded: id, from: vault, hold: hold.toString(), tx, gasUsed: receipt.gasUsed.toString() });
    await untilHeld(id);
    await signerOf(p).agreeAndFund(id); // records the funding the operators now report, so the deal can be followed
    p = reload(p);
    if (stopAfterFunding) { out({ commitmentId: id, funded: true, paidFrom: vault, tx, gasUsed: receipt.gasUsed, follow: `vault-buy resume ${id}` }); process.exit(0); }
    await follow(p, { funding: { tx, gasUsed: receipt.gasUsed } });
  } else {
    const [quoteUrl, scopeRaw, maxRaw, defaults] = pos;
    if (!quoteUrl || !scopeRaw || !/^[0-9]{1,30}$/.test(maxRaw ?? '')) { console.error(USAGE); process.exit(2); }
    const scope = JSON.parse(scopeRaw);
    const p = newPurchase();
    const signer = signerOf(p);
    const quote = await signer.quote(quoteUrl, scope);
    const offer = await signer.readOffer(quote.commitmentId, defaults ? { defaults } : {});
    const terms = (await (await fetch(`${operators[0]}/v1/commitments/${quote.commitmentId}/terms`)).json()) as J;
    const t = terms.terms ?? terms;
    if (String(t.buyerPaymentAddress).toLowerCase() !== vault) throw new Refused(`the offer names ${t.buyerPaymentAddress} as the payment address, not your company's vault ${vault}: nothing is signed or paid`);
    const hold = BigInt(offer.price.amount) + BigInt(offer.fees.adjudication.amount);
    const counterparty = await counterpartyOf(t);
    const own = (await read(vault, VAULT, 'grantOf', [me])) as bigint;
    let vaultCheck: J;
    try {
      await read(vault, VAULT, 'checkPath', [own, hold, counterparty]);
      vaultCheck = { allows: true, note: 'a dry run: your grant and every grant above it allow this payment now, for each limit but the period, lifetime and open-deal counts, which the funding checks' };
    } catch (e) {
      const r = decodeRevert(e);
      vaultCheck = { allows: false, refused: r.name, grant: r.grant?.toString() ?? null, said: await explain(r.name, r.grant, hold, counterparty) };
    }
    const approve = `vault-buy approve ${quote.commitmentId} ${maxRaw}`;
    if (BigInt(offer.fees.total.amount) > BigInt(maxRaw!)) {
      out({ approval: 'over-budget', budget: maxRaw, ...offer, vault: { address: vault, hold: hold.toString(), check: vaultCheck } });
      console.error(printable(`The offer costs ${offer.fees.total.amount} base units, above ${maxRaw}: nothing is signed or paid.`));
      process.exit(1);
    }
    out({ approval: 'needed', budget: maxRaw, ...offer, vault: { address: vault, hold: hold.toString(), check: vaultCheck }, approve });
    console.error(printable(`Stopped before funding: nothing is signed or paid. ${vaultCheck.allows ? 'The vault allows this payment in a dry run.' : vaultCheck.said} To fund exactly this offer from the vault, run:`));
    console.error(approve);
    process.exit(3);
  }
} catch (e) {
  die(e);
}
