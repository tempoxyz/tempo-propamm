// Prints unsigned calldata for a shape and an order, offline: no RPC, no key. Parity with sdk/rust/examples/quote.rs.
//
//   VENUE=0x1111111111111111111111111111111111111111 SEQUENCE=2 VALID_UNTIL=1800000060 node examples/quote.ts
import { Actions, Price, Shape } from '@tempoxyz/propamm-sdk'

const env = (name: string, fallback?: string) => {
  const value = process.env[name] ?? fallback
  if (value === undefined) throw new Error(`set ${name}`)
  return value
}

const venue = env('VENUE') as `0x${string}`
const pairIndex = Number(env('PAIR_INDEX', '0'))
// At sizeUnit 1e6 and 6-decimal tokens this is 50,000 base tokens per side; spread 20 is 2 bp at widthScale 1000.
const shape = Shape.from({
  bids: [{ size: 50_000, spread: 20 }],
  asks: [{ size: 50_000, spread: 20 }],
})
const setShape = Actions.venue.setShape.call({
  venue,
  pairIndex,
  shapeId: 7,
  shape,
})
// Sequence 2 is a fresh pair's first accepted post (it stores 1). Choose a fresh, short expiry.
const order = Actions.maker.order.call({
  venue,
  order: {
    pairIndex,
    mid: Price.parse(env('MID', '1.085')),
    shapeId: 7,
    sequence: Number(env('SEQUENCE')),
    validUntil: Number(env('VALID_UNTIL')),
  },
})
console.log(
  JSON.stringify(
    {
      setShape: {
        to: setShape.to,
        data: setShape.data,
        signer: setShape.signer,
      },
      order: {
        to: order.to,
        data: order.data,
        signer: order.signer,
        posts: order.posts,
      },
    },
    null,
    2,
  ),
)
