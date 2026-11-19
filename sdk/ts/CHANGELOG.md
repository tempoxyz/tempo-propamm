# @tempoxyz/propamm-sdk

## 0.2.0

### Minor Changes

- 044d8e6: Removed the retired curated Registry ABI, constants, actions, listing read, signer roles and event/error decoding.
  
  ```diff
  - Actions.registry
  - Info.listing
  - Registry
  - Abis.registryAbi
  - RegistryAbi, RegistryCall
  - propAmmActions().registry
  ```
  
  Before upgrading, remove the old curated Registry discovery and administration calls; the retired SDK APIs have no compatibility wrappers. The new permissionless contract is also named `Registry`, but has a different ABI: it pages venue addresses, not curated pair listings. This SDK adds no replacement Registry APIs. Use factory events for discovery until a new Registry is deployed, or integrate its ABI directly once deployed.

### Patch Changes

- 044d8e6: Rejected out-of-domain venue pair counts with UnexpectedResponseError before allocating arrays or issuing pair reads.
- 044d8e6: Bounded revert-data traversal for viem errors to prevent stack overflows on deep or cyclic RPC causes.
- 044d8e6: Pinned cancel-all discovery reads to one canonical block hash and rejected reorged or unsupported reads before allocating sequences or sending cancellations.
- 044d8e6: Checked multicall results against the expected contract and arguments before decoding them.
- 044d8e6: Rejected missing or ambiguous internal write ABI bindings with a typed error.
- 044d8e6: Preserved explicit gas-estimation fees on customized Tempo chains with copied formatters or wrapped serializers.
- 044d8e6: Clarified the atomic, monotonic checkpoint persistence protocol required before broadcasting allocated sequences.
- 044d8e6: Accepted uppercase and mixed-case Posted and HotWordReset event selectors while preserving strict malformed-log rejection.
- 044d8e6: Kept synchronous action receipts pending until both block number and block hash were present, without deriving events or post outcomes before inclusion.
- 044d8e6: Preserved explicit fee fields in Tempo gas estimates so fee-cap checks use the intended transaction fees.
- 044d8e6: Preserved aggregate multicall failures instead of misclassifying aborted requests and malformed aggregate responses as unknown venues.
- 044d8e6: Preserved the selected block and state overrides when estimating gas with a local account.
- 044d8e6: Rejected undecodable venue UpdaterSet and DenyUpdated receipt logs instead of reporting access changes as no-ops.
- 044d8e6: Rejected malformed Posted and HotWordReset logs from matching venues instead of silently treating posts as skipped or overlooking reset ambiguity. Ignored unrelated addresses and event signatures.
- 044d8e6: Rejected malformed second ladder words in local quotes instead of discarding them before validation.
- 044d8e6: Reject explicit null values in optional order fields instead of silently applying defaults. Omitted and undefined fields retain their defaults.
- 044d8e6: Rejected sparse ladder arrays at each missing level instead of returning noncanonical shape words.
- 044d8e6: Rejected undecodable venue HaltedSet receipt logs instead of reporting the halt state as unchanged.
- 044d8e6: Rejected TIP-1022 virtual settler addresses before preparing venue writes.
- 044d8e6: Rejected the zero address in role pre-flight checks instead of treating vacant role slots as valid senders.
- 044d8e6: Reserved manual `cancelAll.requests` sequences in the shared sequencer before returning, preventing subsequent posts from reusing them.
- 044d8e6: Added durable last-allocated checkpoint floors to Sequencer.seed and corrected restart guidance to prevent reuse of in-flight sequences.
- 044d8e6: Rejected RPC-prepared transactions that changed the configured signing chain or an explicitly requested nonce lane before local signing.
- 044d8e6: Rejected malformed Fill logs instead of silently returning incomplete fill history.
- 044d8e6: Rejected invalid cancellation mid-band responses and validated the entire cancel batch before reserving sequences.
- 044d8e6: Validated block overrides before reading, rejecting malformed or unknown fields instead of silently omitting them from RPC calls and returning a mismatched snapshot context.
- 044d8e6: Rejected malformed or zero transaction validity bounds (each supplied bound must be a positive safe-integer number) before wallet requests or cancel-all sequence reservations instead of silently dropping them from signed transactions, and required both bounds or neither unless an explicit valid non-expiring `nonceKey` was selected (viem may otherwise choose expiring nonces and generate random or time-dependent missing bounds), and rejected malformed runtime `nonceKey` values before side effects while preserving viem’s uint256 lanes and `expiring` sentinel, and included validity-preflight refusals in every public write action’s error union.

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
