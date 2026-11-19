# Crest

Spend controls for AI agents, enforced on chain. Read `README.md`, then `docs/design.md`.

## Hard rules

- **No real money.** Run only on a local chain or a test network. Refuse a mainnet chain ID in any script.
- **Limits are hard or they are not limits.** Every control is checked by contract code in the transaction that commits the money. A limit is proven by an attack test that fails, named after the attack.
- **No power for whoever deploys or relays.** A vault's principal is an argument; the factory and any relayer keep no role. No upgrade proxy; a minimal clone has fixed code.
- **Nothing the vault does can touch money already committed to a venue's terms.** Taking money back stops at a hold.
- **Money** is a token amount in base units. No floats.
- **Secrets** come from environment variables only. Never read or print `.env*`.
- **Contract descriptions live in the interface files** (`src/I*.sol`). Keep every event.
- **No partner, customer or private names** in this repository.

## Working

- Work on a branch, open a pull request, merge by hand when every check has passed. Never `gh pr merge --auto`.
- Label claims in docs and pull requests as measured, documented, inferred or guessed. Plain active English: the state first, then the facts, then the action.
- Deploys to a public test network, and anything sent to other people, wait for the maintainer's word.

```sh
git submodule update --init --recursive
forge test
```
