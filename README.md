# propAMM

Permissioned venues on Tempo where a market maker trades its own inventory with approved takers. There are no
liquidity providers, LP shares or public deposits: the maker funds and owns both sides, and the venue decides who may
trade.

> **Status:** v2 was audited by Sigma Prime ([audits](audits/README.md)) and its core is deployed on Tempo mainnet (see the
> [v2 guide](contracts/src/v2/README.md#deployments)). The managed pool core (`contracts/src/managed`) was audited by
> Sigma Prime and needs new immutable deployments before use. `DirectPropAMM` was reviewed by Sigma Prime with Earn; the other v1
> contracts are unaudited, and there is no supported v1 deployment.
> `Registry` is a separate, unaudited discovery sidecar and is not deployed.

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

Sigma Prime also reviewed the `DirectPropAMM` pool contract in its PropAMM & Earn review (v2.0, August 2026), listed
with Earn's audits in [tempoxyz/contracts](https://github.com/tempoxyz/contracts/blob/main/docs/earn/audit/README.md);
later changes are not covered by it. The buffer helper, the rebalance controller, the oracle adapters and `Registry`
have not been audited. The reports are confidential and shared under NDA through [security@tempo.xyz](mailto:security@tempo.xyz); the
[audits page](audits/README.md) gives their scope and SHA-256 digests.

## Repository

`contracts/` holds the Solidity (Foundry, configured by the root `foundry.toml`), `sdk/rust` the Rust SDK (in the root
Cargo workspace) and `sdk/ts` the TypeScript SDK (its own npm project). Building, testing and releasing are in
[AGENTS.md](AGENTS.md).
