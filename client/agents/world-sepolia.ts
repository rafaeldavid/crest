// The Sepolia world T-560's stage 2 runs in: Crow's live operators and live test seller, Holdback's deployed contracts
// (taken from the Holdback checkout's own deployment record), and Crest's deployment (taken from this checkout's
// record). Test tokens only. The principal and the helper that pays the vault's gas are long-lived test keys whose
// Sepolia ETH comes from the coordinator; the vault's tUSDC comes from the operators' faucet.
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { holdbackRoot, viem, type J } from '../holdback.ts';
import type { LocalWorld } from './world.ts';

export const SEPOLIA = 11155111;
/** Holdback's own public Sepolia endpoints (packages/settlement/evm/live.ts, SEPOLIA_PUBLIC_RPCS): no key in them. */
const PUBLIC_RPC = 'https://ethereum-sepolia-rpc.publicnode.com';

export async function startSepolia(o: { keys: string; crestRecord: string; log?: (l: string) => void }): Promise<LocalWorld & { principalKey: string; gasKey: string }> {
  const say = o.log ?? (() => {});
  const v = await viem();
  const root = holdbackRoot();
  const deployment = JSON.parse(readFileSync(join(root, 'contracts', 'deployments', 'sepolia.json'), 'utf8')) as J;
  if (!existsSync(o.crestRecord)) throw new Error(`no Crest deployment record at ${o.crestRecord}: deploy Crest to Sepolia first`);
  const crest = JSON.parse(readFileSync(o.crestRecord, 'utf8')) as J;
  const keys = JSON.parse(readFileSync(o.keys, 'utf8')) as { principal: string; gas: string };
  const rpc = process.env['CREST_SEPOLIA_RPC'] || PUBLIC_RPC;
  const chain = v.defineChain({ id: SEPOLIA, name: 'Sepolia', nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [rpc] } } });
  const publicClient = v.createPublicClient({ chain, transport: v.http(rpc), cacheTime: 0 });
  const chainId = await publicClient.getChainId();
  if (chainId !== SEPOLIA) throw new Error(`the RPC answers chain ${chainId}, not Sepolia: nothing is sent`);
  if (Number(deployment.chainId) !== SEPOLIA || Number(crest.chainId) !== SEPOLIA) throw new Error('a deployment record names another chain than Sepolia');
  if (String(crest.rules).toLowerCase() !== String(deployment.rules).toLowerCase()) throw new Error(`Crest's module names the rules contract ${crest.rules}, not Holdback's current ${deployment.rules}`);
  const operators: [string, string] = ['https://api.crow.direct', 'https://api2.crow.direct'];
  const discovery = (await (await fetch(`${operators[0]}/.well-known/holdback.json`)).json()) as J;
  if (String(discovery?.domain?.verifyingContract).toLowerCase() !== String(deployment.rules).toLowerCase()) throw new Error('the operators serve another rules contract than the deployment record names');
  const token = String(deployment.token.address).toLowerCase();
  const bal = (a: string): Promise<bigint> => publicClient.readContract({ address: token, abi: v.erc20Abi, functionName: 'balanceOf', args: [a] });
  const principal = v.accounts.privateKeyToAccount(keys.principal).address;
  const gas = v.accounts.privateKeyToAccount(keys.gas).address;
  for (const [who, a] of [['principal', principal], ['gas helper', gas]] as const) {
    const eth = await publicClient.getBalance({ address: a });
    say(`${who} ${a}: ${v.formatEther(eth)} Sepolia ETH`);
    if (eth === 0n) throw new Error(`the ${who} ${a} holds no Sepolia ETH: ask the coordinator for some`);
  }
  const send = async (key: string, to: string, abi: J[], fn: string, args: unknown[]) => {
    const w = v.createWalletClient({ account: v.accounts.privateKeyToAccount(key), chain, transport: v.http(rpc) });
    const hash = await w.writeContract({ address: to, abi, functionName: fn, args, gas: 3_000_000n });
    const r = await publicClient.waitForTransactionReceipt({ hash, timeout: 180_000 });
    if (r.status !== 'success') throw new Error(`${fn} on ${to} reverted (${hash})`);
    return r;
  };
  const base = 'https://crow.direct/agents/test-seller';
  say(`Sepolia: rules ${deployment.rules}, Crest factory ${crest.factory}, module ${crest.holdbackModule}, list ${crest.allowList}.`);
  return {
    root, rpc, chainId: SEPOLIA, operators, deployment, deploymentJson: JSON.stringify(deployment), token,
    rules: String(deployment.rules).toLowerCase(), factory: String(crest.factory).toLowerCase(), module: String(crest.holdbackModule).toLowerCase(), allowList: String(crest.allowList).toLowerCase(),
    // The live seller cannot be held: it delivers within seconds of each funding.
    seller: { base, quote: `${base}/quote`, defaults: `${base}/defaults`, address: '', hold: () => {} },
    // ETH comes from the coordinator, not from this runner.
    fundEth: async () => {},
    // The faucet mints to a payment address it is named with; the mandate goes to a throwaway address.
    mint: async (a, amount) => {
      const before = await bal(a);
      const res = await fetch(`${operators[0]}/v1/faucet`, { method: 'POST', headers: { 'content-type': 'application/json', 'idempotency-key': crypto.randomUUID() }, body: JSON.stringify({ address: v.accounts.privateKeyToAccount(v.accounts.generatePrivateKey()).address.toLowerCase(), amount: amount.toString(), paymentAddress: a }) });
      if (!res.ok) throw new Error(`the faucet refused: ${res.status} ${(await res.text()).slice(0, 300)}`);
      for (let i = 0; i < 120 && (await bal(a)) < before + amount; i++) await new Promise((r) => setTimeout(r, 2000));
      if ((await bal(a)) < before + amount) throw new Error(`the faucet's tokens did not reach ${a} within 240 s`);
    },
    send, read: (address, abi, fn, args = []) => publicClient.readContract({ address, abi, functionName: fn, args }),
    balance: bal,
    now: async () => Number((await publicClient.getBlock()).timestamp),
    errors: [],
    close: async () => {},
    principalKey: keys.principal, gasKey: keys.gas,
  };
}
