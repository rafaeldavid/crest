# Crest design record 0001: the vault, its grants, child vaults, the factory and the Holdback module

- **Status:** Accepted, 2026-11-19, for the decisions under "Decided"; the points under "Open" are the maintainer's.
- **Origin:** Crow's task T-554 and roadmap row N204. Holdback's side is its ADR-0041 and decision D84: Holdback changes nothing and sees only a payment address that funds a hold.
- **Labels:** **measured** (run or read as cited), **documented** (a published source says it), **inferred**, **guessed**.

## Summary

1. **One vault per principal holds the money and a tree of grants.** The principal holds the root. Each agent gets a grant, and an agent allowed to delegate gives its sub-agents grants of their own. Every payment is checked and counted at its grant and at every grant above it, in the transaction that commits the money.
2. **A grant's controller can also create a child vault** for a sub-agent: its own address and its own money, filled from the parent within the grant's limits. Its payments still answer to the parent's stops, expiries, per-payment limits and approved merchants, and everything above it can take the money back.
3. **The vault pays only through modules the principal enabled, each to the one payee the principal pinned for it.** The vault approves exactly one token authorization, the one it builds itself for the payment it has just checked, and only for the rest of that transaction.
4. **The Holdback module is the first venue.** It exposes Holdback's own `agreeAndFund`, reads the deal's terms, has the vault charge the buyer's grant, and forwards the call unchanged. Holdback's contracts are unchanged.
5. **Nobody who deploys or relays gains any power.** A vault is a fixed minimal clone, its principal is an argument, and the factory keeps no role.

## Context

### What the maintainer asked for

From Crow's founder, 2026-11-19, in order:
- "the owner deploys a contract, funds it, and sets basic controls. The agent can then spend only inside those controls, enforced on chain where the agent cannot override them";
- "look at Link, Stripe, Ramp, etc. spend control frameworks in detailed research and then transfer that into smart-contract deployments with gas we cover, for a nominal fee etc. So it's hard controls";
- "we should classify this as a separate protocol ... We shouldn't entangle them but make them modular. Very likely you'll need a factory approach so each ephemeral agent gets their own spend controls";
- "the design needs to deeply consider current procurement control patterns, but then translate that into smart-contracts and potential agent delegation patterns";
- "it does seem like we're gonna have to build a wrapper on top of whatever we do so that onboarding / implementation is easy";
- "agent principal needs to be able to claw back money, and intervene ... and the vault needs to be able to have approved merchants, but still use Crow (since you an prove money can go to end agent)";
- the name Crest, "which means both a cap but also badge representing a family"; child vaults in the first version; and, to the recommended shape, "Seems like you are good to go on the build".

### What the research found

Three passes ran on 2026-11-19 (kept privately; their findings are summarized here).
- **Products and procurement.** 45 distinct controls across 23 card, wallet and agent-payment products and 15 procurement sources; 36 can be hard rules on chain. The first version's set holds up: per payment, per period, a total, open commitments, approved merchants, expiry, pause and close.
- **Existing standards cannot do it alone.** Holdback funds a hold from a signed token authorization (ERC-3009), and the token asks the payer's address to approve it (ERC-1271), in a read-only call, with only a hash. Safe's allowance module, Coinbase spend permissions, MetaMask delegations and session-key modules all answer from a key or a role, so they cap money moved into the agent's own key, not the deal it pays [two independent passes agree]. No stock rule can check the merchant: the seller's payout address sits inside the payment's hash, and any contract can act as an operator of the shared escrow, so a rule on the signed fields alone paid a stranger on a fork of Sepolia [measured].
- **A vault that makes the funding call itself works.** It writes its counters before the token asks, then answers yes for the one digest it approved. Against Holdback's deployed contracts on a fork of Sepolia, a sketch of this design with three levels of grants passed 18 of 18 tests; on a local chain, Holdback's operators followed such a funding with no change and the deal ended Released [measured].
- **The pattern of capped, chained spenders is kept.** Every level checks its own limit and passes the payment up, so no child can exceed any ancestor. Crest keeps that rule and applies it inside one vault, because a contract per level costs about 1,000,000 gas per agent on an Ethereum-style chain against about 171,000 for a grant record [measured in the sketch].

## Decided

### 1. Three parts

| Part | What it knows | What it never does |
| --- | --- | --- |
| `CrestVault` | the principal, the token, the grants, the limits and counters, the child vaults, the enabled modules and the payee each may pay | read a venue's state or terms |
| `CrestFactory` | the vault's code | keep any role in a vault it created |
| `HoldbackModule` | Holdback's terms, its payment record and its deal stages | hold tokens or state |

A second venue is a second module; the vault does not change.

### 2. The grants

