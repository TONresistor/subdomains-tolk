# TON Subdomains

Permissionless subdomain registries for TON, written in Tolk with [Acton](https://github.com/ton-blockchain/acton).
Project clients support `.ton` domains and collectibles `.t.me` Telegram Username NFTs outside active auctions.
Each subdomain is a transferable TEP-62 NFT with owner-managed TEP-81 DNS records.

## Contracts

| Contract | Role |
|---|---|
| `SubdomainFactory` | Deploys Collections; no admin or protocol fee |
| `SubdomainCollection` | Manages a parent domain, minting, revenue and DNS routing |
| `SubdomainItem` | Subdomain NFT and its DNS records |

All contracts are non-upgradeable. Prices and TEP-64 metadata are fixed at creation.
Minting can be public, allowlist-only or admin-only. NFT royalties are zero.

## Collection modes

| | Linked | Locked |
|---|---|---|
| Parent NFT | Stays in its owner's wallet | Held permanently by Collection |
| DNS link | Parent owner can set or remove it | Collection pins itself as resolver |
| Admin | A new parent owner can claim control | Current admin may transfer the role |
| Conversion | Can become Locked | Final |

Locked creates one Collection per parent; Linked creates one per parent and original creator.
Parent validity still matters: `.ton` requires renewal. When enabled in Locked mode, renewal is
funded by minting or a public call; there is no automatic background service.

See [SPECS.md](SPECS.md) for protocol rules, transaction values and the ABI.

## Deployment (mainnet)

| Contract | Deployment | Verified source |
|---|---|---|
| Factory | [`EQADqpHyfQRvWQGxPqJt6Jyu_c2oqxFZgvfdfxb4UZkCE8R9`](https://tonviewer.com/EQADqpHyfQRvWQGxPqJt6Jyu_c2oqxFZgvfdfxb4UZkCE8R9) | [TON Verifier](https://verifier.ton.org/UQADqpHyfQRvWQGxPqJt6Jyu_c2oqxFZgvfdfxb4UZkCE5m4) |

The verified Factory embeds Collection code hash
`85a44fd403473e5d74575fd606e3aac2873a46e16b944eb68e74b08604397856` and Item code hash
`fafb9b13e3b47c3323023aeb0a9a87277ea5a756886e8a2a6438488dfdf6e349`.

Factory deployed on 2026-07-20 in transaction
[`4676bfe2…1d245c03`](https://tonscan.org/tx/4676bfe277f63a04aa25f8b04408ef1f53ff5b2b6721fcabdaf6ac691d245c03).

## Development

Requires Acton `1.1.0`.

```bash
acton build
acton test tests
acton check
acton fmt --check
```

[CI](.github/workflows/acton.yml) also checks wrappers, coverage, critical mutations and mainnet-fork compatibility.
Deployment and recovery scripts are in [scripts/](scripts/). The frontend is maintained separately.

## License

[MIT](LICENSE).
