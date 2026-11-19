// The local world the agent runs buy in (T-560, stage 1): no deploy anywhere, test tokens only.
//   - anvil, with Holdback's own contracts as Holdback's tests deploy them (EvmWorld: the rules contract, the escrow,
//     the collector and the test token tUSDC);
//   - Crow's operators, the code the live nodes run (apps/demo-cloud's PublicWorld over a LiveChain), served as two
//     nodes on two origins, with no operator fee (the pilots' fee is 0, which the module assumes);
//   - Crow's own test seller (apps/test-agents), selling its sample product by quote, worked as its alarm works it;
//   - Crest's factory and Holdback module, deployed from this checkout's build.
// Everything listens on 127.0.0.1. Nothing reaches a public network.
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { readFileSync } from 'node:fs';
import { holdbackRoot, viem, type J } from '../holdback.ts';

const load = (p: string): Promise<J> => import(pathToFileURL(p).href);
/** anvil's public test mnemonic: its accounts guard nothing of value, on a local chain only. */
const ANVIL_MNEMONIC = ['test', 'test', 'test', 'test', 'test', 'test', 'test', 'test', 'test', 'test', 'test', 'junk'].join(' ');
const devKey = async (index: number): Promise<string> => { const v = await viem(); return v.toHex(v.accounts.mnemonicToAccount(ANVIL_MNEMONIC, { addressIndex: index }).getHdKey().privateKey); };
/** The operators' relayer, and the helper that pays the vault's gas: anvil's second and third accounts. */
export const RELAYER = await devKey(1);
export const GAS_HELPER = await devKey(2);
const ETH = '0x56bc75e2d63100000'; // 100 ETH, test value on anvil

export interface LocalWorld {
  root: string;
  rpc: string;
  chainId: number;
  operators: [string, string];
  deployment: J;
  deploymentJson: string;
  token: string;
  rules: string;
  factory: string;
  module: string;
  /** Crest's default approved-seller list (since Crest PR 9). */
  allowList: string;
  /** Sepolia only: the long-lived principal and gas-helper keys; a local world makes its own. */
  principalKey?: string;
  gasKey?: string;
  seller: { base: string; quote: string; defaults: string; address: string; hold(on: boolean): void };
  /** Test ETH for an address, on anvil only. */
  fundEth(address: string): Promise<void>;
  /** Test tokens minted to an address. */
  mint(address: string, amount: bigint): Promise<void>;
  send(key: string, to: string, abi: J[], fn: string, args: unknown[]): Promise<J>;
  read(address: string, abi: J[], fn: string, args?: unknown[]): Promise<J>;
  balance(address: string): Promise<bigint>;
  now(): Promise<number>;
  errors: string[];
  close(): Promise<void>;
}

const crestArtifact = (name: string): { abi: J[]; bytecode: { object: string } } => JSON.parse(readFileSync(new URL(`../../out/${name}.sol/${name}.json`, import.meta.url), 'utf8'));

