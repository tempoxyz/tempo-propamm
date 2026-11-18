import { getAddress, parseAbi } from 'viem'
import { Abis } from 'viem/tempo'
import { describe, expect, test } from 'vitest'
import { venueAbi } from '../src/generated/abis.js'
import { BaseError, SnapshotIncompleteError } from '../src/internal/errors.js'
import {
  type Read,
  type Result,
  readOf,
  readValue,
} from '../src/internal/read.js'

const venue = '0x1111111111111111111111111111111111111111'
const other = '0x2222222222222222222222222222222222222222'
const taker = '0x00000000000000000000000000000000000000a1'

// These deliberately misplaced internal results model a future cursor mistake, not a current public SDK bug.
describe('readValue', () => {
  test('refuses another pair, token or taker from the same view', () => {
    const cases: readonly (readonly [Read, Read, unknown])[] = [
      [
        readOf(venue, venueAbi, 'consumed', [0]),
        readOf(venue, venueAbi, 'consumed', [1]),
        [111n, 222n],
      ],
      [
        readOf(venue, Abis.tip20, 'balanceOf', [venue]),
        readOf(other, Abis.tip20, 'balanceOf', [venue]),
        777n,
      ],
      [
        readOf(venue, venueAbi, 'takerAccess', [0, taker, 0n]),
        readOf(venue, venueAbi, 'takerAccess', [0, other, 0n]),
        1,
      ],
    ]
    for (const [expected, actual, value] of cases)
      expect
        .soft(() => readValue(success(actual, value), expected))
        .toThrow(BaseError)
  })

  test('preserves ABI and view checks', () => {
    const expected = readOf(venue, venueAbi, 'owner')
    for (const actual of [
      readOf(venue, [...venueAbi], 'owner'),
      readOf(venue, venueAbi, 'pendingOwner'),
    ])
      expect(() => readValue(success(actual, taker), expected)).toThrow(
        BaseError,
      )
  })

  test('accepts separately constructed equivalent reads and address casing', () => {
    const expected = readOf(taker, Abis.tip20, 'balanceOf', [taker])
    const actual = readOf(getAddress(taker), Abis.tip20, 'balanceOf', [
      getAddress(taker),
    ])
    expect(readValue(success(actual, 123n), expected)).toBe(123n)
    expect(
      readValue(
        success(readOf(venue, venueAbi, 'owner', []), taker),
        readOf(venue, venueAbi, 'owner'),
      ),
    ).toBe(taker)
  })

  test('compares nested arguments by their ABI encoding', () => {
    const abi = parseAbi([
      'function inspect((address target, uint256[] amounts)[] entries) view returns (uint256)',
    ])
    const expected = readOf(venue, abi, 'inspect', [
      [{ target: taker, amounts: [1n, 2n] }],
    ])
    const same = readOf(venue, abi, 'inspect', [
      [{ amounts: [1n, 2n], target: getAddress(taker) }],
    ])
    const different = readOf(venue, abi, 'inspect', [
      [{ target: taker, amounts: [1n, 3n] }],
    ])
    expect(readValue(success(same, 3n), expected)).toBe(3n)
    expect(() => readValue(success(different, 4n), expected)).toThrow(BaseError)
  })

  test('keeps missing and failed reads distinct from misplaced results', () => {
    const expected = readOf(venue, venueAbi, 'consumed', [0])
    const error = new Error('view reverted')
    expect(() => readValue(undefined, expected)).toThrow(
      SnapshotIncompleteError,
    )
    expect(() =>
      readValue({ status: 'failure', error, read: expected }, expected),
    ).toThrow(error)
    expect(() =>
      readValue(
        {
          status: 'failure',
          error,
          read: readOf(venue, venueAbi, 'consumed', [1]),
        },
        expected,
      ),
    ).toThrow(BaseError)
  })
})

function success(read: Read, result: unknown): Result {
  return { status: 'success', result, read }
}
