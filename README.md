# Crest

Spend controls for AI agents, enforced on chain.

A principal's vault holds the money. Each agent, and each agent's short-lived sub-agents, gets a grant with limits no wider than its parent's: the most per deal and per period, a total, how many deals may be open at once, approved merchants tied to their payout addresses, an expiry and a stop. Every payment is checked and counted at every level up to the principal, in the transaction that commits the money, so no agent can spend past any level above it. The principal takes back any money not yet committed and stops any agent at once.

Crest knows how to pay; it knows nothing of what it pays for. A module per venue says what a payment is. The first module pays a hold in Holdback, the escrow behind Crow, whose contracts Crest uses unchanged.

**State:** design and first build, on test networks only. No real money. Not audited.

- `docs/design.md`: the design record and the decisions still open.
- `docs/research/`: the research behind it.
- `src/`: the vault, its factory and the Holdback module, with descriptions in their interface files.
- `test/`: the tests, attack tests included: each limit is proven by an attempt to break it that fails.
- `script/Deploy.s.sol`: deploys the factory and the Holdback module on Sepolia or a local chain, and refuses any other chain. It checks what it deployed and writes `deployments/<chain id>.json`. Deploys wait for the maintainer.

```sh
git submodule update --init --recursive
forge test
CREST_FORK_URL=<sepolia-rpc-url> forge test --match-contract SepoliaForkTest   # the deploy rehearsal on a fork
```
