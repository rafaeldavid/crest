// Source verification of Crest's Sepolia deployment on Sourcify, through its API v2: no key and no account. forge
// 1.0.0's `verify-contract` calls Sourcify's removed API v1, so this sends the compile job itself (the same routes as
// Holdback's scripts/sourcify-verify.mjs).
//
//   node script/sourcify-verify.mjs              check only: each deployed address's code against this checkout's build
//   node script/sourcify-verify.mjs --submit     then send each contract's standard JSON input, and read back the match
//
// It reads the addresses from deployments/11155111.json and each creation transaction from broadcast/, and refuses any
// chain but Sepolia. The input for each contract is `forge verify-contract --show-standard-json-input`, from this
// checkout, whose build must be the one deployed. The vault implementation is created inside the factory's constructor,
// so its creation transaction is the factory's. The RPC URL is never printed.
//   POST /v2/verify/{chainId}/{address}   {stdJsonInput, compilerVersion, contractIdentifier, creationTransactionHash}
//   GET  /v2/verify/{verificationId}      {isJobCompleted, error?, contract: {match, runtimeMatch, creationMatch}}
//   GET  /v2/contract/{chainId}/{address} {match, runtimeMatch, creationMatch}
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const SEPOLIA = 11155111;
const SOURCIFY = 'https://sourcify.dev/server';
const RPC = process.env.CREST_SEPOLIA_RPC || 'https://ethereum-sepolia-rpc.publicnode.com';
const COMPILER = '0.8.28+commit.7893614a';
const submit = process.argv.includes('--submit');

const rpc = async (method, params) => {
  const r = await (await fetch(RPC, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) })).json();
  if (r.error) throw new Error(`${method}: ${r.error.message}`);
  return r.result;
};
if (Number(await rpc('eth_chainId', [])) !== SEPOLIA) throw new Error('the RPC is not Sepolia: nothing is sent');

const record = JSON.parse(readFileSync(join(ROOT, 'deployments', `${SEPOLIA}.json`), 'utf8'));
const broadcast = JSON.parse(readFileSync(join(ROOT, 'broadcast', 'Deploy.s.sol', String(SEPOLIA), 'run-latest.json'), 'utf8'));
const txOf = (name) => broadcast.transactions.find((t) => t.contractName === name && t.hash)?.hash;
const contracts = [
  { name: 'CrestFactory', id: 'src/CrestFactory.sol:CrestFactory', address: record.factory, tx: txOf('CrestFactory') },
  { name: 'CrestVault (implementation)', id: 'src/CrestVault.sol:CrestVault', address: record.implementation, tx: txOf('CrestFactory') },
  { name: 'HoldbackModule', id: 'src/modules/holdback/HoldbackModule.sol:HoldbackModule', address: record.holdbackModule, tx: txOf('HoldbackModule') },
  { name: 'CrestAllowList', id: 'src/CrestAllowList.sol:CrestAllowList', address: record.allowList, tx: txOf('CrestAllowList') },
];

// The check: each address holds code, and the build's runtime code has the same length (immutables differ in value only).
const artifact = (id) => { const [path, name] = id.split(':'); return JSON.parse(readFileSync(join(ROOT, 'out', path.split('/').pop(), `${name}.json`), 'utf8')); };
let ok = true;
for (const c of contracts) {
  const code = await rpc('eth_getCode', [c.address, 'latest']);
  const built = artifact(c.id).deployedBytecode.object;
  const same = code.length === built.length;
  if (!same || !c.tx) ok = false;
  console.log(`${c.name} ${c.address}: ${same ? 'code length matches the build' : `DIFFERS (${(code.length - 2) / 2} bytes on chain, ${(built.length - 2) / 2} built)`}${c.tx ? '' : ', no creation transaction in broadcast/'}`);
}
if (!ok) { console.log('Nothing sent: a check failed.'); process.exit(1); }
if (!submit) { console.log('Check only. Run with --submit to send to Sourcify.'); process.exit(0); }

let all = true;
for (const c of contracts) {
  const input = JSON.parse(execFileSync('forge', ['verify-contract', c.address, c.id, '--show-standard-json-input', '--chain', 'sepolia'], { cwd: ROOT, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }));
  let res, body;
  for (let i = 0; i < 5; i++) {
    res = await fetch(`${SOURCIFY}/v2/verify/${SEPOLIA}/${c.address}`, { method: 'POST', headers: { 'content-type': 'application/json', 'user-agent': 'crest-sourcify-verify' }, body: JSON.stringify({ stdJsonInput: input, compilerVersion: COMPILER, contractIdentifier: c.id, creationTransactionHash: c.tx }) });
    body = await res.json().catch(() => ({}));
    if (res.status !== 429 && res.status < 500) break;
    await new Promise((r) => setTimeout(r, 5000 * (i + 1)));
  }
  if (res.status === 202) {
    for (let i = 0; i < 60; i++) {
      await new Promise((r) => setTimeout(r, 5000));
      const job = await (await fetch(`${SOURCIFY}/v2/verify/${body.verificationId}`)).json();
      if (job.isJobCompleted) { if (job.error) console.log(`${c.name}: Sourcify refused: ${job.error.customCode ?? ''} ${job.error.message ?? ''}`); break; }
    }
  } else if (res.status !== 409) console.log(`${c.name}: Sourcify answered ${res.status}: ${JSON.stringify(body).slice(0, 300)}`);
  const held = await (await fetch(`${SOURCIFY}/v2/contract/${SEPOLIA}/${c.address}`)).json();
  const exact = held.runtimeMatch === 'exact_match';
  if (!exact) all = false;
  console.log(`${c.name} ${c.address}: runtime ${held.runtimeMatch ?? 'none'}, creation ${held.creationMatch ?? 'none'}`);
}
process.exit(all ? 0 : 1);
