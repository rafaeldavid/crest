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
- **A new period length keeps the spend of the last window paid in when that window overlaps the new current one,** so changing a limit's period never hands the agent a fresh window. The vault keeps one window's counter, not a history, so a longer period knows only that last window (open, for the maintainer).
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

- **The buyer is the agent's key; the payer is the vault.** The terms name the agent's key as `buyer` and the vault as `buyerPaymentAddress`. The rules contract checks the agent's own agreement; the vault's grant for that key bounds what it may fund.
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

  Each is fixed, and the cross-check's attack tests, which failed before, pass since. One case of the period finding stays open for the maintainer (section 2). Its coverage tests add:
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

## Open, for the maintainer

1. **The vault as the buyer,** so the principal can step in on a funded deal: it needs Holdback's operators to read a contract buyer (Holdback T-227) and narrows Holdback's ADR-0038 rule that a revocation never touches a funded deal.
2. **Gas:** the operators relaying a vault's funding, so agents need no ETH, and Crow paying to create vaults on request (a new request field or route).
3. **The fee:** none now is recommended, with no fee code in any contract.
4. **Grants by signature alone,** so a sub-agent costs no transaction.
5. **A second approver above a threshold,** carried in the funding's signature field.
6. **Depending on third-party code a single address can pause, or under copyleft or source-available licences:** none in the first version.
7. **A trademark search for the name** before any public use.
8. **Deploys to Sepolia,** on the maintainer's word.
9. **Identity notes:** whether to fix a format for identity in a note now (for example a CAIP-19 identifier for an ERC-8004 agent) or when a principal asks.
10. **An identity-following merchant list:** whether an opt-in module may ever approve merchants by agent identity, given that one outside key controls the registries.
11. **Controller keys:** guidance on a long-lived public key per agent against a fresh key per deal or session.
12. **A longer period after spend on several days:** the vault keeps one window's counter, so lengthening a daily limit to a weekly one counts only the last day paid in. After 3 holds on each of two days, a weekly limit of 6 lets 3 more through: 9 in the week (`test_observe_lengthenThePeriodAfterTwoDaysOfSpend_countsOnlyTheLastDay`). There are two ways to close it:
    - document it: set a lower limit for the rest of the week, or pause first;
    - carry conservatively: count the whole lifetime spend since the new window began, which needs a history the vault does not keep.

    Documenting it is recommended.

The repository's visibility is settled: public since 2026-11-19, with secret scanning, push protection, private vulnerability reporting, and a rule on `main` that takes changes only by pull request with both checks passing.
