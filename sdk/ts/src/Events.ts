// Decodes the logs of the SDK's contracts: the venue's, the factory's, TIP-20's events, as one union
// typed from their ABIs, so `eventName` narrows `args`.
import {
  type Abi,
  type AbiEvent,
  type Address,
  type ContractEventName,
  type GetEventArgs,
  getAddress,
  type Log,
  type ParseEventLogsErrorType,
  parseEventLogs,
} from 'viem'
import { Abis } from 'viem/tempo'
import { venueAbi, venueFactoryAbi } from './generated/abis.js'
import { signature } from './internal/abi.js'
import {
  type GlobalErrorType,
  type InvalidAddressErrorType,
  InvalidArgumentError,
  type InvalidArgumentErrorType,
  show,
} from './internal/errors.js'
import * as validate from './internal/validate.js'

/** One ABI's decoded events, a variant per event. */
type Of<
  abi extends Abi,
  name extends ContractEventName<abi> = ContractEventName<abi>,
> = {
  [eventName in name]: {
    /** The emitting contract, checksummed. */
    address: Address
    /** The event's name, which narrows `args`. */
    eventName: eventName
    /** The event's arguments, every one present. */
    args: GetEventArgs<abi, eventName, { IndexedOnly: false; Required: true }>
    /** The log it came from: block, transaction, log index, and `removed` for reorg handling. */
    log: Log
  }
}[name]

/** The name of every event the SDK decodes. */
export type EventName =
  | ContractEventName<typeof venueAbi>
  | ContractEventName<typeof venueFactoryAbi>
  | ContractEventName<typeof Abis.tip20>

/** The name of every venue event. */
export type VenueEventName = ContractEventName<typeof venueAbi>

/** A decoded event: one variant per event the SDK decodes, narrowed by `eventName` (all of them by default). */
export type Event<name extends EventName = EventName> = Extract<
  Of<typeof venueAbi> | Of<typeof venueFactoryAbi> | Of<typeof Abis.tip20>,
  { eventName: name }
>

/** A decoded venue event (`Posted`, `Refilled`, `ShapeSet`, `Fill`, the access and admin events). */
export type VenueEvent<name extends VenueEventName = VenueEventName> = Extract<
  Of<typeof venueAbi>,
  { eventName: name }
>

/** Every event the SDK decodes (the venue's, the factory's, TIP-20's), each signature once. The
 * Settler emits none. */
export const allEventsAbi: readonly AbiEvent[] = (() => {
  const seen = new Set<string>()
  const out: AbiEvent[] = []
  for (const abi of [
    venueAbi,
    venueFactoryAbi,
    Abis.tip20,
  ] as readonly (readonly { type: string }[])[]) {
    for (const item of abi) {
      if (item.type !== 'event') continue
      const sig = signature(item as AbiEvent)
      if (seen.has(sig)) continue
      seen.add(sig)
      out.push(item as AbiEvent)
    }
  }
  return out
})()

const eventNames: ReadonlySet<string> = new Set(allEventsAbi.map((e) => e.name))
const venueEventNames: ReadonlySet<string> = new Set(
  venueAbi.flatMap((item) => (item.type === 'event' ? [item.name] : [])),
)

/**
 * Decodes the logs the SDK knows, optionally only those from `address` or named `eventName`, and skips the rest.
 *
 * @example
 * ```ts
 * import { Events } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { getTransactionReceipt } from 'viem/actions'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const receipt = await getTransactionReceipt(client, { hash: '0x...' })
 *
 * for (const event of Events.parse(receipt.logs, { eventName: ['Posted', 'Refilled'] }))
 *   if (event.eventName === 'Posted') console.log(event.args.pairIndex, event.args.hotWord)
 * ```
 *
 * @param logs - Logs, such as a receipt's.
 * @param options - The emitter and event names to keep.
 * @returns The decoded events, in log order.
 */
export function parse<const name extends EventName = EventName>(
  logs: readonly Log[],
  options: parse.Options<name> = {},
): parse.ReturnValue<name> {
  checkLogs(logs)
  if (typeof options !== 'object' || options === null)
    throw new InvalidArgumentError('options must be an object', {
      parameter: 'options',
      value: options,
    })
  const names = namesOf(options.eventName, eventNames, 'SDK')
  const address =
    options.address === undefined
      ? undefined
      : validate.address(options.address, 'address')
  const out: Event<name>[] = []
  for (const log of parseEventLogs({
    abi: allEventsAbi,
    logs: logs as Log[],
    strict: true,
  })) {
    const emitter = getAddress(log.address)
    if (address && emitter !== address) continue
    if (names && !names.has(log.eventName)) continue
    out.push({
      address: emitter,
      eventName: log.eventName,
      args: log.args,
      log,
    } as unknown as Event<name>)
  }
  return out
}

