// In-process sequence allocation for one venue, for a single writer process: the Rust SDK's `Sequencer`, as a state
// value and functions over it (`from` is the Rust `new`).
import { type Address, maxUint32 } from 'viem'
import { venueAbi } from './generated/abis.js'
import * as HotWord from './HotWord.js'
import {
  type GlobalErrorType,
  type InvalidAddressErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  type InvalidHotWordErrorType,
  SequenceExhaustedError,
  type SequenceExhaustedErrorType,
  type SnapshotIncompleteErrorType,
  UnknownPairError,
  type UnknownPairErrorType,
  UnseededPairError,
  type UnseededPairErrorType,
} from './internal/errors.js'
import {
  type MulticallParameters,
  type PinErrorType,
  pin,
  type ReadManyErrorType,
  type ReadParameters,
  readMany,
  readOf,
  readOptions,
  readValue,
} from './internal/read.js'
import type { AnyClient } from './internal/types.js'
import * as validate from './internal/validate.js'

/**
 * A sequence allocator's state: the last sequence it allocated (or was seeded with) for each pair. Make one with
 * {@link from} or {@link seed}, then take every order's and cancel's sequence from {@link next}.
 *
 * Once made, it allocates from memory and never rereads the chain (only {@link seed} reads stored sequences, once), so
 * it can't hand out a number an unmined post of its own already uses, which "read the stored sequence and add one" can.
 * The venue accepts any sequence above the stored one, so gaps are harmless.
 *
 * {@link next} and {@link observe} update the state in place and only ever raise a pair's counter, so everything that
 * holds the state shares one counter and a sequence is never handed out twice: keep one state per venue and pass it
 * around, never a copy. A pair it wasn't made with (one the venue added later, or a market moved to another index)
 * joins it through {@link observe}, at the pair's stored sequence. Every writer to a pair must share it: separate processes, keys or nonce lanes need a shared
 * counter (a database row per pair) instead. Persistence is the caller's responsibility: atomically max-merge each
 * pair's `last` into durable storage, never lowering a floor within its application generation or deleting other pairs. Await its durable commit before
 * broadcasting that allocation. Concurrent snapshot writes can finish out of order: replacing the whole checkpoint
 * with an older snapshot can lose a higher, already broadcast sequence. Serialize checkpoint capture and commit through one writer,
 * or use transactional per-pair maxima; stop or fence the old process against allocation and broadcast before
 * restoring the latest committed checkpoint with {@link seed}. Max-merging storage alone does not coordinate allocators.
 *
 * For a deliberate reset, follow the README's recovery protocol: halt, fence old allocators, durable writes and
 * executable posts (halt does not block posts), then confirm a separate owner `resetHotWord`. Atomically transition
 * only that pair's durable application generation and floor to the confirmed reset state. Bind this idempotent
 * transition to the reset receipt; retries must not clear subsequent allocations. Reject old-generation writes
 * atomically and preserve other pairs. Restore only current-generation floors into a fresh allocator, never the
 * pre-reset checkpoint; `observe` cannot lower it. Neither SDK nor contract carries a reset epoch or fences old posts.
 *
 * @example
 * ```ts
 * import { Sequencer } from '@tempoxyz/propamm-sdk'
 *
 * const sequencer: Sequencer.Sequencer = Sequencer.from([[0, 41]])
 * console.log(Sequencer.next(sequencer, 0)) // 42
 * console.log(Object.fromEntries(sequencer.last)) // { '0': 42 }, a checkpoint
 * ```
 */
export type Sequencer = {
  /** Each seeded pair's last allocated (or seeded) sequence. Read-only: change it with `next` and `observe`. */
  readonly last: ReadonlyMap<number, number>
}

/**
 * Starts an allocator from known last-used sequences, such as a durable checkpoint (the Rust SDK's `Sequencer::new`).
 * Each pair at most once. On restart, include every allocation that could still execute (persist before broadcast),
 * and raise each pair to its stored sequence with {@link observe}, or let {@link seed} merge the checkpoint.
 *
 * @example
 * ```ts
 * import { Sequencer } from '@tempoxyz/propamm-sdk'
 *
 * const fromEntries = Sequencer.from([[0, 41], [5, 7]])
 * const fromRecord = Sequencer.from({ 0: 41, 5: 7 })
 * console.log(Sequencer.next(fromEntries, 5), Sequencer.next(fromRecord, 0)) // 8 42
 * ```
 *
 * @param last - `[pairIndex, sequence]` entries, or a record of them; none by default.
 * @returns A new allocator.
 */
