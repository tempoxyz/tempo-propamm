// `propAmmActions()` at runtime: each group binds every action its module exports, with the action's own helpers.
// Nothing here sends: binding an action makes no request.
import { createClient, http } from 'viem'
import { tempoModerato } from 'viem/chains'
import { describe, expect, test } from 'vitest'
import { Actions, propAmmActions } from '../src/index.js'

const client = createClient({
  chain: tempoModerato,
  transport: http('http://127.0.0.1:9'),
}).extend(propAmmActions())

const helpers = ['call', 'extractEvent', 'extractEvents', 'requests']
const own = (action: object) =>
  helpers.filter((key) => Object.hasOwn(action, key)).sort()

describe('propAmmActions', () => {
  test('adds the four groups beside the client', () => {
    expect(Object.keys(propAmmActions()(client)).sort()).toStrictEqual([
      'factory',
      'maker',
      'venue',
    ])
  })

  for (const group of ['factory', 'maker', 'venue'] as const) {
    test(`${group}: binds every action, each with its helpers`, () => {
      const bound = client[group] as Record<string, object>
      const actions = Actions[group] as Record<string, object>
      expect(Object.keys(bound).sort()).toStrictEqual(
        Object.keys(actions).sort(),
      )
      for (const [name, action] of Object.entries(actions)) {
        const binding = bound[name] as Record<string, unknown>
        expect(typeof binding, name).toBe('function')
        expect(own(binding), name).toStrictEqual(own(action))
        // Simulation and gas are viem's own actions over `call()`, not helpers.
        for (const key of ['estimateGas', 'simulate']) {
          expect(Object.hasOwn(action, key), `${name}.${key}`).toBe(false)
          expect(Object.hasOwn(binding, key), `${name}.${key}`).toBe(false)
        }
        // Client-less helpers are the action's own; the others take the client from the binding.
        for (const key of ['call', 'extractEvent', 'extractEvents'])
          if (Object.hasOwn(action, key))
            expect(binding[key], `${name}.${key}`).toBe(
              (action as Record<string, unknown>)[key],
            )
      }
    })
  }

  test('a bound call builds the same call', () => {
    const args = {
      venue: '0x1111111111111111111111111111111111111111',
      halted: true,
    } as const
    expect(client.venue.setHalted.call(args)).toStrictEqual(
      Actions.venue.setHalted.call(args),
    )
  })
})