- **A grant** names its parent, its controller (one key), its limits and its state. The principal controls the root. A key controls at most one grant in a vault.
- **The limits:** the most one payment may be; the most a period's payments may add up to, with the period's length in seconds (86,400 for a UTC day); the most the grant may ever pay; how many commitments may be open at once; an expiry; whether the controller may grant children or create child vaults. The largest value of each type means no limit of that kind. An allow list, when the grant is restricted, names the counterparties it may pay.
- **Every payment charges the grant and every grant above it,** checking each one's state, expiry, limits and list, and adding to each one's counters. One refusal reverts the payment, and nothing is counted.
- **A child granted wider limits than its parent is still bound** by the parent at payment time, so the vault never compares limits when a grant is made.
- **Who may do what.** The principal withdraws, enables modules, hands the vault over and acts on any grant. A controller above a grant may pause, resume or close it, set its limits and list its counterparties. A grant's own controller may pause or close itself and, when allowed, grant children and create and fill child vaults; it may never widen, resume or reopen its own grant.
- **Delegating asks the whole path.** Granting, creating a child vault and filling one each need every grant on the path, here and in every ancestor vault, to be open, unexpired and allowed to delegate. That holds for the grant's own controller and for authority above it, so turning an agent's delegation off stops all delegating at or below it, through its sub-agents and inside its child vaults. Only the top principal grants without it.
- **A pause has no rank.** Anyone above a paused grant can lift the pause, so a principal who distrusts an agent pauses the agent's own grant, which stops everything below it; the agent cannot lift that.
- **A key holds one grant per vault, and closing a grant frees its key.** A closed grant's controller has no authority, and delegating needs an open path, so a closed agent cannot act through its sub-agents. A handover closes any grant the new principal's key held, so no agent can block it by giving that key a grant first. In the same way, authority above a key's grant may grant that key anew, and the old grant closes in that transaction, so no agent can hold a key the principal is granting.
- **A new period length keeps the spend of the last window paid in when that window overlaps the new current one,** so changing a limit's period never hands the agent a fresh window. The vault keeps one window's counter, not a history, so a longer period knows only that last window (open item 11).
- **Every change carries who made it and a note.** Each function a principal or a controller calls takes a `note`, and its event carries it with the caller: a reason, a ticket, or the hash of a document kept elsewhere. Limits changes also carry the previous limits. The note is public, so a reason meant to stay private goes in as a hash.
- **Periods are fixed windows** (`floor(time / period)`), with no carry-over. A refund does not give a period's limit back: the counters are gross, and the refunded money returns to the vault.
- **Open commitments are counted, not their total.** The total at risk is already bounded by the count times the per-payment limit. The module that opened a commitment releases it when the venue says it has ended; anyone may ask it to.

### 3. Child vaults

- **Created through the parent:** the controller of a grant that may delegate asks its vault to create a child vault. The child's principal is that controller; its parent is the vault, and its parent grant is that grant.
- **Filled through the parent:** the parent's controller moves money into the child. The move is charged to the grant's path for its period and total limits, like a payment; it opens no commitment.
- **Bound from above:** each payment from a child is checked against the parent grant's path for its state, expiry, per-payment limit and approved counterparties, through the whole chain of parents. A stop anywhere above stops the child at once.
- **Modules come from the top:** a child pays only through modules enabled at the top vault, to the payees pinned there. A child's principal cannot enable a module.
- **Money goes back up only:** a child sends money to its parent vault and nowhere else. Its principal, and anyone with authority over the parent grant, can send it back.
- **The child's root extends the parent grant:** only authority strictly above the parent grant can widen, resume or reopen it; the grant's controller manages everything below it. Filling a child, like creating one, needs every grant on the path above it to be open and allowed to delegate.
- **No handover strands a child:** a child vault cannot be handed over, and a top vault's root creates no child, so a change of principal never leaves a child with the previous one.

### 4. Payments

- **A module asks the vault to charge.** The vault checks the module is enabled, charges the path, records the commitment, and approves exactly one ERC-3009 `ReceiveWithAuthorization`: from the vault, to the module's pinned payee, for exactly the charged amount, with the module's nonce and deadline. It holds that approval in transient storage for the rest of the transaction.
- **The vault answers ERC-1271 to the token only,** and only for that digest. It answers no one else, so an agent's own signature never moves the vault's money.
- **Nothing reaches a funded hold.** A hold sits in the venue's escrow; the vault has no function that calls the venue except the escrow's own payer-only `reclaim` after the escrow's expiry, which can only return money to the vault.

### 5. The Holdback module

