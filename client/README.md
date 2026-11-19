# Crest's thin client, and the two-model test

State: a test client for a local chain, test tokens only (T-560, stage 1). Crest is unreviewed. Nothing here is deployed.

## vault-buy: an agent buys on Crow and its vault pays

`vault-buy.ts` is the command an agent runs to buy from a seller on Crow with its company's Crest vault paying. The agent's own key is the deal's buyer and signs the agreement. The vault is the payment address and pays the hold through Crest's Holdback module, within the grant the principal gave that key (`docs/design.md`, section 5). A helper key pays the gas; the call carries the agent's signed agreement, so the helper gains nothing.

It borrows Holdback's own buyer tools from a Holdback checkout (`HOLDBACK_ROOT`): the quote, the offer read from every operator, the approval stop, and following the deal to its outcome. Only the funding is its own: a dry run of the module's `agreeAndFund`, which names the limit that refuses, then the call itself. Before each payment it tells the vault about the agent's ended deals (`close`), so their open counts fall.

The agent's page is `docs/pay-through-a-vault.txt`, a draft served to the agents by the test's local web only.

One finding shaped it: Holdback's `buy-with-signer` makes a fresh signing key for every deal, and a grant names one key in advance. So `vault-buy` keeps one long-lived key per agent and copies it into each purchase's key store (`docs/design.md`, open point 11).

## The two-model test

`agents/run.ts` runs the ten scenarios of `agents/scenarios.ts` with one buying agent per purchase: Claude through Anthropic's API, DeepSeek through its OpenAI-compatible API, or a scripted stand-in. The agent loop, the providers, the fenced tools and the record are Holdback's duet harness (`tools/duet`), used as a library. The world (`agents/world.ts`) is anvil with Holdback's own contracts, Crow's operators (the code the live nodes run), Crow's test seller, and Crest's factory and module from this checkout's build. The principal (`agents/principal.ts`) is scripted.

```sh
forge build
HOLDBACK_ROOT=<a built Holdback checkout> node client/agents/run.ts list --buyer claude     # the plan and the most it can cost; sends nothing
HOLDBACK_ROOT=<a built Holdback checkout> node client/agents/run.ts run --buyer scripted   # no keys
```

The Holdback checkout needs `pnpm install`, `pnpm build` and `forge build` in its `contracts/`. A live run reads only the agents' own keys (`HOLDBACK_AGENT_ANTHROPIC_API_KEY`, or `HOLDBACK_AGENT_OPENAI_COMPATIBLE_API_KEY` with `HOLDBACK_AGENT_OPENAI_COMPATIBLE_BASE_URL`), prints the batch's most cost at list prices, and waits 10 s before it sends anything.

Each scenario writes `record.jsonl` (every model turn, tool call, refusal, command and check, with every key scrubbed) and `summary.json` (each check against its expectation, and each purchase's turns, tokens, cost, seconds and gas).