export async function startWorld(o: { log?: (l: string) => void; sellerLog?: (l: string) => void } = {}): Promise<LocalWorld> {
  const root = holdbackRoot();
  const say = o.log ?? (() => {});
  const v = await viem();
  const { EvmWorld, LiveChain } = await load(join(root, 'packages/settlement/dist/evm/index.js'));
  const { PublicWorld, MemoryStorage } = await load(join(root, 'apps/demo-cloud/dist/index.js'));
  const { serveTwoOrigins } = await load(join(root, 'examples/two-origins.ts'));
  const { TestSeller } = await load(join(root, 'apps/test-agents/src/seller.ts'));
  const { pinOf } = await load(join(root, 'examples/verify.ts'));
  const { MAINNET_CHAIN_IDS } = await load(join(root, 'packages/core/dist/chains.js'));
  const closers: Array<() => Promise<void>> = [];
  const errors: string[] = [];
  try {
    say('Starting anvil with Holdback\'s contracts.');
    const anvil = await EvmWorld.start(`${root}/`, { blockTimeSec: 1, token: 'test-usdc' });
    closers.push(() => anvil.stop());
    if (MAINNET_CHAIN_IDS.includes(anvil.chainId)) throw new Error('a mainnet chain ID: refused');
    const d = anvil.deployment;
    const deployment = {
      chainId: anvil.chainId,
      fromBlock: Number(d.fromBlock),
      token: { address: d.token, name: anvil.tokenDomain.name, version: anvil.tokenDomain.version, symbol: 'tUSDC', decimals: 6 },
      escrow: d.escrow, erc3009Collector: d.erc3009Collector, multicall: d.multicall, rules: d.rules, beacon: d.beacon,
      expiryMarginSec: Number(anvil.expiryMargin),
    };
    const chain = new LiveChain({ deployment, rpcUrls: [anvil.rpcUrl], relayerKey: RELAYER, pollMs: 200, rebroadcastMs: 10_000, mintBatchMs: 200 });
    const publicClient = v.createPublicClient({ chain: v.defineChain({ id: anvil.chainId, name: 'anvil', nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [anvil.rpcUrl] } } }), transport: v.http(anvil.rpcUrl), cacheTime: 0 });
    const viemChain = publicClient.chain;
    const fundEth = async (a: string) => { await anvil.rpc('anvil_setBalance', [a, ETH]); };
    for (const l of chain.lanes) await fundEth(l.address);
    await fundEth(v.accounts.privateKeyToAccount(GAS_HELPER).address);

    say('Opening the operators.');
    const world = await PublicWorld.open({ storage: new MemoryStorage(), env: {}, live: { chain, beacon: 'sim' }, faucetPerClient: 100_000, rateLimit: { writes: 100_000, reads: 1_000_000, windowMs: 60_000 }, fundedDealsPerClientPerDay: 100_000, onError: (e: Error) => errors.push(e.message) });
    const two = await serveTwoOrigins(world, { tickMs: 200 });
    closers.push(() => two.close());
    for (const end = Date.now() + 120_000; !world.ready() && Date.now() < end; ) await new Promise((r) => setTimeout(r, 250));
    if (!world.ready()) throw new Error(`the operators were not ready after 120 s: ${errors.slice(-3).join('; ')}`);
    const operators = two.urls as [string, string];

    say('Starting Crow\'s test seller.');
    const pin = pinOf(deployment);
    let held = false;
    let seller: J;
    const server: Server = createServer(async (req, res) => {
      const chunks: Buffer[] = [];
      for await (const c of req) chunks.push(c as Buffer);
      const body = ['GET', 'HEAD'].includes(req.method ?? 'GET') ? undefined : Buffer.concat(chunks);
      const r = await seller.fetch(new Request(`http://${req.headers.host}${req.url}`, { method: req.method ?? 'GET', headers: req.headers as Record<string, string>, ...(body ? { body } : {}) }), req.socket.remoteAddress ?? 'unknown');
      res.writeHead(r.status, Object.fromEntries(r.headers));
      res.end(Buffer.from(await r.arrayBuffer()));
    });
    await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
    const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}/agents/test-seller`;
    const seed = `0x${Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('hex')}`;
    seller = new TestSeller({ storage: new MemoryStorage(), operators: [...operators], seed, pin, base, log: o.sellerLog ?? (() => {}), quoteLimits: { perHour: 10_000, perDay: 100_000, waiting: 50, inLine: 50 }, limits: { open: 100, perHour: 10_000, perDay: 100_000, perClientPerHour: 10_000, perClientPerDay: 100_000 } });
    let running = true;
    const loop = (async () => {
      while (running) {
        if (!held) await seller.work().catch((e: Error) => errors.push(`seller: ${e.message}`));
        await new Promise((r) => setTimeout(r, 200));
      }
    })();
    closers.push(async () => { running = false; await loop; server.closeAllConnections(); await new Promise<void>((r) => server.close(() => r())); });

    say('Deploying Crest\'s factory and Holdback module.');
    const deployer = v.createWalletClient({ account: v.accounts.privateKeyToAccount(GAS_HELPER), chain: viemChain, transport: v.http(anvil.rpcUrl) });
    const deploy = async (name: string, args: unknown[]) => {
      const a = crestArtifact(name);
      const hash = await deployer.deployContract({ abi: a.abi, bytecode: a.bytecode.object, args });
      const r = await publicClient.waitForTransactionReceipt({ hash });
      if (r.status !== 'success') throw new Error(`${name} did not deploy`);
      return { address: (r.contractAddress as string).toLowerCase(), gas: r.gasUsed as bigint };
    };
    // Since Crest PR 8 the factory takes a fee rate and a sweeper: no fee here (rate 0, no sweeper). An older build takes none.
    const factoryInputs = (crestArtifact('CrestFactory').abi.find((x: J) => x.type === 'constructor')?.inputs ?? []).length;
    const factory = await deploy('CrestFactory', factoryInputs === 2 ? [0, '0x0000000000000000000000000000000000000000'] : []);
    const module = await deploy('HoldbackModule', [d.rules]);
    const allowList = await deploy('CrestAllowList', []);
    say(`Crest: factory ${factory.address} (${factory.gas} gas), module ${module.address} (${module.gas} gas).`);

    const send = async (key: string, to: string, abi: J[], fn: string, args: unknown[]) => {
      const w = v.createWalletClient({ account: v.accounts.privateKeyToAccount(key), chain: viemChain, transport: v.http(anvil.rpcUrl) });
      const hash = await w.writeContract({ address: to, abi, functionName: fn, args, gas: 5_000_000n });
      const r = await publicClient.waitForTransactionReceipt({ hash });
      if (r.status !== 'success') throw new Error(`${fn} on ${to} reverted (${hash})`);
      return r;
    };
    const read = (address: string, abi: J[], fn: string, args: unknown[] = []) => publicClient.readContract({ address, abi, functionName: fn, args });
    const bal = (a: string): Promise<bigint> => publicClient.readContract({ address: d.token, abi: v.erc20Abi, functionName: "balanceOf", args: [a] });
    return {
      root, rpc: anvil.rpcUrl, chainId: anvil.chainId, operators, deployment, deploymentJson: JSON.stringify(deployment),
      token: String(d.token).toLowerCase(), rules: String(d.rules).toLowerCase(), factory: factory.address, module: module.address, allowList: allowList.address,
      seller: { base, quote: `${base}/quote`, defaults: `${base}/defaults`, address: String(seller.agent.address).toLowerCase(), hold: (on: boolean) => { held = on; } },
      fundEth,
      mint: async (a, amount) => { const before = await bal(a); await chain.mint(a, amount); for (let i = 0; i < 150 && (await bal(a)) < before + amount; i++) await new Promise((r) => setTimeout(r, 200)); },
      send, read,
      balance: bal,
      now: async () => Number((await publicClient.getBlock()).timestamp),
      errors,
      close: async () => { for (const c of closers.reverse()) await c().catch(() => undefined); },
    };
  } catch (e) {
    for (const c of closers.reverse()) await c().catch(() => undefined);
    throw e;
  }
}
