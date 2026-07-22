# TON Subdomains

Anyone who owns a `.ton` domain or a wallet-owned Telegram Username NFT can open a subdomain registry. Each subdomain is a tradeable **TEP-62 NFT** that resolves on-chain via **TEP-81 DNS**.

Creators choose one of two explicit guarantees. **Locked** transfers the parent NFT into the
collection and freezes resolution permanently. **Linked** keeps the parent in the owner's wallet,
supports trustless owner claims through a parent NFT round trip, and can explicitly convert one-way to Locked. All contracts are **non-upgradeable** (`embed_code`).

> Written in **Tolk** with the **[Acton](https://github.com/ton-blockchain/acton)** toolchain.

## Architecture

Three tiers, each non-upgradeable:

| Tier | Contract | Role |
|------|----------|------|
| 0 | `SubdomainFactory` | Global permissionless deployer and recovery coordinator. |
| 1 | `SubdomainCollection` | One Locked per parent; Linked per parent and creator. Manages custody, minting, revenue and DNS. |
| 2 | `SubdomainItem` | One transferable NFT per subdomain with editable DNS records. |

## How it works

- **Create.** `.ton` and `.t.me` parents support Locked or Linked. Locked keeps the parent in the
  Collection permanently. Linked keeps it in the owner's wallet and uses its `next_resolver` record.
- **Mint.** A label becomes a tradeable TEP-62 NFT. Minting can be public, allowlist-only or
  admin-only, with immutable length-based pricing that may be free.
- **Resolve.** The Collection routes `sha256(label)` to the NFT, which serves its TEP-81 DNS records.
- **Linked ownership.** A new parent owner can claim the Collection by sending the parent through it
  with `0.01 TON`. They become admin, receive available revenue and get the parent back. Linked can
  also convert permanently to Locked.
- **Renewal.** Locked `.ton` collections renew their parent when needed. Telegram Username NFTs do
  not expire, so Locked `.t.me` collections never send a renewal heartbeat.
- **Metadata.** Each Collection and Item stores complete immutable TEP-64 metadata. Text and
  attributes are on-chain; `image` and `uri` may use any URI chosen by the creating client.

## Contract specification

See [`SPECS.md`](SPECS.md) for protocol behavior, ABI opcodes and transaction values.

## Deployment (mainnet)

| Contract | Deployment | Verified source |
|---|---|---|
| Factory | [`EQADqpHyfQRvWQGxPqJt6Jyu_c2oqxFZgvfdfxb4UZkCE8R9`](https://tonviewer.com/EQADqpHyfQRvWQGxPqJt6Jyu_c2oqxFZgvfdfxb4UZkCE8R9) | [TON Verifier](https://verifier.ton.org/UQADqpHyfQRvWQGxPqJt6Jyu_c2oqxFZgvfdfxb4UZkCE5m4) |

The verified Factory embeds Collection code hash
`85a44fd403473e5d74575fd606e3aac2873a46e16b944eb68e74b08604397856` and Item code hash
`fafb9b13e3b47c3323023aeb0a9a87277ea5a756886e8a2a6438488dfdf6e349`.

Factory deployed on 2026-07-20 in transaction
[`4676bfe2…1d245c03`](https://tonscan.org/tx/4676bfe277f63a04aa25f8b04408ef1f53ff5b2b6721fcabdaf6ac691d245c03).

## Develop

```bash
acton build
acton test tests
acton check
acton fmt --check
```

The frontend dApp lives in a separate repository.

## License

MIT. See [LICENSE](LICENSE).
