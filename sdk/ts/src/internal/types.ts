import type { Account, Chain, Client, Transport } from 'viem'

/** Any viem client: public, wallet or Tempo. Reads need a transport; sends also need an account, on the client or in
 * the parameters. */
export type AnyClient = Client<
  Transport,
  Chain | undefined,
  Account | undefined
>

/** A contract the SDK knows: one a call targets (`PreparedCall.contract`) or one that declares a revert
 * (`Errors.Decoded.contracts`). The SDK builds no call to the Settler, but decodes its errors. */
export type ContractName = 'Settler' | 'TIP20' | 'Venue' | 'VenueFactory'