- **The buyer is the agent's key; the payer is the vault** (today; section 11 makes the vault the buyer in the next build). The terms name the agent's key as `buyer` and the vault as `buyerPaymentAddress`. The rules contract checks the agent's own agreement; the vault's grant for that key bounds what it may fund.
- **The counterparty** is the deal's payout address together with its three adjudicators, so a principal approves a merchant and the adjudicators it accepts in one entry. A hold pays out only to the terms' payout address or back to the payer (Holdback, `HoldbackRules.sol:400`) [measured], so the approved-merchant list holds through the escrow.
- **The amount** is the hold: price plus the adjudication fee. Operator fees are not paid through the module; the pilots' fee is 0.
- **Open deals end** when the rules contract's stage is Released, Refunded or Settled, or the escrow's expiry has passed.
- **One module per Holdback rules deployment.** After a redeploy the principal enables the new module with one transaction.

### 6. The factory

- **Each vault is a minimal clone** of one implementation, at an address that follows from the principal, the token and a salt. Anyone may create it and pay the gas; the creator gets nothing. A second creation returns the existing vault.
- **The implementation and the factory** deploy once per chain.

### 7. Neutrality and the hold

No principal, controller, module or factory can stop a funded deal from settling by its terms or move a hold. Before funding, a limit or a stop only declines to pay, as any buyer may. After funding, the principal can stop its agent and take back everything not in a hold, and Holdback's own timeouts return every hold. A Crest vault is the principal's own wallet, not a settlement contract: its principal has over it what any key has over its own balance.

### 8. Measured on the first build

- `forge test` on Holdback's own test world and its unchanged rules contract: an attack test for each control in section 9, refused by name; five invariants over random payments through a tree (no grant passes its total, period or open limit; every level counts what passes through it; money leaves only to the pinned payee); a fuzz test that the approved digest equals the collector's for any terms; and a selector allowlist [measured, 2026-11-19]. One review and one red-team pass found three child-vault authority gaps, a handover an agent could block, a period change that opened a fresh window, and missing attack tests; each is fixed and covered by a test. A re-review killed 11 of 13 one-line mutations with the PR's own tests and 2 more with its own. It found one regression, a principal that handed the vault to itself closing its root, now fixed and tested. The red team's 29 attacks, the review's 24 tests, the re-review's 9, the deploy script's 8 and the build's own tests pass together: 145 of 145, with the three fork suites skipped without an RPC [measured, 2026-11-19].
- A cross-check against the published audits of comparable systems and Holdback's own audit work sorted 113 vulnerability classes [measured, 2026-11-19]:
  - 82 covered by a test;
  - 20 not applicable;
  - 5 residual: inherent or documented limits with no test;
  - 6 gaps, from 3 distinct findings.

  None let money past a limit or touch a funded hold. The three findings:
  - delegation turned off did not stop an agent delegating through its sub-agent (Medium);
  - a longer period forgot spend inside the new window (Low);
  - an agent could take a key the principal was about to grant (Low).

  Each is fixed, and the cross-check's attack tests, which failed before, pass since. One case of the period finding stays open for the maintainer (open item 11). Its coverage tests add:
  - the vault never approves a transfer, cancel or permit digest during a charge;
  - no SELFDESTRUCT, CALLCODE or DELEGATECALL in the vault, the factory or the module;
  - a vault is exactly the library's minimal proxy;
  - zero addresses are refused;
  - a fork test through Circle's USDC on Sepolia.
- The deploy script on a fork of Sepolia, against Holdback's live rules contract, escrow, collector and tUSDC: it deploys at the CREATE2 addresses its code gives and checks itself; one deal inside the caps ends Released, and one above the per-deal cap is refused. At this repository's commit `d361715` the factory's transaction costs 3,168,775 gas, vault implementation included, and the module's 1,446,305 gas [measured, 2026-11-19].
- The chain the script deploys to is the one the RPC answers. Forge 1.0.0 simulates a script with `block.chainid` 31337 from `foundry.toml` whatever the RPC, and signs for the chain the RPC answers, so a check on `block.chainid` alone would pass on mainnet [measured, 2026-11-19; the signing side was measured by Holdback's red team for T-410]. Every public path of the script reads the RPC's chain, and against an RPC that answers chain ID 1, `run`, `deploy` and `verify` each refuse before anything is sent [measured]. A review of the first fix found a direct `deploy` call that took the chain as an argument, a record written in the simulation before anything was sent, and two fork suites racing on a shared environment variable. Each is fixed and tested. The record is now written only by `verify`, which checks the contracts the chain holds. On Sepolia the rules contract comes from Holdback's own record at the pinned commit. A rerun deploys nothing twice.
- Static analysis: Slither and Aderyn report no finding of High impact that holds on reading; their ordering and unused-return findings are fixed [measured].
- On a local chain with Holdback's operator code, a funding sent from a Crest vault through the Holdback module was followed with no change to the operators, and the deal ended Released; a funding over the per-deal limit reverted [measured, 2026-11-19, at this repository's commit `e532074`].
- A funding through a vault one level below the root costs 390,634 gas, against 297,568 from a plain key, measured in the same forge test [measured].