export function from(
  last:
    | Iterable<readonly [number, number]>
    | Readonly<Record<number, number>> = [],
): from.ReturnValue {
  if (typeof last !== 'object' || last === null)
    throw new InvalidArgumentError(
      'last must be [pairIndex, sequence] entries or a record of them',
      { parameter: 'last', value: last },
    )
  const entries: Iterable<readonly [number, number]> =
    Symbol.iterator in last
      ? (last as Iterable<readonly [number, number]>)
      : Object.entries(last).map(([k, v]) => [Number(k), v] as const)
  const counters = new Map<number, number>()
  for (const [pairIndex, sequence] of entries) {
    const pair = validate.pairIndex(pairIndex)
    if (counters.has(pair))
      throw new InvalidArgumentError(`pair ${pair} is given twice`, {
        parameter: 'last',
        value: pair,
      })
    counters.set(pair, validate.uintNumber(sequence, 32, 'sequence'))
  }
  return { last: counters }
}

export declare namespace from {
  /** A new allocator. */
  type ReturnValue = Sequencer
  /** The errors `from` throws. */
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}

/**
 * Starts an allocator from each pair's stored sequence plus `gap` (default 0), read in one multicall at one block,
 * never below that pair's optional `last` checkpoint. `UnknownPairError` for a removed or unknown pair.
 *
 * A fresh process cannot discover unmined allocations from the chain. Stop the old writer and pass a durable `last`
 * checkpoint covering every allocation that could still execute, persisted before broadcasting its post. The floor
 * becomes `max(storedSequence + gap, lastAllocated)`. Without that checkpoint, wait until all earlier posts have
 * landed or can no longer execute, then read the settled chain. A gap is safe only if `storedSequence + gap` is at
 * least the highest potentially executable sequence, NOT merely when it exceeds the number of pending posts.
 * Reusing the same gap across restarts can reuse an unmined sequence.
 *
 * @example
 * ```ts
 * import { Sequencer } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const sequencer = await Sequencer.seed(client, {
 *   venue: '0x1111111111111111111111111111111111111111',
 *   pairs: [0, 1],
 *   // Loaded from durable storage; the old writer has stopped.
 *   last: { 0: 41, 1: 7 },
 * })
 * console.log(Sequencer.next(sequencer, 0))
 * ```
 *
 * @param client - A viem client.
 * @param parameters - The venue, its pairs, the checkpoint, the gap and the read options.
 * @returns A new allocator.
 */
export async function seed(
  client: AnyClient,
  parameters: seed.Parameters,
): Promise<seed.ReturnValue> {
  const venue = validate.address(parameters.venue, 'venue', { nonzero: true })
  const gap = validate.uintNumber(parameters.gap ?? 0, 32, 'gap')
  const checkpoint = from(parameters.last)
  if (!Array.isArray(parameters.pairs))
    throw new InvalidArgumentError('pairs must be an array of pair indexes', {
      parameter: 'pairs',
      value: parameters.pairs,
    })
  const pairs = [
    ...new Set(
      parameters.pairs.map((pairIndex) => validate.pairIndex(pairIndex)),
    ),
  ]
  const options = {
    ...(await pin(client, readOptions(parameters))),
    ...(parameters.multicallAddress === undefined
      ? {}
      : {
          multicallAddress: validate.address(
            parameters.multicallAddress,
            'multicallAddress',
          ),
        }),
  }
  const results = await readMany(
    client,
    pairs.map((pairIndex) => readOf(venue, venueAbi, 'hotWord', [pairIndex])),
    options,
  )
  const updated = pairs.map((pairIndex, i): [number, number] => {
    const word = readValue(
      results[i],
      readOf(venue, venueAbi, 'hotWord', [pairIndex]),
      `hotWord(${pairIndex})`,
    )
    if (BigInt(word) === 0n)
      throw new UnknownPairError(`pair ${pairIndex} is unknown or removed`, {
        pairIndex,
      })
    const sequence = HotWord.decode(word).sequence + gap
    if (sequence > Number(maxUint32))
      throw new SequenceExhaustedError(
        `pair ${pairIndex} has exhausted its sequence numbers`,
        { pairIndex },
      )
    return [pairIndex, Math.max(sequence, checkpoint.last.get(pairIndex) ?? 0)]
  })
  return from(new Map([...checkpoint.last, ...updated]))
}

export declare namespace seed {
  /** The venue, the pairs to seed, the checkpoint, the gap and the read options. */
  type Parameters = ReadParameters &
    MulticallParameters & {
      venue: Address
      pairs: readonly number[]
      /**
       * Durable last-allocated floors, in the same format as `from`. All checkpoint floors are retained; only requested pairs are refreshed from the chain.
       * Within each current application generation, atomically max-merge each pair without deleting other floors; await durable commit before broadcast.
       * Stop or fence the old writer, and use the latest committed checkpoint on restart. See `Sequencer` for the persistence protocol.
       */
      last?:
        | Iterable<readonly [number, number]>
        | Readonly<Record<number, number>>
        | undefined
      /**
       * Added to each stored sequence (default 0). Not a pending-post count: without `last`, the resulting floor
       * must cover the highest sequence that could still execute, including gaps from earlier runs.
       */
      gap?: number | undefined
    }
  /** A new allocator. */
  type ReturnValue = Sequencer
  /** The errors `seed` throws. */
  type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | InvalidHotWordErrorType
    | PinErrorType
    | ReadManyErrorType
    | SequenceExhaustedErrorType
    | SnapshotIncompleteErrorType
    | UnknownPairErrorType
    | GlobalErrorType
}

