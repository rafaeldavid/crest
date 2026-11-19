// Crest's thin client borrows Holdback's own buyer client, settlement encoders and viem from a Holdback checkout,
// named by HOLDBACK_ROOT, so it signs and checks exactly as Crow's buyer tools do and adds only the vault's funding.
// Nothing here is copied from Holdback; nothing in Holdback names Crest.
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export type J = any; // eslint-disable-line @typescript-eslint/no-explicit-any

export function holdbackRoot(): string {
  const root = process.env['HOLDBACK_ROOT'];
  if (!root || !existsSync(join(root, 'examples', 'buyer-signer.ts'))) throw new Error('HOLDBACK_ROOT must name a Holdback checkout with examples/buyer-signer.ts: this client uses its buyer tools');
  if (!existsSync(join(root, 'packages', 'settlement', 'dist', 'evm', 'encode.js'))) throw new Error(`run pnpm build in ${root} first: this client uses its built settlement encoders`);
  return root;
}

const load = (path: string): Promise<J> => import(pathToFileURL(path).href);

/** viem, resolved from Holdback's own examples, so both sides use one copy. */
export async function viem(): Promise<J> {
  const req = createRequire(join(holdbackRoot(), 'examples', 'package.json'));
  const [main, accounts] = await Promise.all([load(req.resolve('viem')), load(req.resolve('viem/accounts'))]);
  return { ...main, accounts };
}

export const buyerSigner = (): Promise<J> => load(join(holdbackRoot(), 'examples', 'buyer-signer.ts'));
export const agentModule = (): Promise<J> => load(join(holdbackRoot(), 'examples', 'agent.ts'));
export const verify = (): Promise<J> => load(join(holdbackRoot(), 'examples', 'verify.ts'));
export const encode = (): Promise<J> => load(join(holdbackRoot(), 'packages', 'settlement', 'dist', 'evm', 'encode.js'));
export const chains = (): Promise<J> => load(join(holdbackRoot(), 'packages', 'core', 'dist', 'chains.js'));

/** A forge artifact's ABI from Crest's own build (`forge build` writes out/). */
export function crestAbi(name: string): J[] {
  const file = new URL(`../out/${name}.sol/${name}.json`, import.meta.url);
  if (!existsSync(file)) throw new Error(`run forge build in the Crest checkout first: ${name}'s ABI is not in out/`);
  return JSON.parse(readFileSync(file, 'utf8')).abi;
}

/** Every error a funding through the module can revert with, by name: the vault's, the module's, Holdback's and the token's. */
export function fundingErrors(): J[] {
  const seen = new Set<string>();
  const out: J[] = [];
  const add = (abi: J[]) => { for (const e of abi) if (e.type === 'error') { const sig = `${e.name}(${e.inputs.map((i: J) => i.type).join(',')})`; if (!seen.has(sig)) { seen.add(sig); out.push(e); } } };
  for (const n of ['CrestVault', 'HoldbackModule', 'HoldbackRules', 'AuthCaptureEscrow', 'ERC3009PaymentCollector']) { try { add(crestAbi(n)); } catch { /* not built: fewer names */ } }
  // The token's own errors: Holdback's local test token and any token artifact beside it.
  const out2 = join(holdbackRoot(), 'contracts', 'out');
  for (const dir of existsSync(out2) ? readdirSync(out2).filter((d) => /USDC|ERC20|Token/i.test(d)) : []) {
    for (const f of readdirSync(join(out2, dir)).filter((x) => x.endsWith('.json'))) { try { add(JSON.parse(readFileSync(join(out2, dir, f), 'utf8')).abi ?? []); } catch { /* skip */ } }
  }
  return out;
}