### 9. What the tests must show failing

For each control, an attempt to break it that fails: a payment over each limit at the grant and at each ancestor; a wider child; siblings that together pass their parent; an unlisted counterparty at any level; after a stop at any level; an expired grant; a controller widening or resuming itself; a stranger or an agent withdrawing, enabling a module or granting; a module not enabled; a payee other than the pinned one; a commitment opened or released twice; a failed venue call after a charge (nothing counted); the approval used twice or asked by a caller that is not the token; the period boundary; a child vault paying past its parent's stop, expiry, per-payment limit or list; a child sending money anywhere but up; a Holdback funding sent straight to the rules contract for a vault-paid deal; and the principal emptying the vault after a funding while the deal still settles.

### 10. Identity and reputation standards: addresses are the keys

A research pass on 2026-11-19 read the agent identity and reputation standards: ERC-8004 (Trustless Agents: identity, reputation and validation registries, Draft, deployed on Ethereum and Sepolia), ERC-8183 (agentic commerce jobs, Draft), ERC-7710 and ERC-7715 (delegations, Draft), ERC-6551, ERC-8196, x402, A2A and AP2. Crest is compatible with them as built, and needs no contract change [measured on a fork of Sepolia: 11 of 11 scratch tests].
- **A grant's controller can be a registered agent's wallet,** so `grantOf(agentWallet)` finds an ERC-8004 agent's grant. A vault itself cannot be an agent wallet [measured].
- **Identity goes in a note, not in storage.** A principal that wants a grant tied to an agent identity puts it in the grant's note (for example an ERC-8004 agent ID); `Granted` carries it, at about 2,000 gas against 22,100 for a stored field [measured].
- **No payment reads a registry.** The ERC-8004 registries are upgradeable and controlled by one outside key [measured], so a payment that read them would let that key change who is paid. Approved merchants stay payout addresses, which Holdback's terms enforce.
- **Crest emits no reputation or validation records.** A reputation system can read Crest's events and Holdback's deal outcomes by the commitment ID; Crest stays a wallet.

### 11. Who the buyer is (decided, 2026-11-19)

The maintainer: "if an agent uses a vault, the vault admin owner should be the buyer, but if agent doesn't have a vault then it would be the buyer I think".

- **With a vault, the vault is the buyer.**
  - It is named in a deal's terms as `buyer` and stays the `buyerPaymentAddress`.
  - The agent signs for the vault while its grant can pay.
  - The principal can sign in the agent's place.
  - After a stop, the vault refuses the agent, so the principal cuts the agent off from a funded deal.
  - The principal's key never has to sign a deal, so buying stays autonomous.
- **Without a vault, the agent's key is the buyer,** as today.

### 12. Build plan: the vault as the buyer (not built)

The build waits for the first stage of the two-model test (T-560), which runs with the agent's key as the buyer. The same scenarios then rerun with the vault as the buyer, plus new ones where the principal steps in on a funded deal.

**What the vault answers, and to whom.** Holdback's rules contract checks `buyer` through Solady's `SignatureCheckerLib`: ECDSA for an address without code, ERC-1271 for one with code (`HoldbackRules.sol:565-570`). It asks for three things:
- the agreement (`:183`);
- an early accept (`:339`);
- the buyer's signature on a settlement both sides sign (`:377`).

So the vault can be the buyer with no change to Holdback's contracts [measured, at the pinned `27ab44e8`].

