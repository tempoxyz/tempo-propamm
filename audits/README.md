# Audits

[Sigma Prime](https://sigmaprime.io) completed two security reviews of propAMM. The finalized reports are
confidential; Tempo shares them under NDA (request them through
[security@tempo.xyz](mailto:security@tempo.xyz)). Each report is authoritative for its own scope.

| Report                  | Auditor     | Version | Date          | Commit    |
| ----------------------- | ----------- | ------- | ------------- | --------- |
| PropAMM V2              | Sigma Prime | 2.0     | October 2026  | `459ccf7` |
| Managed PropAMM         | Sigma Prime | 1.0     | November 2026 | `0569025` |

## PropAMM V2

The scope was `contracts/src/v2`. All six findings (low and informational) were resolved and retested.
The `Registry` discovery sidecar was added later and is not covered.

## Managed PropAMM

The scope was the managed pool core in `contracts/src/managed`: `ManagedDirectPropAMM`, `PoolFactory`,
`Settler` and their four interfaces. Sigma Prime found no vulnerabilities; its one informational item
summarizes the review. Routers, hook implementations and vault peripherals were out of scope.

## Not covered

Each report covers its listed components at the commit it reviewed; later changes are not covered by
it. Neither of these two reports covers `DirectPropAMM` or the buffer helper (see below), the rebalance controller, the oracle
adapters, `Registry`, or the Rust and TypeScript SDKs.

## DirectPropAMM

Sigma Prime reviewed the `DirectPropAMM` pool contract and `DirectPropAMMBufferHelper` as part of its PropAMM & Earn review (v2.0,
August 2026), which is listed with Earn's audits in
[tempoxyz/contracts](https://github.com/tempoxyz/contracts/blob/main/docs/earn/audit/README.md) and
shared the same way. Changes after that review are not covered. That review did not cover the oracle
adapters or the rebalance controller used with a DirectPropAMM pool.

## Verifying a copy

Recipients can check a report against these SHA-256 digests:

| File                                                                       | SHA-256                                                            |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `Sigma_Prime_Tempo_PropAMM_V2_Security_Assessment_Report_v2_0.pdf`        | `1d153ea60028905784cfbf887a3c40c48320a9a5bed6520f123264364bdb228b` |
| `Sigma_Prime_Tempo_Managed_PropAMM_Security_Assessment_Report_v1_0.pdf`   | `5564e1feea4d8d124a24fde0e2c67710f9dc5184cadde58be7568472b81294d9` |
