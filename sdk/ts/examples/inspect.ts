// Reads one venue at one block and prints each pair's book and a quote: read-only, no key. Parity with
// sdk/rust/examples/inspect.rs. Supply a deployment you verified; the SDK presets no v2 address.
//
//   RPC_URL=... VENUE=0x... FACTORY=0x... node examples/inspect.ts

import { Book, Info, Price, Quote, Snapshot } from '@tempoxyz/propamm-sdk'
import { createClient, http } from 'viem'
import { tempoModerato } from 'viem/chains'

const env = (name: string) => {
  const value = process.env[name]
  if (!value) throw new Error(`set ${name}`)
  return value
}

const client = createClient({
  chain: tempoModerato,
  transport: http(env('RPC_URL')),
})
const venue = env('VENUE') as `0x${string}`
// Trust the venue only if the factory you verified created it.
if (
  !(await Info.isVenue(client, {
    factory: env('FACTORY') as `0x${string}`,
    venue,
  }))
)
  throw new Error(`${venue} is not a venue the factory created`)
const snapshot = await Snapshot.get(client, { venue })
console.log(
  `venue ${venue} at block ${snapshot.block.number}: halted ${snapshot.state.halted}, ${snapshot.state.pairCount} pairs`,
)
const now = { at: snapshot.block.timestamp, halted: snapshot.state.halted }
for (const pair of snapshot.pairs) {
  if (!pair.ok) {
    console.log(
      `pair ${pair.pairIndex}: unreadable (${pair.error.message.split('\n')[0]})`,
    )
    continue
  }
  if (BigInt(pair.base) === 0n) continue
  console.log(
    `pair ${pair.pairIndex}: mid ${pair.hot.mid === 0n ? 'unposted' : Price.format(pair.hot.mid)}, seq ${pair.hot.sequence}, valid until ${pair.hot.validUntil}`,
  )
  for (const side of ['bids', 'asks'] as const) {
    console.log(
      `  ${side}: ${Book.remaining(pair, side, now)} base takeable now, of ${Book.ladder(pair, side).reduce((s, r) => s + r.depth, 0n)} posted`,
    )
  }
  const q = Quote.local(snapshot, {
    pairIndex: pair.pairIndex,
    tokenIn: pair.quote,
    tokenOut: pair.base,
    amount: 1_000_000n,
    exactIn: false,
    // An eth_call's priority fee: a send's own tip may meet the venue's cap.
    priorityFee: 0n,
  })
  console.log(
    `  buy 1e6 base: ${q.ok ? `${q.amountIn} quote in` : q.error.errorName}`,
  )
}