| Who asks | About what | The vault says yes when |
|---|---|---|
| The token | The ERC-3009 `ReceiveWithAuthorization` the vault approved during `charge` | As today: the one digest it holds in transient storage, asked by the token only. Never an agent's signature. |
| Anyone (a contract, an operator's `eth_call`) | A Holdback buyer message's EIP-712 digest | All three conditions below hold. |
| Anyone | Anything else | Never. |

The three conditions for a Holdback buyer message:
1. **The signature decodes.** It carries the message's kind, its fields and a 65-byte ECDSA signature.
2. **The module rebuilds the digest.** The venue's module, enabled at the top vault, rebuilds the digest from those fields and returns the deal's ID; the digest must equal the one asked about. The vault stays ignorant of venues: the module says what a message is, as it says what a payment is.
3. **The signer may act.** The signer must be one of:
   - the controller of the grant that opened that deal (`getOpen(id).grant`), while that grant's path can pay: open, unpaused and unexpired, here and in every ancestor vault;
   - anyone with authority above that grant, which includes the principal.

**The agreement.** The module recovers the agent's key from the agreement signature and charges that key's grant. The vault then answers the rules contract's check of the agreement for the same deal and the same key.

**A funded deal after a stop.**
- When the agent's grant, or anything on its path, is paused or closed, the vault refuses that agent's signature on every buyer message for the deals its grant opened: early accept, and a settlement both sides sign.
- The principal, or any authority above the grant, signs instead.
- Holdback's own deadlines still run: the adjudicator's decision, refunds at expiry, and the vault's `reclaim`. No deal is stuck.
- This narrows Holdback's ADR-0038 point 4, "It never touches a funded hold", for a deal whose buyer is a vault. A Holdback decision record needs a line saying so; that is the maintainer's to accept.

**Child vaults.**
- A child vault is the buyer of its own deals. One principal's agents then deal from separate addresses.
- Inside the child, a sub-agent signs while its path can pay.
- The child's principal, and everyone above it in the ancestor vaults, can sign in its place.

**Attack tests that must fail:**
1. The agent signs for the vault after its grant is paused or closed, or after anything above it is.
2. A stranger signs: no grant here, and no authority above.
3. Another agent in the same vault signs a buyer message for a deal it did not open.
4. The principal's signature on one deal is replayed on another deal.
5. A signature's fields name one deal while the digest is another deal's.
6. A message is decoded by a module the principal has disabled.
7. A digest under another EIP-712 domain, or a deal another vault pays, is presented.
8. The agent's raw ECDSA signature is offered to the token as the vault's ERC-3009 authorization (`TransferWithAuthorization`, `ReceiveWithAuthorization` or `CancelAuthorization`).
9. A sibling sub-agent signs for another sub-agent's child vault.

**What Holdback's operators and adjudicator must change.** None of this is Crest's code.
- **Who carries it.** Holdback's T-549 carries it in schema v0.12 and its two pull requests: the buyer's fields in the schema one, the buyer's checks in the settlement one. It adds them on the maintainer's yes on Holdback's record (D84).
- **The pinned bundles.** `site/buy.mjs` and `site/try.mjs` stay pinned by hash, so their ECDSA path stays byte-identical. A vault buyer signs through Crest's own tooling or a new command.

The changes:
- **The check.** Read a buyer's signature as T-549 reads the seller's:
  - ECDSA for a 65-byte signature from an address without code;
  - ERC-1271 through `eth_call` otherwise, with a code override (or ERC-6492) for a vault the factory has not deployed yet.
- **Where the check goes:**
  - `packages/core/src/eip712.ts`: `verifyTerms`, `verifyMessage` and the check of a message both sides sign recover ECDSA only, at `recoversTo`;
  - the EVM node's buyer checks in `packages/settlement/evm/evm-settlement.ts`;
  - SimChain;
  - the reference adjudicator's buyer checks.
- **The schema.** Use `PartySignature` for every buyer signature:
  - the buyer's signature on the terms;
  - `Agree`;
  - `EarlyAccept`;
  - the buyer's half of `Mutual`;
  - any other message in `messages.schema.json` that the buyer signs.

  The ERC-3009 funding signature stays as it is: for a vault payer, Crest's module ignores its content.
- **The vault must also answer the terms digest.** That holds if operators keep checking the buyer's signature on the full terms. Then the module rebuilds `CommitmentTerms` as one more message kind.

### 13. Gas: the operators relay a vault's funding (decided, 2026-11-19; not built)

The maintainer, asked who pays the network fee when an agent funds a deal from a vault: "Build the operators' relay after the test, so agents need no ETH", and earlier, "gas we cover". The relay is a build in Holdback's operators, after the first stage of the two-model test (T-560). Nothing in Crest changes.

What an operator accepts, checks and sends:
- **What it accepts.** The same signed messages the funding route takes today for a key buyer: the seller's signature, the adjudicator's acceptance, the buyer's agreement and a funding signature. Measured: the funding signature is not checked off chain (`fund` in core). For a vault payer, Crest's module ignores its content and requires 65 bytes. So there is no new route and no schema change [inferred; the T-549 build confirms it].
- **What it checks before sending:**
  1. The payer, `buyerPaymentAddress`, is a vault of a factory the operator lists: `isVault(payer)`. The factory is listed as the rules contract is.
  2. The vault pays through this rules deployment's module: `payeeOf(module)` is the rules contract's ERC-3009 collector.
  3. `module.agreeAndFund(...)` succeeds in an `eth_call`. A revert is the vault refusing (a limit, a stop or an allow list). The operator returns it to the agent as a problem and sends nothing.
- **What it sends.** The module call, from its own relayer key. It follows the deal as it follows any funding. Measured on a local chain at `e532074`: the node followed a funding sent through Crest's module to Released, with no node change.
- **Who pays.** The operator's relayer key pays the gas, which Crow covers for the pilots. A refused funding costs it only the `eth_call`. A funding that passes the simulation and reverts on chain (for example, the principal paused the agent in between) costs it that transaction's gas. The per-buyer write budget bounds that.
- **Neutrality.** An operator that will not relay stops nothing: the agent, another operator or anyone with ETH can send the same call to the module.

### 14. The fee (decided: none now, with fee code; the design below is proposed, for the maintainer)

The maintainer, asked whether Crest charges a fee: "None now, but have fee code in the contract". The fee is the one place where Crest could give someone power over a principal's money, so the design comes before the code.

The proposal, with the reason for each part:
1. **Fixed at deployment, by no one afterwards.**
   - The rate (`FEE_BPS`, an integer in basis points, 0 today) and the recipient are immutables of the vault implementation.
   - The factory's constructor sets them when it deploys the implementation, and every vault and child vault from that factory carries them for good.
   - There is no setter, no owner and no upgrade, so no key, Crow's included, can raise a fee on money already in a vault.
   - A new rate means a new factory at a new address. A principal moves to it by creating a vault there and withdrawing from the old one.
   - One rate per factory, rather than one per module: the principal already chooses modules, and a per-module fee would let any module's author set any rate and put every module's fee code in a review's scope. One place is one thing to audit.
2. **What it is taken on.**
   - Only a payment a module asks for, in `charge`: `fee = floor(amount × FEE_BPS / 10,000)`, rounded down, so never above the stated rate.
   - None on a deposit, a `withdraw`, money coming back (a refund, a void or `reclaim`), `fundChild`, `takeBackFromChild` or `returnToParent`.
   - A child vault's payment charges the fee once, in the vault that pays. The parent's `checkPath` is a view and moves nothing.
3. **A refused payment charges nothing.** The fee is counted inside `charge`, after every check. A refusal anywhere later in the transaction, such as Holdback's agreement call reverting, reverts it.
4. **The fee is owed, then collected.**
   - `charge` adds the fee to the vault's `feeOwed` and moves no token to the recipient.
   - Anyone may call `collectFee()`, which sends exactly `feeOwed` to the fixed recipient.
   - `withdraw`, `fundChild` and `returnToParent` move only the balance above `feeOwed`.
   - Why: the recipient can never change. If it ever refused tokens, say a contract that reverts, a key the token blocks, or an address that was lost, a fee pushed at payment time would block every payment from every vault of that factory. A fee that is owed blocks nothing: payments never depend on the recipient. At worst, a fee waits uncollected in the vault.
5. **The recipient must be an address that cannot be lost.** For example, a multisig the maintainers hold, recorded in the deployment record. If it is a contract, it must be able to move the token onward. Otherwise collected fees stay in it for good, and only that contract's own code decides their fate.
6. **The hold is never blocked or shrunk.**
   - The fee is owed on top of the payment.
   - The ERC-3009 authorization stays exactly the payment's amount, so the hold receives what the terms say.
   - After funding, nothing in Crest reaches the hold, the fee included.
   - A vault whose balance above `feeOwed` is less than the amount plus the fee refuses the payment before anything is funded.
7. **It counts against the limits.** The fee counts with the payment against every limit on the path, so the principal's limits bound everything that leaves the vault. At 0 nothing changes.
8. **The constructor refuses only the malformed:** a rate above 10,000, or a non-zero rate with no recipient. Any lower cap is the maintainer's choice, not the code's.
9. **Two events, only when there is a fee:**
   - `FeeOwed(grant, fee)` when a payment owes one;
   - `FeeCollected(recipient, amount, by)` when it is collected.

   `Charged` is unchanged.
10. **At a rate of 0, as near zero cost as measurable.** One comparison of an immutable in `charge`. The gas of a funding before and after goes in the pull request.

Attack tests that must fail:
- anyone changing the rate or the recipient: no selector can, and none appears in the selector allowlist;
- a fee above the stated rate through rounding, as a fuzz test over amounts;
- a fee charged twice through a child vault's path;
- a fee on a refund, a void, `reclaim`, `withdraw`, `fundChild` or `returnToParent`;
- a refused payment that still pays a fee;
- a hold that receives less than its terms;
- a vault short of the fee that still funds;
- a recipient that reverts on receipt and so blocks a payment;
- a `withdraw`, a fill or a return that takes the fee owed;
- `collectFee` sending anything but `feeOwed`, or to anyone but the recipient.

Every fee line is in the outside review's scope: the maintainer set it to all six contract files, in deep mode.

### 15. Approved merchants in a list contract the principal chooses (decided; the design below is proposed, for the maintainer; not built)

The maintainer, on approving merchants by an agent-identity registry: "later, crest code should allow for an approved address list defined in another contract, not integrated into the vault code itselt, the vault owner should be able to set where that check goes".

This changes the design, not only the timing. Today each grant keeps its own allow list inside the vault: the `restricted` flag, the `allowed` mapping and `allow`. Under this design the list lives in a separate contract, and the vault asks the contract the principal chose. An identity-based list is then one such contract, written later.

The proposal, with the reason for each part:
1. **One list contract per grant, set with the grant's limits.**
   - `Caps.list`, an address, replaces `Caps.restricted`. An address of 0 means any counterparty.
   - **Why per grant:** limits and lists are per grant today, and different agents buy from different merchants. One list for the whole vault cannot say that.
   - **Why inside `Caps`:** a grant and its list are then set in one transaction, so no new grant is ever briefly unrestricted.
   - **Who sets it:** only authority above the grant, the principal included, through `grant` and `setCaps`. The change carries a note in `Granted` or `CapsSet`.
   - An agent cannot change its own list's address, as it cannot widen its own limits.
2. **The vault asks every level.**
   - A payment asks the list of every grant on its path that names one, here and in every ancestor vault. Today's `checkPath` walk stays.
   - So a child grant or a child vault pointing at a looser list still needs every list above it to say yes. It can never be looser than its parent's path.
3. **The call is read-only, gas-capped and fails closed.**
   - The vault calls `allows(vault, grant, counterparty)` with `staticcall` and a fixed gas cap. 30,000 gas is proposed.
   - The cap is fixed only after measuring two lists:
     - the default list;
     - a list that reads another contract's storage, as an identity-based list would: a cold call and cold reads in a registry.
   - The pull request reports both.
   - Only one answer counts as a yes: exactly 32 bytes equal to the function's selector, as ERC-1271 returns a magic value.
   - A checker that reverts, runs out of gas or returns anything else refuses the payment.
   - It is read only in `charge` and `checkPath`, never after funding, so it cannot touch a deal already funded, and it never moves money.
4. **A default list contract does what the vault's list does today.**
   - `CrestAllowList`: one deployed contract with no owner, storing `(vault, grant, counterparty) → bool`.
   - A write passes when the vault says the sender is above that grant (`vault.isAbove(sender, grant)`), the same rule as `allow` today. It emits `Allowed(vault, grant, counterparty, ok, by, note)`.
   - The first version loses nothing, and the vault drops `allowed`, `allow` and the `Allowed` event.
5. **Trust, stated plainly.** Whoever controls a list contract controls whom the grant can pay. A principal who points a grant at someone else's list trusts that party, and the owner's guide says so. The default list has no owner: only the vault's own authority writes a vault's entries.

Attack tests that must fail:
- an agent changing its own grant's list address;
- a list that says yes to a counterparty its parent's list refuses, in the same vault and through a child vault;
- a list that tries to re-enter the vault or write anything, which the `staticcall` refuses;
- a list that reverts, loops past the gas cap, or returns `true` or garbage instead of the magic value;
- a list whose answer changes between an off-chain simulation and the payment, where the answer at payment time decides;
- a stranger writing a vault's entries in the default list.

Gas: the pull request reports a payment's cost with the external check against today's in-vault check, at one level and at three.

Scope: the default list contract and its interface are new files, so the outside review's file list grows by two when this is built.

### 16. Three more answers (decided, 2026-11-19)

- **A second approver above an amount:** "Later, when someone asks". Nothing to build.
- **A trademark search for the name:** "go ahead and check". A first desk search is running and kept privately. A lawyer's opinion comes after it and is the maintainer's to ask for.
- **Building order:** the vault as the buyer, the external list and the fee are built after the first stage of the two-model test (T-560), which keeps running on what is merged.

### 17. Limits for a sub-agent by a signature alone (evaluated for the maintainer; not built)

The maintainer: "Does this require code change for crest? Feels like something quite useful. Evaluate it, if it can be done we might as well do now". It needs a code change in the vault. Two shapes were compared.

**(a) A signed grant that lands on chain at first use (recommended).**
- **How it works.**
  - The controller of a grant that may delegate signs an EIP-712 `Grant` off chain: the parent grant, the new key, its limits, a salt and a deadline.
  - Anyone submits it with `grantBySig`: the sub-agent, an operator, or a batch with the first payment through Multicall3. The controller sends no transaction.
  - The vault runs the same checks as `grant`, with the signer in place of the sender: authority over the parent, and a path that is open and may delegate. It then creates an ordinary grant, whose event names the signer as `by`.
  - From then on it is a grant like any other.
- **Replay.**
  - The signed data is bound to one vault and one chain by the vault's EIP-712 domain: the name, version, chain ID and the vault's address.
  - The grant's ID is `keccak256(parent, key, salt)`. Once created it stays taken, even after the grant closes, so the same signature never creates a second grant. No separate nonce is needed.
  - The deadline ends the signature's use.
  - The signer's key is checked by ECDSA, or by ERC-1271 if it is a contract.
- **Revocation.**
  - Before first use, three things stop it:
    - the deadline passes;
    - the signer loses its authority;
    - its path is paused or closed, or may no longer delegate.
  - An explicit cancel would need about 6 more lines: a closed record under the same ID. It is optional; short deadlines are recommended instead.
  - After first use it is an ordinary grant: pause it, close it, or stop anything above it.
- **A parent's stop.** Submitting checks the whole path at that moment, so a signed grant below a stopped parent cannot land. Once landed, the parent's stop stops it at every payment, as it stops any grant.
- **Size.** About 30 new lines in `CrestVault.sol` and 12 in `ICrestVault.sol` [inferred]:
  - `grantBySig`;
  - the EIP-712 domain, from Solady's `EIP712`;
  - one type hash;
  - one shared internal grant path that `grant` also uses.

  An outside review reads the new function, the domain, and the shared path.
- **Gas.**
  - The first payment costs one grant (126,160 gas at the median today [measured]) plus about 3,000 to 6,000 for the signature check and its calldata [inferred], plus today's funding (378,612 gas at the median through the module [measured, in-test execution without the 21,000 base]).
  - Every later payment costs exactly today's funding.
  - The build's pull request reports the measured numbers.

**(b) A grant that never lands, checked from its signature chain at every payment (not recommended).**
- **How it works.** Each payment carries the chain of signed grants from an on-chain grant down to the paying key, and the vault verifies every link every time.
- **Counters.** The period, total and open limits need counters that persist between payments, so the vault must store them by the signed grant's hash. The grant then lands on chain anyway, as counters, without the rest of the model.
- **Revocation.** It needs a new on-chain list of revoked hashes, because there is nothing on chain to close.
- **Size and gas.** About 120 to 200 new lines [inferred]:
  - link encoding;
  - a verification loop;
  - the counters by hash;
  - the revocation list;
  - a path walk that mixes on-chain and off-chain levels, across child vaults.

  Every payment pays the signature checks and calldata of every link, again and again.
- **Review.** It is a second model of the tree beside the first, so the outside review reads both, and every invariant must be proven twice.

**Attack tests that must fail, for (a):**
- a signature replayed after its grant closed;
- a signature from another vault, another chain or another domain;
- a signature after its deadline;
- a signer without authority over the parent;
- a signer whose path is paused, closed, expired or may not delegate;
- a signer that lost its authority between signing and submission;
- limits, key, parent or salt changed after signing;
- a key that holds a grant elsewhere, when the signer is not above that grant;
- a malleable signature, which yields the same ID and is refused as a replay.

**Recommendation:** build (a) in the next build, with the vault as the buyer, the fee and the external list, after the first stage of the two-model test (T-560).

## Open, for the maintainer

1. **The fee's design** (section 14): fixed at deployment in the vault implementation, taken only on a payment, rounded down, never on the hold. To accept or change before it is built.
2. **The external merchant list's design** (section 15): one list contract per grant, set with the limits, asked read-only and gas-capped at every level. To accept or change before it is built.
3. **Grants by signature** (section 17): shape (a) is recommended for the next build.
4. **Holdback's side of the vault as the buyer** (section 12):
    - the maintainer's yes on Holdback's record (D84), so T-549's schema v0.12 carries the buyer's longer signature;
    - his acceptance that a vault buyer narrows ADR-0038 point 4.
5. **The name:** the first desk search found the name crowded in crypto and finance, with a close use in the same field. Until the maintainer decides, it spreads no further: no site page, package name, domain or announcement.
6. **Crow paying to create vaults on request:** a new request field or route; the relay of fundings is decided (section 13).
7. **Depending on third-party code a single address can pause, or under copyleft or source-available licences:** none in the first version.
8. **Deploys to Sepolia,** on the maintainer's word. They follow Holdback's redeploy of its rules contract (T-563), since the module is per rules deployment, and a bump of `lib/holdback` to the new record.
9. **Identity notes:** whether to fix a format for identity in a note now (for example a CAIP-19 identifier for an ERC-8004 agent) or when a principal asks.
10. **Controller keys:** guidance on a long-lived public key per agent against a fresh key per deal or session.
11. **A longer period after spend on several days:** the vault keeps one window's counter, so lengthening a daily limit to a weekly one counts only the last day paid in. After 3 holds on each of two days, a weekly limit of 6 lets 3 more through: 9 in the week (`test_observe_lengthenThePeriodAfterTwoDaysOfSpend_countsOnlyTheLastDay`). There are two ways to close it:
    - document it: set a lower limit for the rest of the week, or pause first;
    - carry conservatively: count the whole lifetime spend since the new window began, which needs a history the vault does not keep.

    Documenting it is recommended.

The repository's visibility is settled: public since 2026-11-19, with secret scanning, push protection, private vulnerability reporting, and a rule on `main` that takes changes only by pull request with both checks passing.
