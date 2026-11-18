---
"@tempoxyz/propamm-sdk": major
---

Removed the retired curated Registry ABI, constants, actions, listing read, signer roles and event/error decoding.

```diff
- Actions.registry
- Info.listing
- Registry
- Abis.registryAbi
- RegistryAbi, RegistryCall
- propAmmActions().registry
```

Before upgrading, remove the old curated Registry discovery and administration calls; the retired SDK APIs have no compatibility wrappers. The new permissionless contract is also named `Registry`, but has a different ABI: it pages venue addresses, not curated pair listings. This SDK adds no replacement Registry APIs. Use factory events for discovery until a new Registry is deployed, or integrate its ABI directly once deployed.