/**
 * Allocates the pair's next sequence, one above the last, and records it in the state: no two calls on one state ever
 * return the same number. `UnseededPairError` for a pair the state doesn't know (start one with {@link observe} at its
 * stored sequence), `SequenceExhaustedError` past `uint32`.
 *
 * @example
 * ```ts
 * import { Sequencer } from '@tempoxyz/propamm-sdk'
 *
 * const sequencer = Sequencer.from([[0, 1]])
 * const first = Sequencer.next(sequencer, 0)
 * const second = Sequencer.next(sequencer, 0)
 * console.log(first, second) // 2 3
 * ```
 *
 * @param sequencer - The allocator, updated in place.
 * @param pairIndex - The pair.
 * @returns The pair's new sequence.
 */
export function next(
  sequencer: Sequencer,
  pairIndex: number,
): next.ReturnValue {
  const counters = countersOf(sequencer)
  const last = counter(counters, pairIndex)
  if (last >= Number(maxUint32))
    throw new SequenceExhaustedError(
      `pair ${pairIndex} has exhausted its sequence numbers`,
      { pairIndex },
    )
  counters.set(pairIndex, last + 1)
  return last + 1
}

export declare namespace next {
  /** The pair's new sequence. */
  type ReturnValue = number
  /** The errors `next` throws. */
  type ErrorType =
    | InvalidArgumentErrorType
    | SequenceExhaustedErrorType
    | UnseededPairErrorType
    | GlobalErrorType
}

/**
 * Raises the pair's floor after learning of a higher stored sequence, such as an owner's manual post. Never lowers it.
 * A pair the state doesn't know yet starts at `sequence`: observe a new pair's stored sequence once (a pair the venue
 * added, or a market that moved to another index) and {@link next} allocates above it, in the same state.
 *
 * @example
 * ```ts
 * import { Sequencer } from '@tempoxyz/propamm-sdk'
 *
 * const sequencer = Sequencer.from([[0, 5]])
 * Sequencer.observe(sequencer, 0, 9)
 * Sequencer.observe(sequencer, 0, 3) // ignored: never lowers
 * console.log(Sequencer.next(sequencer, 0)) // 10
 *
 * // A pair added after the state was made: start it at its stored sequence.
 * Sequencer.observe(sequencer, 2, 1)
 * console.log(Sequencer.next(sequencer, 2)) // 2
 * ```
 *
 * @param sequencer - The allocator, updated in place.
 * @param pairIndex - The pair.
 * @param sequence - A sequence the venue stores or has stored for the pair.
 */
export function observe(
  sequencer: Sequencer,
  pairIndex: number,
  sequence: number,
): observe.ReturnValue {
  const counters = countersOf(sequencer)
  const pair = validate.pairIndex(pairIndex)
  validate.uintNumber(sequence, 32, 'sequence')
  const last = counters.get(pair)
  if (last === undefined || sequence > last) counters.set(pair, sequence)
}

export declare namespace observe {
  /** Nothing: the state is updated in place. */
  type ReturnValue = undefined
  /** The errors `observe` throws. */
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}

/**
 * The pair's most recently allocated (or seeded) sequence, or undefined for a pair the state doesn't know.
 *
 * @example
 * ```ts
 * import { Sequencer } from '@tempoxyz/propamm-sdk'
 *
 * const sequencer = Sequencer.from([[0, 5]])
 * Sequencer.next(sequencer, 0)
 * console.log(Sequencer.last(sequencer, 0), Sequencer.last(sequencer, 1)) // 6 undefined
 * ```
 *
 * @param sequencer - The allocator.
 * @param pairIndex - The pair.
 * @returns The pair's last sequence, or undefined.
 */
export function last(
  sequencer: Sequencer,
  pairIndex: number,
): last.ReturnValue {
  return countersOf(sequencer).get(validate.pairIndex(pairIndex))
}

export declare namespace last {
  /** The pair's last sequence, or undefined for a pair the state doesn't know. */
  type ReturnValue = number | undefined
  /** The errors `last` throws. */
  type ErrorType = InvalidArgumentErrorType | GlobalErrorType
}

/** The state's counters, writable: only `next` and `observe` write them. */
function countersOf(sequencer: Sequencer): Map<number, number> {
  const counters = (sequencer as { last?: unknown } | null | undefined)?.last
  if (!(counters instanceof Map))
    throw new InvalidArgumentError(
      'not a sequencer: make one with Sequencer.from or Sequencer.seed',
      { parameter: 'sequencer', value: sequencer },
    )
  return counters as Map<number, number>
}

function counter(counters: Map<number, number>, pairIndex: number): number {
  const last = counters.get(validate.pairIndex(pairIndex))
  if (last === undefined)
    throw new UnseededPairError(
      `pair ${pairIndex} was not seeded in the sequencer`,
      { pairIndex },
    )
  return last
}
