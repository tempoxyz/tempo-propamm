// The `*Sync` step every `post` write shares (`Actions.venue.post` and `Actions.maker`'s orders and cancels): a stale
// entry succeeds without an event, so the result reports which entries the venue stored, from the receipt's logs.
import type { Account, Chain, Client, Transport } from 'viem'
import { venueAbi } from '../../generated/abis.js'
import * as PostOutcome from '../../PostOutcome.js'
import type { VenueAbi, VenueCall } from './abis.js'
import {
  type EventArgs,
  extractEvents,
  type SyncReturnValue,
  sendSync,
  type WriteParameters,
} from './define.js'

/** What a `post` write's `*Sync` returns, keyed on its receipt's `status` (`SyncReturnValue`). */
export type PostSyncReturnValue = SyncReturnValue<{
  /** Each `Posted` event's arguments at the venue, in order: one per entry it stored. */
  posted: EventArgs<VenueAbi, 'Posted'>[]
  /** Which entries the venue stored and which it skipped as stale (`PostOutcome.fromLogs`). */
  outcome: PostOutcome.PostOutcome
}>

/**
 * @internal Sends a `post` call, waits for its receipt and matches its entries against its venue's `Posted` events. A
 * pending receipt carries no logs yet, and a reverted one none at all: neither says an entry was skipped, so the result
 * is that receipt alone.
 */
export async function sendPost<
  chain extends Chain | undefined,
  account extends Account | undefined,
>(
  client: Client<Transport, chain, account>,
  parameters: WriteParameters<chain, account>,
  call: VenueCall<'post'>,
): Promise<PostSyncReturnValue> {
  return sendSync(client, parameters, call, (logs, options) => ({
    posted: extractEvents(venueAbi, 'Posted', logs, options).map(
      (log) => log.args,
    ),
    outcome: PostOutcome.fromLogs(call, logs),
  }))
}
