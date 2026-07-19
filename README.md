# TON Subdomains

Anyone who owns a `.ton` domain or a wallet-owned Telegram Username NFT can open a subdomain registry. Each subdomain is a tradeable **TEP-62 NFT** that resolves on-chain via **TEP-81 DNS**.

`.ton` creators choose one of two explicit guarantees. **Locked** transfers the parent into the
collection and freezes resolution permanently. **Linked** keeps the parent in the owner's wallet,
supports trustless owner claims through a parent NFT round trip, and can explicitly convert one-way
to Locked. Telegram Username parents use Linked only. All contracts are **non-upgradeable** (`embed_code`).

> Written in **Tolk** with the **[Acton](https://github.com/ton-blockchain/acton)** toolchain.

## Architecture

Three tiers, each non-upgradeable:

| Tier | Contract | Role |
|------|----------|------|
| 0 | `SubdomainFactory` | One global, free, permissionless deployer. Derives collections and retains phase-aware recovery state until deployment and custody are positively acknowledged. |
| 1 | `SubdomainCollection` | One per domain. Custody, Linked claims, access policy, immutable pricing, mint and DNS routing. |
| 2 | `SubdomainItem` | One per subdomain. TEP-62 NFT holding DNS records, `dnsresolve`, transfer. |

## How it works

- **Create.** `.ton` supports Locked or Linked. A wallet-owned `.t.me` Username NFT outside an active
  auction uses Linked, so the NFT stays in the wallet and delegates through its `next_resolver` record.
- **Mint.** A label becomes a tradeable TEP-62 NFT. Minting can be public, allowlist-only or
  admin-only, with immutable length-based pricing that may be free.
- **Resolve.** The Collection routes `sha256(label)` to the NFT, which serves its TEP-81 DNS records.
- **Linked ownership.** A new parent owner can claim the Collection by sending the parent through it
  with `0.01 TON`. They become admin, receive available revenue and get the parent back. Linked can
  also convert a `.ton` parent permanently to Locked.
- **Metadata.** The admin can update the off-chain metadata base URI without changing pricing or
  custody.

## Contract specification

See [`SPECS.md`](SPECS.md) for the normative storage layouts, messages, getters, permissions,
economics, DNS behavior, recovery rules and invariants of all three contracts.

## Deployment (mainnet)

| Contract | Deployment | Verified source |
|---|---|---|
| Factory | [`EQAAzQese032pNIO5T-eOxb5bDjdGJ1m0-iutqd86ZH39nXN`](https://tonviewer.com/EQAAzQese032pNIO5T-eOxb5bDjdGJ1m0-iutqd86ZH39nXN) | [TON Verifier](https://verifier.ton.org/UQAAzQese032pNIO5T-eOxb5bDjdGJ1m0-iutqd86ZH39igI) |
| Collection code anchor | [`EQDYIpHPkgxZhEbk6Q9QZdWuqbFdLMJC0fYWfhWJq3hhfIZv`](https://tonviewer.com/EQDYIpHPkgxZhEbk6Q9QZdWuqbFdLMJC0fYWfhWJq3hhfIZv) | [TON Verifier](https://verifier.ton.org/UQDYIpHPkgxZhEbk6Q9QZdWuqbFdLMJC0fYWfhWJq3hhfNuq) |
| Item code anchor | [`EQDVuzqRciQiChoU4ohKbaEAydncY3_WZNWIHnk2si22BOzY`](https://tonviewer.com/EQDVuzqRciQiChoU4ohKbaEAydncY3_WZNWIHnk2si22BOzY) | [TON Verifier](https://verifier.ton.org/UQDVuzqRciQiChoU4ohKbaEAydncY3_WZNWIHnk2si22BLEd) |

The code anchors verify the shared Collection and Item code, not a specific contract state.

Factory deployed on 2026-07-19 in transaction
[`01d89dda…39ce1a`](https://tonscan.org/tx/01d89ddabe281cd3b240be565aff7afc4498025dd41f3b859991c69bfe39ce1a).

## Develop

```bash
acton build
acton test tests
acton check
acton fmt --check
acton script scripts/verify-telemint-fork.tolk --fork-net mainnet --fork-block-number 80702445
```

The frontend dApp lives in a separate repository.

## License

MIT. See [LICENSE](LICENSE).
