# @tempoxyz/propamm-sdk

## 0.1.1

### Patch Changes

- d1bb8d6: Copied decoded shape words defensively and rejected invalid consumed depths before walking book ladders.

## 0.1.0

### Minor Changes

- bf03177: Added the TypeScript maker SDK for propAMM v2: viem/tempo-style actions (with `call`, which viem's `simulateContract`
  and `estimateContractGas` take as it is, `extractEvent` and `<name>Sync`) and a `propAmmActions()` client decorator,
  reads at one block, an atomic batch simulator, bit-exact ladder math and encodings in ox-style modules, and one error
  class per kind of mistake.
- abf8872: Added owner-only hot-word recovery actions, reset-event decoding and sequencer restart guidance, and refused ambiguous post-outcome attribution when a receipt resets a pair it also attributes.
  
  ```diff
  - const outcomes = PostOutcome.fromBatch(calls, receipt.logs)
  + // Send resetHotWord in a previous transaction, then attribute fresh posts.
  + const outcomes = PostOutcome.fromBatch(calls, receipt.logs)
  ```
- b50b27c: Reported idempotent venue access writes from `*Sync` without requiring an event, with explicit changed-state results and factory-verified eventless targets instead of mutable end-of-block state.
  
  ```diff
  - if (result.status === 'success') console.log(result.halted)
  + if (result.status === 'success' && result.changed) console.log(result.halted)
  ```

### Patch Changes

- ffedbe1: Added named venue ownership and sponsor-admin transfer cancellation actions, restoring nonzero nominees for transfer
  proposals.
  
  ```diff
  - await Actions.venue.transferSponsorAdmin(client, { venue, sponsorId, newAdmin: zeroAddress })
  + await Actions.venue.cancelSponsorAdminTransfer(client, { venue, sponsorId })
  ```
- b50b27c: Confirmed eventless access writes against venue state at the receipt block before reporting a no-op, rejecting empty or mismatched replies.
- 39a8585: Added `Fees.takerFields` to build and validate the fee fields a capped taker reuses for simulation and submission.
