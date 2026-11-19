# Crest design record 0001: the vault, its grants, child vaults, the factory and the Holdback module

- **Status:** Accepted, 2026-11-19, for the decisions under "Decided"; the points under "Open" are the owner's.
- **Origin:** Crow's task T-554 and roadmap row N204. Holdback's side is its ADR-0041 and decision D84: Holdback changes nothing and sees only a payment address that funds a hold.
- **Labels:** **measured** (run or read as cited), **documented** (a published source says it), **inferred**, **guessed**.

## Summary

1. **One vault per owner holds the money and a tree of grants.** The owner holds the root. Each agent gets a grant, and an agent allowed to delegate gives its sub-agents grants of their own. Every payment is checked and counted at its grant and at every grant above it, in the transaction that commits the money.
2. **A grant's controller can also create a child vault** for a sub-agent: its own address and its own money, filled from the parent within the grant's limits. Its payments still answer to the parent's stops, expiries, per-payment limits and approved merchants, and everything above it can take the money back.
3. **The vault pays only through modules the owner enabled, each to the one payee the owner pinned for it.** The vault approves exactly one token authorization, the one it builds itself for the payment it has just checked, and only for the rest of that transaction.
4. **The Holdback module is the first venue.** It exposes Holdback's own `agreeAndFund`, reads the deal's terms, has the vault charge the buyer's grant, and forwards the call unchanged. Holdback's contracts are unchanged.
5. **Nobody who deploys or relays gains any power.** A vault is a fixed minimal clone, its owner is an argument, and the factory keeps no role.

## Context

### What the owner asked for

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
| `CrestVault` | the owner, the token, the grants, the limits and counters, the child vaults, the enabled modules and the payee each may pay | read a venue's state or terms |
| `CrestFactory` | the vault's code | keep any role in a vault it created |
| `HoldbackModule` | Holdback's terms, its payment record and its deal stages | hold tokens or state |

A second venue is a second module; the vault does not change.

### 2. The grants

- **A grant** names its parent, its controller (one key), its limits and its state. The owner controls the root. A key controls at most one grant in a vault.
- **The limits:** the most one payment may be; the most a period's payments may add up to, with the period's length in seconds (86,400 for a UTC day); the most the grant may ever pay; how many commitments may be open at once; an expiry; whether the controller may grant children or create child vaults. The largest value of each type means no limit of that kind. An allow list, when the grant is restricted, names the counterparties it may pay.
- **Every payment charges the grant and every grant above it,** checking each one's state, expiry, limits and list, and adding to each one's counters. One refusal reverts the payment, and nothing is counted.
- **A child granted wider limits than its parent is still bound** by the parent at payment time, so the vault never compares limits when a grant is made.
- **Who may do what.** The owner withdraws, enables modules and acts on any grant. A controller above a grant may stop it, resume it, set its limits and list its counterparties. A grant's own controller may stop itself and, when allowed, grant children; it may never widen or resume its own grant.
- **Periods are fixed windows** (`floor(time / period)`), with no carry-over. A refund does not give a period's limit back: the counters are gross, and the refunded money returns to the vault.
- **Open commitments are counted, not their total.** The total at risk is already bounded by the count times the per-payment limit. The module that opened a commitment releases it when the venue says it has ended; anyone may ask it to.

### 3. Child vaults

- **Created through the parent:** the controller of a grant that may delegate asks its vault to create a child vault. The child's owner is that controller; its parent is the vault, and its parent grant is that grant.
- **Filled through the parent:** the parent's controller moves money into the child. The move is charged to the grant's path for its period and total limits, like a payment; it opens no commitment.
- **Bound from above:** each payment from a child is checked against the parent grant's path for its state, expiry, per-payment limit and approved counterparties, through the whole chain of parents. A stop anywhere above stops the child at once.
- **Modules come from the top:** a child pays only through modules enabled at the top vault, to the payees pinned there. A child's owner cannot enable a module.
- **Money goes back up only:** a child sends money to its parent vault and nowhere else. Its owner, and anyone with authority over the parent grant, can send it back.

