---
"@tempoxyz/propamm-sdk": patch
---

Rejected malformed or zero transaction validity bounds (each supplied bound must be a positive safe-integer number) before wallet requests or cancel-all sequence reservations instead of silently dropping them from signed transactions, and required both bounds or neither unless an explicit valid non-expiring `nonceKey` was selected (viem may otherwise choose expiring nonces and generate random or time-dependent missing bounds), and rejected malformed runtime `nonceKey` values before side effects while preserving viem’s uint256 lanes and `expiring` sentinel, and included validity-preflight refusals in every public write action’s error union.
