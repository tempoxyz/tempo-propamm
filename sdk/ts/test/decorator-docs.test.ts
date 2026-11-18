import { describe, expect, test } from 'vitest'
import {
  actionDocs,
  decoratorEntries,
  drift,
  sections,
  synced,
} from '../scripts/decorator-docs.mjs'
import * as Actions from '../src/actions/index.js'

describe("propAmmActions()'s docs", () => {
  test("every entry's description and @returns are its action's (node scripts/decorator-docs.mjs --write syncs them)", () => {
    expect(
      drift().map((e: { key: string; why: string }) => `${e.key}: ${e.why}`),
    ).toStrictEqual([])
  })

  test('the decorator binds every action, and only actions', () => {
    const entries = decoratorEntries().map((e: { key: string }) => e.key)
    const exported = Object.entries(Actions).flatMap(([group, actions]) =>
      Object.keys(actions as object).map((name) => `${group}.${name}`),
    )
    expect(new Set(entries)).toStrictEqual(new Set(exported))
    expect(new Set([...actionDocs().keys()])).toStrictEqual(new Set(exported))
  })

  test('a drifted entry is synced from its action, its example and params kept, rewrapped for its indent', () => {
    const action = sections(`/**
 * A new description that is long enough to need a second line once it is indented four more columns inside the decorator's type.
 *
 * - an item
 *
 * @param client - Client.
 * @returns The new value.
 */`)
    const entry = `/**
     * An old description.
     *
     * @example
     * \`\`\`ts
     * client.venue.x({})
     * \`\`\`
     *
     * @param parameters - Parameters.
     * @returns The old value.
     */`
    expect(synced(entry, action, '    ')).toBe(`/**
     * A new description that is long enough to need a second line once it is indented four more columns inside the
     * decorator's type.
     *
     * - an item
     *
     * @example
     * \`\`\`ts
     * client.venue.x({})
     * \`\`\`
     *
     * @param parameters - Parameters.
     * @returns The new value.
     */`)
  })
})
