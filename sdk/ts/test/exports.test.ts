// The package entry's surface: what it exports, and that the contracts' private constants stay internal.
import { describe, expect, test } from 'vitest'
import * as Sdk from '../src/index.js'

describe('the package entry', () => {
  test("exports its modules, the contracts' public constants and the enums", () => {
    expect(Object.keys(Sdk).sort()).toMatchInlineSnapshot(`
      [
        "Abis",
        "AccessMode",
        "Actions",
        "Book",
        "Errors",
        "Events",
        "Fees",
        "HotWord",
        "Info",
        "Ladder",
        "Plan",
        "Post",
        "PostOutcome",
        "Price",
        "Quote",
        "Roles",
        "Sequencer",
        "Shape",
        "Snapshot",
        "TakerAccess",
        "Venue",
        "VenueHookFlags",
        "accessModeNames",
        "propAmmActions",
        "takerAccessNames",
      ]
    `)
  })

  test('gives each contract only its public constants, in camelCase', () => {
    expect(Sdk.Venue).toMatchInlineSnapshot(`
      {
        "defaultTakerPriorityFeeCap": 10000000000n,
        "hookViewGas": 1500000n,
        "maxBatch": 100n,
        "noPriorityFeeCap": 18446744073709551615n,
      }
    `)
    expect(Sdk.VenueHookFlags).toMatchInlineSnapshot(`
      {
        "afterFill": 2,
        "all": 7,
        "beforeFill": 1,
        "takeInput": 4,
      }
    `)
    expect(Object.keys(Sdk.Abis).sort()).toMatchInlineSnapshot(`
      [
        "settlerAbi",
        "venueAbi",
        "venueFactoryAbi",
        "venueHookAbi",
      ]
    `)
  })

  test('gives each read, plan and event module its surface', () => {
    const modules = {
      Book: Sdk.Book,
      Events: Sdk.Events,
      Info: Sdk.Info,
      Plan: Sdk.Plan,
      PostOutcome: Sdk.PostOutcome,
      Quote: Sdk.Quote,
      Roles: Sdk.Roles,
      Sequencer: Sdk.Sequencer,
      Snapshot: Sdk.Snapshot,
    }
    expect(
      Object.fromEntries(
        Object.entries(modules).map(([name, module]) => [
          name,
          Object.keys(module).sort(),
        ]),
      ),
    ).toMatchInlineSnapshot(`
      {
        "Book": [
          "ladder",
          "remaining",
          "side",
        ],
        "Events": [
          "allEventsAbi",
          "parse",
          "venue",
        ],
        "Info": [
          "consumed",
          "fills",
          "hookLiquidity",
          "isAgent",
          "isDenied",
          "isMember",
          "isVenue",
          "market",
          "meta",
          "orders",
          "pairSponsor",
          "predictVenue",
          "quote",
          "sponsorState",
          "takerAccess",
          "takerAllowed",
          "venueState",
        ],
        "Plan": [
          "estimateGas",
          "gasEstimateMultiplier",
          "gasLimit",
          "simulate",
        ],
        "PostOutcome": [
          "fromBatch",
          "fromBatchReceipt",
          "fromLogs",
          "fromReceipt",
        ],
        "Quote": [
          "local",
        ],
        "Roles": [
          "check",
        ],
        "Sequencer": [
          "from",
          "last",
          "next",
          "observe",
          "seed",
        ],
        "Snapshot": [
          "access",
          "get",
          "pair",
        ],
      }
    `)
  })

  test('gives each pure module its ox-style surface', () => {
    const modules = {
      Errors: Sdk.Errors,
      Fees: Sdk.Fees,
      HotWord: Sdk.HotWord,
      Ladder: Sdk.Ladder,
      Post: Sdk.Post,
      Price: Sdk.Price,
      Shape: Sdk.Shape,
    }
    // Each module's functions and constants; Errors' classes are pinned in errors.test.ts.
    const surface = Object.fromEntries(
      Object.entries(modules).map(([name, module]) => [
        name,
        Object.keys(module)
          .filter((key) => !/Error$/.test(key))
          .sort(),
      ]),
    )
    expect(surface).toMatchInlineSnapshot(`
      {
        "Errors": [
          "allErrorsAbi",
          "assertAccess",
          "decode",
          "describe",
          "describeAccess",
          "errorOf",
          "validateAccess",
        ],
        "Fees": [
          "allows",
          "defaultBaseFeeMultiplier",
          "defaultMakerMargin",
          "feeFields",
          "gwei",
          "isNoCap",
          "makerTip",
          "priorityFee",
          "takerFields",
        ],
        "HotWord": [
          "assert",
          "decode",
          "decodeEntry",
          "flagAsksOff",
          "flagBidsOff",
          "flagRefillAsks",
          "flagRefillBids",
          "flagsMask",
          "flagsRefill",
          "fromFields",
          "initial",
          "isWellFormed",
          "refillFlags",
          "refillFromFlags",
          "sideOff",
          "sidesFlags",
          "sidesFromFlags",
          "toFields",
          "validate",
          "withoutRefill",
        ],
        "Ladder": [
          "applyFill",
          "applyRefill",
          "curve",
          "denominator",
          "depth",
          "effectiveSize",
          "factor",
          "factorOne",
          "fill",
          "scaleOne",
          "spreadOne",
        ],
        "Post": [
          "bulkCancel",
          "bulkOrders",
          "cancel",
          "order",
          "pack",
          "unpack",
        ],
        "Price": [
          "assert",
          "format",
          "from",
          "one",
          "parse",
          "validate",
        ],
        "Shape": [
          "assert",
          "check",
          "checkSide",
          "continues",
          "decodeSide",
          "empty",
          "encodeSide",
          "from",
          "fromWords",
          "levelBits",
          "levelsPerWord",
          "maxLevels",
          "rawLevel",
          "reasonNonCanonical",
          "reasonReservedBits",
          "reasonSpreadDecreases",
          "reservedMask",
          "side",
          "validate",
        ],
      }
    `)
  })

  test("keeps each library's constants in the module that ports it", () => {
    expect(Sdk.HotWord.initial).toBe(
      '0x0000000000010000000000000000000000000000000000000000000000000000',
    )
    expect([
      Sdk.HotWord.flagBidsOff,
      Sdk.HotWord.flagAsksOff,
      Sdk.HotWord.flagRefillBids,
      Sdk.HotWord.flagRefillAsks,
      Sdk.HotWord.flagsRefill,
      Sdk.HotWord.flagsMask,
    ]).toStrictEqual([1, 2, 4, 8, 12, 15])
    expect([
      Sdk.Shape.reasonReservedBits,
      Sdk.Shape.reasonNonCanonical,
      Sdk.Shape.reasonSpreadDecreases,
    ]).toStrictEqual([1, 2, 3])
    expect([
      Sdk.Shape.levelsPerWord,
      Sdk.Shape.levelBits,
      Sdk.Shape.maxLevels,
    ]).toStrictEqual([5n, 48n, 10n])
    expect([
      Sdk.Ladder.factorOne,
      Sdk.Ladder.scaleOne,
      Sdk.Ladder.denominator,
      Sdk.Ladder.spreadOne,
    ]).toStrictEqual([10n ** 8n, 1000n, 10n ** 26n, 100_000n])
    expect(Sdk.Price.one).toBe(10n ** 18n)
    expect([
      Sdk.Fees.gwei,
      Sdk.Fees.defaultMakerMargin,
      Sdk.Fees.defaultBaseFeeMultiplier,
    ]).toStrictEqual([10n ** 9n, 10n ** 9n, 3])
  })
})
