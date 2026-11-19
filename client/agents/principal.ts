// The scripted principal (T-560): a company's owner, not a model. It creates one vault, enables Crow's module, funds
// the vault with test tokens and grants one key per agent; between purchases it changes limits, pauses, approves a
// merchant, or withdraws. Every call goes on chain from the principal's own key; the factory keeps no role.
import { readFileSync } from 'node:fs';
import { viem, type J } from '../holdback.ts';
import type { LocalWorld } from './world.ts';

const abi = (n: string): J[] => JSON.parse(readFileSync(new URL(`../../out/${n}.sol/${n}.json`, import.meta.url), 'utf8')).abi;
export const VAULT_ABI = abi('CrestVault');
export const FACTORY_ABI = abi('CrestFactory');
export const MODULE_ABI = abi('HoldbackModule');
export const MAX128 = (1n << 128n) - 1n;
export const MAX32 = Number((1n << 32n) - 1n);

export interface Caps { perSpend: bigint; perPeriod: bigint; lifetime: bigint; maxOpen: number; period: number; expiresAt: number; restricted: boolean; mayDelegate: boolean }
/** No limit of any kind, a UTC day as the period, any seller: the start every scenario narrows. */
export const OPEN: Caps = { perSpend: MAX128, perPeriod: MAX128, lifetime: MAX128, maxOpen: MAX32, period: 86_400, expiresAt: 0, restricted: false, mayDelegate: false };
const note = (s: string) => `0x${Buffer.from(s, 'utf8').toString('hex')}`;
const salt = () => `0x${Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('hex')}`;

export class Principal {
  readonly key: string;
  readonly address: string;
  readonly w: LocalWorld;
  vault = '';
  constructor(w: LocalWorld, key: string, address: string) { this.w = w; this.key = key; this.address = address; }

  static async open(w: LocalWorld): Promise<Principal> {
    const v = await viem();
    const key = v.accounts.generatePrivateKey();
    const p = new Principal(w, key, v.accounts.privateKeyToAccount(key).address.toLowerCase());
    await w.fundEth(p.address);
    const r = await w.send(key, w.factory, FACTORY_ABI, 'create', [p.address, w.token, salt()]);
    const ev = r.logs.map((l: J) => { try { return v.decodeEventLog({ abi: FACTORY_ABI, data: l.data, topics: l.topics }); } catch { return null; } }).find((e: J) => e?.eventName === 'VaultCreated');
    p.vault = String(ev.args.vault).toLowerCase();
    await w.send(key, p.vault, VAULT_ABI, 'setModule', [w.module, w.deployment.erc3009Collector, note('Crow payments')]);
    return p;
  }

  /** A grant for `controller` under `parent` (the root by default), in this vault or another the key controls. */
  async grant(controller: string, caps: Caps, o: { parent?: bigint; vault?: string; key?: string; why?: string } = {}): Promise<bigint> {
    const v = await viem();
    const vault = o.vault ?? this.vault;
    const r = await this.w.send(o.key ?? this.key, vault, VAULT_ABI, 'grant', [o.parent ?? 1n, controller, caps, salt(), note(o.why ?? 'agent grant')]);
    const ev = r.logs.map((l: J) => { try { return v.decodeEventLog({ abi: VAULT_ABI, data: l.data, topics: l.topics }); } catch { return null; } }).find((e: J) => e?.eventName === 'Granted');
    return ev.args.id as bigint;
  }
  setCaps(id: bigint, caps: Caps, why: string) { return this.w.send(this.key, this.vault, VAULT_ABI, 'setCaps', [id, caps, note(why)]); }
  setPaused(id: bigint, paused: boolean, why: string) { return this.w.send(this.key, this.vault, VAULT_ABI, 'setPaused', [id, paused, note(why)]); }
  allow(id: bigint, counterparty: string, why: string) { return this.w.send(this.key, this.vault, VAULT_ABI, 'allow', [id, counterparty, true, note(why)]); }
  withdraw(amount: bigint, why: string) { return this.w.send(this.key, this.vault, VAULT_ABI, 'withdraw', [this.address, amount, note(why)]); }
  fund(amount: bigint) { return this.w.mint(this.vault, amount); }
  getGrant(id: bigint, vault = this.vault): Promise<J> { return this.w.read(vault, VAULT_ABI, 'getGrant', [id]); }
  balance(vault = this.vault): Promise<bigint> { return this.w.balance(vault); }
  /** The approved-merchant entry for a payout address and the deal's three adjudicators. */
  counterparty(payout: string, adj: [string, string, string]): Promise<string> { return this.w.read(this.w.module, MODULE_ABI, 'counterpartyOf', [payout, ...adj]); }
}
