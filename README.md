# propAMM

Permissioned venues on Tempo where a market maker trades its own inventory with approved takers. There are no
liquidity providers, LP shares or public deposits: the maker funds and owns both sides, and the venue decides who may
trade.

> **Status:** v2 was audited by Sigma Prime ([audits](audits/README.md)) and its core is deployed on Tempo mainnet (see the
> [v2 guide](contracts/src/v2/README.md#deployments)). The managed pool core (`contracts/src/managed`) was audited by
> Sigma Prime and is deployed on Tempo mainnet (see the [managed guide](contracts/src/managed/README.md#deployments));
> each maker creates its own pool from the factory. `DirectPropAMM` and its buffer helper were reviewed by Sigma Prime with
> Earn; the other v1 contracts are unaudited, and there is no supported v1 deployment.
> `Registry` is a separate, unaudited discovery sidecar and is not deployed.

## Deployments

Tempo mainnet (chain ID 4217). Every contract below has verified source, and no deployment left its deployer a role.

| System | Contract | Address |
| --- | --- | --- |
| v2 | VenueFactory | [0x7b71Cd1F47EB6b98fD5aF5167872ce378fc7136b](https://explore.tempo.xyz/address/0x7b71Cd1F47EB6b98fD5aF5167872ce378fc7136b) |
| v2 | Settler | [0xDD683c32d7379a8353b5b23E9a8159A2831F65b6](https://explore.tempo.xyz/address/0xDD683c32d7379a8353b5b23E9a8159A2831F65b6) |
| v2 | Venue implementation | [0xEc207E702C5eEC03b79fb687e82049ed60BF64F3](https://explore.tempo.xyz/address/0xEc207E702C5eEC03b79fb687e82049ed60BF64F3) |
| Managed | PoolFactory | [0x61e5C6b8B737930d07025eC88B34B307F61e162c](https://explore.tempo.xyz/address/0x61e5C6b8B737930d07025eC88B34B307F61e162c) |
| Managed | Settler | [0xf8Ed0Ed4D960f1F400400dA717Aba69708049595](https://explore.tempo.xyz/address/0xf8Ed0Ed4D960f1F400400dA717Aba69708049595) |
| Managed | Pool implementation | [0xa12a02d2917c4EFb4d4BFAf2fCca17c7Ab55215b](https://explore.tempo.xyz/address/0xa12a02d2917c4EFb4d4BFAf2fCca17c7Ab55215b) |
| Price adapter | USDY (Ondo wrapper), 18 decimals | [0xa1e2D13c513907aaa5e771D792D908C98E146766](https://explore.tempo.xyz/address/0xa1e2D13c513907aaa5e771D792D908C98E146766) |
| Price adapter | PRIME (HASTRAPRIME / WYLDS feed), 8 decimals | [0x64672f045089AdDC26b2FE6e3E1D2AD4DAc91A61](https://explore.tempo.xyz/address/0x64672f045089AdDC26b2FE6e3E1D2AD4DAc91A61) |

The two Settlers are different contracts: approve the one for the system you trade on. Records:
[v2](docs/v2-deployment.md#mainnet-deployment), [managed](docs/deployment.md#mainnet-core) and
[price adapters](docs/deployment.md#mainnet-price-adapters). Testnet deployments are in each guide.

## Choose a contract

| | v1 pools | v2 venues |
| --- | --- | --- |
| Contracts | `DirectPropAMM` (one pair per pool) and `ManagedDirectPropAMM` (many pairs per pool) | `Venue` (one per maker, many pairs), `Settler`, `VenueFactory`; optional `Registry` |
| Price | One oracle mid per pair; optional capped fee/policy hooks per pair on `ManagedDirectPropAMM`, none on `DirectPropAMM` | A maker-posted mid and a stepped ladder per side |
| Entry point | The pool, or a shared settlement contract (`Settler`) for factory-created managed pools | One `Settler` for every venue |
| Access | Taker allowlists; `ManagedDirectPropAMM` adds sponsor lists per pair | Per pair: allowlists managed by the maker or admitted businesses (sponsors); a venue-wide deny list overrides them |
| Discovery | Configured addresses or Managed factory events | Permissionless `Registry` (not deployed), or factory events |
| Guide | [v1 guide](contracts/README.md) | [v2 guide](contracts/src/v2/README.md) |

Neither design is upgradeable. This version of `ManagedDirectPropAMM` replaces native fee tables with optional
per-pair fee/policy hooks and requires a new pool deployment. Only the owner selects a hook, while the pair is
closed to swaps. A hook's optional quote callback sets the input-token fee, capped at 10%; without it the fee
is zero. Managed pool administration is owner-only. Custom fee mappings and policy administration belong to the hook. `DirectPropAMM` and v2 are unchanged.

Managed-specific source, tests and scripts live in their own `managed/` directories.
See [Managed routing](contracts/src/managed/README.md) for the factory, caller-based settlement and owner-controlled settler replacement.

## Guides by role

- **Takers and routers:** [swap through the v2 `Settler`](contracts/src/v2/README.md#swapping-taker-or-router), or swap
  a v1 pool directly ([v1 guide](contracts/README.md)). Approve exactly what each swap spends, in the same batch as the
  swap, and never leave a standing allowance on an account with access keys.
- **Makers and updaters:** [set up a v2 venue](contracts/src/v2/README.md#setting-up-a-venue-maker) and
  [post quotes](contracts/src/v2/README.md#quoting-updater), with the [Rust](sdk/rust/README.md) or
  [TypeScript](sdk/ts/README.md) SDK.
- **Sponsors:** [onboard users](contracts/src/v2/README.md#onboarding-users-sponsor) onto a v2 pair. Sponsor lists on
  `ManagedDirectPropAMM` are in the [v1 guide](contracts/README.md).
- **Owners:** pairs, access, inventory and emergency controls are in each guide.
- **Security reviewers:** start from the [audits](#security) and the trust assumptions in each guide.
- **Vault integrators:** the optional Veda buffer for v1 pools is in [docs/veda-integration.md](docs/veda-integration.md).

## SDKs

| SDK | Package | Covers |
| --- | --- | --- |
| [Rust](sdk/rust/README.md) | `propamm-sdk` | v2 makers, owners and sponsors: `Exchange`, `Info`, local pricing and offline `Actions` |
| [TypeScript](sdk/ts/README.md) | `@tempoxyz/propamm-sdk` | v2 makers, owners and sponsors on viem, plus taker reads and local quotes |

Both SDKs use the same names and are held to the same test vectors as the contracts.

## Security

Report vulnerabilities to [security@tempo.xyz](mailto:security@tempo.xyz), not in public issues. Each guide lists its
known limits and risks.

Audits: Sigma Prime reviewed `contracts/src/v2` at commit `459ccf7`; all six findings (low and informational) were
resolved and retested. The final report is v2.0, October 2026.

Sigma Prime reviewed the managed pool core at commit `0569025`: `ManagedDirectPropAMM`, `PoolFactory`, `Settler`
and their four interfaces in `contracts/src/managed`. It found no vulnerabilities; its one informational item
summarizes the review. Routers, hook implementations and vault peripherals were out of scope. The report is v1.0,
November 2026.

Sigma Prime also reviewed the `DirectPropAMM` pool contract and its buffer helper in its PropAMM & Earn review (v2.0, August 2026), listed
with Earn's audits in [tempoxyz/contracts](https://github.com/tempoxyz/contracts/blob/main/docs/earn/audit/README.md);
later changes are not covered by it. The rebalance controller, the oracle adapters and `Registry` have not been
audited. The reports are confidential and shared under NDA through [security@tempo.xyz](mailto:security@tempo.xyz); the
[audits page](audits/README.md) gives their scope and SHA-256 digests.

## Repository

`contracts/` holds the Solidity (Foundry, configured by the root `foundry.toml`), `sdk/rust` the Rust SDK (in the root
Cargo workspace) and `sdk/ts` the TypeScript SDK (its own npm project). Building, testing and releasing are in
[AGENTS.md](AGENTS.md).
