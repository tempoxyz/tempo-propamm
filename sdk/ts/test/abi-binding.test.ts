import { encodeFunctionData, parseAbi } from 'viem'
import { describe, expect, test } from 'vitest'
import { narrow, venueCall } from '../src/actions/internal/abis.js'
import { venueAbi } from '../src/generated/abis.js'
import { InvalidArgumentError } from '../src/internal/errors.js'

// Malformed and overloaded fixtures exercise internal invariants; current public builders pass valid literal names.
describe('narrow', () => {
  test('refuses a missing function name before encoding', () => {
    expect(() => narrow(venueAbi, 'missing' as never, [])).toThrow(
      InvalidArgumentError,
    )
  })

  test('refuses ambiguous function names before encoding', () => {
    const overloaded = parseAbi([
      'function configure(uint256 limit)',
      'function configure(address account)',
    ])
    expect(() => narrow(overloaded, 'configure', [])).toThrow(
      InvalidArgumentError,
    )
  })

  test('preserves a unique function and its errors', () => {
    const abi = parseAbi([
      'function configure(uint256 limit)',
      'error Refused()',
    ])
    const errors = abi.filter((item) => item.type === 'error')
    const selected = narrow(abi, 'configure', errors)
    expect(selected).toStrictEqual(abi)
    expect(
      encodeFunctionData({
        abi: selected,
        functionName: 'configure',
        args: [123n],
      }),
    ).toBe(encodeFunctionData({ abi, functionName: 'configure', args: [123n] }))
  })
})

describe('venueCall', () => {
  test('reports a typed refusal rather than passing an undefined ABI item to viem', () => {
    expect(() =>
      venueCall({
        venue: '0x1111111111111111111111111111111111111111',
        functionName: 'missing' as never,
        args: [] as never,
        signer: { role: 'owner' },
      }),
    ).toThrow(InvalidArgumentError)
  })
})