export declare namespace parse {
  /** The emitter and event names to keep. */
  type Options<name extends EventName = EventName> = {
    /** Only this contract's logs. */
    address?: Address | undefined
    /** Only these events. */
    eventName?: name | readonly name[] | undefined
  }
  /** The decoded events, in log order. */
  type ReturnValue<name extends EventName = EventName> = Event<name>[]
  /** The errors `parse` throws: logs or options that aren't ones, an event name the SDK doesn't decode, an address that
   * isn't one, and viem's for the decode. */
  type ErrorType =
    | InvalidAddressErrorType
    | InvalidArgumentErrorType
    | ParseEventLogsErrorType
    | GlobalErrorType
}

/**
 * Decodes only `venue`'s own events, optionally only those named `eventName`.
 *
 * @example
 * ```ts
 * import { Events } from '@tempoxyz/propamm-sdk'
 * import { createClient, http } from 'viem'
 * import { getTransactionReceipt } from 'viem/actions'
 * import { tempoModerato } from 'viem/chains'
 *
 * const client = createClient({ chain: tempoModerato, transport: http() })
 * const receipt = await getTransactionReceipt(client, { hash: '0x...' })
 *
 * const [fill] = Events.venue(receipt.logs, { venue: '0x...', eventName: 'Fill' })
 * if (fill) console.log(fill.args.amountIn, fill.args.amountOut)
 * ```
 *
 * @param logs - Logs, such as a receipt's.
 * @param options - The venue, and the event names to keep.
 * @returns The venue's decoded events, in log order.
 */
export function venue<const name extends VenueEventName = VenueEventName>(
  logs: readonly Log[],
  options: venue.Options<name>,
): venue.ReturnValue<name> {
  if (typeof options !== 'object' || options === null)
    throw new InvalidArgumentError('options must be an object', {
      parameter: 'options',
      value: options,
    })
  const names =
    namesOf(options.eventName, venueEventNames, 'venue') ?? venueEventNames
  return parse(logs, {
    address: validate.address(options.venue, 'venue'),
  }).filter((e) => names.has(e.eventName)) as unknown as VenueEvent<name>[]
}

export declare namespace venue {
  /** The venue, and the event names to keep. */
  type Options<name extends VenueEventName = VenueEventName> = {
    /** The venue. */
    venue: Address
    /** Only these events. */
    eventName?: name | readonly name[] | undefined
  }
  /** The venue's decoded events, in log order. */
  type ReturnValue<name extends VenueEventName = VenueEventName> =
    VenueEvent<name>[]
  /** The errors `venue` throws: `parse`'s. */
  type ErrorType = parse.ErrorType
}

/** Refuses anything but an array of logs, each with topics and an address. */
function checkLogs(logs: readonly Log[]): void {
  if (!Array.isArray(logs))
    throw new InvalidArgumentError('logs must be an array of logs', {
      parameter: 'logs',
      value: logs,
    })
  logs.forEach((log: unknown, i) => {
    const entry = log as { topics?: unknown; address?: unknown } | null
    if (
      typeof entry !== 'object' ||
      entry === null ||
      !Array.isArray(entry.topics)
    )
      throw new InvalidArgumentError(`logs[${i}] is not a log`, {
        parameter: `logs[${i}]`,
        value: log,
      })
    validate.address(entry.address as Address, `logs[${i}].address`)
  })
}

/** The event names asked for, each one the SDK decodes, or undefined for all of them. */
function namesOf(
  eventName: string | readonly string[] | undefined,
  known: ReadonlySet<string>,
  what: string,
): ReadonlySet<string> | undefined {
  if (eventName === undefined) return undefined
  const list = typeof eventName === 'string' ? [eventName] : eventName
  if (!Array.isArray(list))
    throw new InvalidArgumentError(
      'eventName must be an event name or an array of them',
      { parameter: 'eventName', value: eventName },
    )
  for (const name of list)
    if (typeof name !== 'string' || !known.has(name))
      throw new InvalidArgumentError(
        `no ${what} event is named ${show(name)}`,
        {
          parameter: 'eventName',
          value: name,
        },
      )
  return new Set(list)
}
