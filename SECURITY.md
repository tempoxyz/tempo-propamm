# Security policy

## Reporting a vulnerability

Report vulnerabilities privately by email to [security@tempo.xyz](mailto:security@tempo.xyz). Never
report them in public issues, pull requests, or discussions.

Include:

- the affected contract, script, or SDK, and the commit you tested;
- the impact, such as lost or stranded inventory, a mispriced fill, or broken access control;
- steps or a proof-of-concept test that reproduces it, for example a Foundry test; and
- any deployment or configuration the issue depends on.

Keep the report confidential until we have confirmed a fix and agreed on disclosure with you.

## Scope

In scope:

- the contracts in [`contracts/src/`](contracts/src/): `DirectPropAMM`, managed propAMM
  ([`contracts/src/managed/`](contracts/src/managed/)) and propAMM v2 ([`contracts/src/v2/`](contracts/src/v2/));
- the Rust and TypeScript SDKs in [`sdk/`](sdk/); and
- the deployment and configuration scripts in [`contracts/script/`](contracts/script/).

Out of scope:

- tests, mocks, and fixtures, including every `test/` directory;
- vendored dependencies in `lib/`; and
- external integrations such as Earn and Veda. Report issues in them to their owners. A bug in how
  propAMM integrates with them is in scope.

Each guide documents its trust assumptions and privileged roles. Behavior documented there as trusted
is not a vulnerability by itself.

## Bug bounty

These contracts have no bug bounty.

## Audits

The [audits page](audits/README.md) lists completed audits and what they cover. The reports are confidential; Tempo
shares them under NDA through security@tempo.xyz.