### 4. Payments

- **A module asks the vault to charge.** The vault checks the module is enabled, charges the path, records the commitment, and approves exactly one ERC-3009 `ReceiveWithAuthorization`: from the vault, to the module's pinned payee, for exactly the charged amount, with the module's nonce and deadline. It holds that approval in transient storage for the rest of the transaction.
- **The vault answers ERC-1271 to the token only,** and only for that digest. It answers no one else, so an agent's own signature never moves the vault's money.
- **Nothing reaches a funded hold.** A hold sits in the venue's escrow; the vault has no function that calls the venue except the escrow's own payer-only `reclaim` after the escrow's expiry, which can only return money to the vault.

### 5. The Holdback module

- **The buyer is the agent's key; the payer is the vault.** The terms name the agent's key as `buyer` and the vault as `buyerPaymentAddress`. The rules contract checks the agent's own agreement; the vault's grant for that key bounds what it may fund.
- **The counterparty** is the deal's payout address together with its three adjudicators, so an owner approves a merchant and the adjudicators it accepts in one entry. A hold pays out only to the terms' payout address or back to the payer (Holdback, `HoldbackRules.sol:400`) [measured], so the approved-merchant list holds through the escrow.
- **The amount** is the hold: price plus the adjudication fee. Operator fees are not paid through the module; the pilots' fee is 0.
- **Open deals end** when the rules contract's stage is Released, Refunded or Settled, or the escrow's expiry has passed.
- **One module per Holdback rules deployment.** After a redeploy the owner enables the new module with one transaction.

### 6. The factory

- **Each vault is a minimal clone** of one implementation, at an address that follows from the owner, the token and a salt. Anyone may create it and pay the gas; the creator gets nothing. A second creation returns the existing vault.
- **The implementation and the factory** deploy once per chain.

### 7. Neutrality and the hold

No owner, controller, module or factory can stop a funded deal from settling by its terms or move a hold. Before funding, a limit or a stop only declines to pay, as any buyer may. After funding, the owner can stop its agent and take back everything not in a hold, and Holdback's own timeouts return every hold. A Crest vault is the owner's own wallet, not a settlement contract: its owner has over it what any key has over its own balance.

### 8. What the tests must show failing

For each control, an attempt to break it that fails: a payment over each limit at the grant and at each ancestor; a wider child; siblings that together pass their parent; an unlisted counterparty at any level; after a stop at any level; an expired grant; a controller widening or resuming itself; a stranger or an agent withdrawing, enabling a module or granting; a module not enabled; a payee other than the pinned one; a commitment opened or released twice; a failed venue call after a charge (nothing counted); the approval used twice or asked by a caller that is not the token; the period boundary; a child vault paying past its parent's stop, expiry, per-payment limit or list; a child sending money anywhere but up; a Holdback funding sent straight to the rules contract for a vault-paid deal; and the owner emptying the vault after a funding while the deal still settles.

## Open, for the owner

1. **The vault as the buyer,** so the owner can step in on a funded deal: it needs Holdback's operators to read a contract buyer (Holdback T-227) and narrows Holdback's ADR-0038 rule that a revocation never touches a funded deal.
2. **Gas:** the operators relaying a vault's funding, so agents need no ETH, and Crow paying to create vaults on request (a new request field or route).
3. **The fee:** none now is recommended, with no fee code in any contract.
4. **Grants by signature alone,** so a sub-agent costs no transaction.
5. **A second approver above a threshold,** carried in the funding's signature field.
6. **Depending on third-party code a single address can pause, or under copyleft or source-available licences:** none in the first version.
7. **A trademark search for the name** before any public use.
8. **Deploys to Sepolia,** on the owner's word.
9. **GitHub Pro or a public repository,** for secret scanning with push protection and a rule that requires a pull request and both checks on `main`. GitHub Free offers neither on a private repository [measured, 2026-11-19: HTTP 422 and 403].
