# Crest

Spend controls for AI agents, enforced on chain.

An owner's vault holds the money. Each agent, and each agent's short-lived sub-agents, gets a grant with limits no wider than its parent's: the most per deal and per period, a total, how many deals may be open at once, approved merchants tied to their payout addresses, an expiry and a stop. Every payment is checked and counted at every level up to the owner, in the transaction that commits the money, so no agent can spend past any level above it. The owner takes back any money not yet committed and stops any agent at once.

Crest knows how to pay; it knows nothing of what it pays for. A module per venue says what a payment is. The first module pays a hold in Holdback, the escrow behind Crow, whose contracts Crest uses unchanged.

**State:** design and first build, on test networks only. No real money. Not audited.

- `docs/design.md`: the design record and the decisions still open.
- `docs/research/`: the research behind it.
- `src/`: the vault, its factory and the Holdback module, with descriptions in their interface files.
- `test/`: the tests, attack tests included: each limit is proven by an attempt to break it that fails.

```sh
git submodule update --init --recursive
forge test
```
