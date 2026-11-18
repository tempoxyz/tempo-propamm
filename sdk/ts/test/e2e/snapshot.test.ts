// One snapshot equals the individual reads at its block, through the deployless and the Multicall3 paths; and the
// deployed contracts' public constants equal the generated ones.
import {
  BaseError,
  CallExecutionError,
  createClient,
  custom,
  encodeAbiParameters,
  encodeDeployData,
  encodeFunctionData,
  getAddress,
  type Hex,
  keccak256,
  numberToHex,
  toFunctionSelector,
} from 'viem'
import {
  getBlock,
  getBlockNumber,
  getStorageAt,
  readContract,
  sendTransactionSync,
} from 'viem/actions'
import { Abis as TempoAbis, Actions as TempoActions } from 'viem/tempo'
import { afterAll, assert, beforeAll, describe, expect, test } from 'vitest'
import {
  Abis,
  Actions,
  Errors,
  HotWord,
  Info,
  Quote,
  Sequencer,
  Shape,
  Snapshot,
  Venue,
  VenueHookFlags,
} from '../../src/index.js'
import { readMany, readOf } from '../../src/internal/read.js'
import {
  artifact,
  type Fixture,
  mined,
  type PairSetup,
  setupPair,
  start,
} from './fixture.js'

const MULTICALL3 = '0xcA11bde05977b3631167028862bE2a173976CA11'
let f: Fixture
let p: PairSetup

beforeAll(async () => {
  f = await start()
  p = await setupPair(f)
  const { owner, sponsorAdmin, stranger } = f.accounts
  await Actions.venue.addSponsorSync(f.client, {
    venue: f.venue,
    sponsorId: 42n,
    admin: sponsorAdmin.address,
    account: owner,
  })
  await Actions.venue.setPairSponsorSync(f.client, {
    venue: f.venue,
    pairIndex: p.pairIndex,
    sponsorId: 42n,
    admitted: true,
    account: owner,
  })
  await Actions.venue.setDeniedSync(f.client, {
    venue: f.venue,
    accounts: [stranger.address],
    deny: true,
    account: owner,
  })
  // A removed pair stays in the index range and reads as all zero.
  const { pairIndex } = mined(
    await Actions.venue.addPairSync(f.client, {
      venue: f.venue,
      base: f.quote,
      quote: f.base,
      sizeUnit: 1n,
      account: owner,
    }),
  )
  await Actions.venue.removePairSync(f.client, {
    venue: f.venue,
    pairIndex,
    account: owner,
  })
})
afterAll(async () => f?.stop())

describe('Snapshot.get', () => {
  test('uses the validated bigint clock in RPC and local quote context', async () => {
    const calls: unknown[][] = []
    const client = createClient({
      chain: f.client.chain,
      transport: custom({
        request: ({ method, params }) => {
          if (method === 'eth_call') calls.push(params as unknown[])
          return f.client.request({ method, params } as never)
        },
      }),
    })
    const current = await Snapshot.get(client, {
      venue: f.venue,
      pairs: [p.pairIndex],
    })
    const block = await getBlock(f.client, {
      blockNumber: current.block.number,
    })
    expect(current.block.timestamp).toBe(block.timestamp)
    expect(calls.every((params) => params[3] === undefined)).toBe(true)
    calls.length = 0
    const time = BigInt(p.validUntil) + 1n
    const snapshot = await Snapshot.get(client, {
      venue: f.venue,
      pairs: [p.pairIndex],
      blockOverrides: { time },
    })
    expect(snapshot.block.timestamp).toBe(time)
    expect(calls.length).toBeGreaterThan(0)
    expect(
      calls.every(
        (params) =>
          (params[3] as { time?: string })?.time === numberToHex(time),
      ),
    ).toBe(true)
    const request = {
      pairIndex: p.pairIndex,
      tokenIn: f.base,
      tokenOut: f.quote,
      amount: 1n,
      exactIn: true,
    }
    const local = Quote.local(snapshot, { ...request, priorityFee: 0n })
    assert(!local.ok)
    expect(local.error.errorName).toBe('QuoteExpired')
    const remote = await Info.quote(client, {
      venue: f.venue,
      ...request,
      blockNumber: snapshot.block.number,
      blockOverrides: { time },
    }).catch((error: unknown) => error)
    const decoded = Errors.decode(remote)
    expect([decoded?.errorName, decoded?.args]).toStrictEqual([
      local.error.errorName,
      local.error.args,
    ])
  })

  test('equals the individual reads at its block, deployless or through Multicall3', async () => {
    const { taker, stranger, agent } = f.accounts
    const blockNumber = await getBlockNumber(f.client)
    const params = {
      venue: f.venue,
      sponsorIds: [42n, 7n],
      accounts: [stranger.address, agent.address],
      access: [{ taker: taker.address, sponsorIds: [0n, 42n] }],
      blockNumber,
      verifyHash: true,
    }
    const deployless = await Snapshot.get(f.client, params)
    const viaMulticall = await Snapshot.get(f.client, {
      ...params,
      multicallAddress: MULTICALL3,
    })
    expect(viaMulticall).toStrictEqual(deployless)

    const at = { blockNumber }
    const s = deployless
    expect(s.block.number).toBe(blockNumber)
    expect(s.state).toStrictEqual(
      await Info.venueState(f.client, { venue: f.venue, ...at }),
    )
    expect(s.pairs.length).toBe(2)
    const pair = Snapshot.pair(s, p.pairIndex)
    const market = await Info.market(f.client, {
      venue: f.venue,
      pairIndex: p.pairIndex,
      ...at,
    })
    expect({
      pairIndex: pair.pairIndex,
      base: pair.base,
      quote: pair.quote,
      sizeUnit: pair.sizeUnit,
      access: pair.access,
      hook: pair.hook,
      hookFlags: pair.hookFlags,
    }).toStrictEqual(market)
    const word = await readContract(f.client, {
      address: f.venue,
      abi: Abis.venueAbi,
      functionName: 'hotWord',
      args: [p.pairIndex],
      ...at,
    })
    expect(pair.hotWord).toBe(word)
    expect(pair.hot).toStrictEqual(HotWord.decode(word))
    expect(pair.consumed).toStrictEqual(
      await Info.consumed(f.client, {
        venue: f.venue,
        pairIndex: p.pairIndex,
        ...at,
      }),
    )
    expect(pair.shapeWords).toStrictEqual(
      await readContract(f.client, {
        address: f.venue,
        abi: Abis.venueAbi,
        functionName: 'shape',
        args: [p.pairIndex, pair.hot.shapeId],
        ...at,
      }),
    )
    expect(pair.shape).toStrictEqual(Shape.fromWords([...pair.shapeWords]))
    const balance = async (token: typeof f.base) =>
      (
        await TempoActions.token.getBalance(f.client, {
          token,
          account: f.venue,
          ...at,
        })
      ).amount
    expect(pair.inventory.base).toBe(await balance(f.base))
    expect(pair.inventory.quote).toBe(await balance(f.quote))
    expect(pair.hookLiquidity).toStrictEqual({ base: 0n, quote: 0n })

    const removed = s.pairs[1]
    assert(removed?.ok)
    expect(removed.access).toBe('none')
    expect(BigInt(removed.base)).toBe(0n)

    const [sponsor42, sponsor7] = s.sponsors
    assert(sponsor42?.ok && sponsor7?.ok)
    const state42 = await Info.sponsorState(f.client, {
      venue: f.venue,
      sponsorId: 42n,
      ...at,
    })
    expect({
      admin: sponsor42.admin,
      pendingAdmin: sponsor42.pendingAdmin,
      enabled: sponsor42.enabled,
      generation: sponsor42.generation,
    }).toStrictEqual(state42)
    expect(sponsor42.admitted).toStrictEqual({ 0: true, 1: false })
    expect(
      await Info.pairSponsor(f.client, {
        venue: f.venue,
        pairIndex: 1,
        sponsorId: 42n,
        ...at,
      }),
    ).toBe(false)
    expect(BigInt(sponsor7.admin), 'an unregistered id reads all zero').toBe(0n)

    expect(s.accounts).toStrictEqual([
      { ok: true, account: stranger.address, isDenied: true, isAgent: false },
      { ok: true, account: agent.address, isDenied: false, isAgent: true },
    ])
    for (const a of s.accounts) {
      assert(a.ok)
      expect(a.isDenied).toBe(
        await Info.isDenied(f.client, {
          venue: f.venue,
          account: a.account,
          ...at,
        }),
      )
      expect(a.isAgent).toBe(
        await Info.isAgent(f.client, {
          venue: f.venue,
          agent: a.account,
          ...at,
        }),
      )
    }
    expect(
      s.access
        .filter((a) => a.pairIndex === p.pairIndex)
        .map((a) => (a.ok ? [a.sponsorId, a.access, a.isMember] : a.error)),
    ).toStrictEqual([
      [0n, 'allowed', true],
      [42n, 'notListed', false],
    ])
    for (const a of s.access) {
      assert(a.ok)
      expect(a.access).toBe(
        await Info.takerAccess(f.client, {
          venue: f.venue,
          pairIndex: a.pairIndex,
          taker: a.taker,
          sponsorId: a.sponsorId,
          ...at,
        }),
      )
      expect(a.isMember).toBe(
        await Info.isMember(f.client, {
          venue: f.venue,
          pairIndex: a.pairIndex,
          sponsorId: a.sponsorId,
          account: a.taker,
          ...at,
        }),
      )
    }
    expect(
      Snapshot.access(s, {
        pairIndex: p.pairIndex,
        taker: taker.address,
        sponsorId: 42n,
      }).access,
    ).toBe('notListed')
    expect(() =>
      Snapshot.access(s, {
        pairIndex: p.pairIndex,
        taker: taker.address,
        sponsorId: 7n,
      }),
    ).toThrow(Errors.SnapshotIncompleteError)
  })

  test('pins every read to one block, seeds a sequencer from it, and refuses a venue that is not one', async () => {
    const before = await Snapshot.get(f.client, {
      venue: f.venue,
      pairs: [p.pairIndex],
    })
    await Actions.maker.orderSync(f.client, {
      venue: f.venue,
      order: {
        pairIndex: p.pairIndex,
        mid: before.pairs[0]?.ok ? before.pairs[0].hot.mid + 1n : 1n,
        shapeId: 7,
        sequence: Sequencer.next(p.sequencer, p.pairIndex),
        validUntil: p.validUntil,
      },
      account: f.accounts.agent,
    })
    const again = await Snapshot.get(f.client, {
      venue: f.venue,
      pairs: [p.pairIndex],
      blockNumber: before.block.number,
    })
    expect(
      again,
      'a later post does not leak into a pinned snapshot',
    ).toStrictEqual(before)
    const seeded = await Sequencer.seed(f.client, {
      venue: f.venue,
      pairs: [p.pairIndex],
      gap: 5,
      blockNumber: before.block.number,
    })
    expect(Sequencer.last(seeded, p.pairIndex)).toBe(
      Snapshot.pair(before, p.pairIndex).hot.sequence + 5,
    )
    await expect(
      Sequencer.seed(f.client, { venue: f.venue, pairs: [1] }),
    ).rejects.toThrow(Errors.UnknownPairError)
    await expect(
      Snapshot.get(f.client, { venue: f.core.settler }),
    ).rejects.toThrow(Errors.UnknownVenueError)
  })

  test("tells a node that fails the venue state's read from an address that is no venue", async () => {
    // A transport that forwards every request to anvil but fails every eth_call, as a node that is down would.
    const failing = createClient({
      chain: f.client.chain,
      transport: custom(
        {
          request: async ({ method, params }) => {
            if (method === 'eth_call') throw new Error('the node is down')
            return f.client.request({ method, params } as never)
          },
        },
        { retryCount: 0 },
      ),
    })
    const error = await Snapshot.get(failing, { venue: f.venue }).catch(
      (e: unknown) => e,
    )
    expect(error).not.toBeInstanceOf(Errors.UnknownVenueError)
    expect(error).toBeInstanceOf(BaseError)
    expect(
      (error as BaseError).walk((e) => e instanceof CallExecutionError),
      "viem's error for the failed eth_call",
    ).not.toBe(null)
    expect((error as BaseError).message).toContain('the node is down')
    // An account with no code answers no view: not a venue.
    await expect(
      Snapshot.get(f.client, { venue: f.accounts.stranger.address }),
    ).rejects.toThrow(Errors.UnknownVenueError)
  })

  test.each(['pair', 'takerAccess', 'shape', 'balanceOf'] as const)(
    'keeps a failed %s aggregate chunk local to its entries',
    async (functionName) => {
      const failure = new DOMException('one chunk aborted', 'AbortError')
      const needle =
        functionName === 'balanceOf'
          ? encodeFunctionData({
              abi: TempoAbis.tip20,
              functionName,
              args: [f.venue],
            })
          : functionName === 'shape'
            ? encodeFunctionData({
                abi: Abis.venueAbi,
                functionName,
                args: [0, p.shapeId],
              })
            : functionName === 'pair'
              ? encodeFunctionData({
                  abi: Abis.venueAbi,
                  functionName,
                  args: [0],
                })
              : encodeFunctionData({
                  abi: Abis.venueAbi,
                  functionName,
                  args: [0, f.accounts.taker.address, 0n],
                })
      let rejected = 0
      const client = createClient({
        chain: f.client.chain,
        batch: { multicall: { batchSize: 4 } },
        transport: custom(
          {
            request: ({ method, params }) => {
              if (
                method === 'eth_call' &&
                (params as [{ data: Hex }])[0].data
                  .toLowerCase()
                  .includes(needle.slice(2).toLowerCase())
              ) {
                rejected++
                throw failure
              }
              return f.client.request({ method, params } as never)
            },
          },
          { retryCount: 0 },
        ),
      })
      const snapshot = await Snapshot.get(client, {
        venue: f.venue,
        pairs: [0, 1],
        accounts: [f.accounts.stranger.address],
        sponsorIds: [42n],
        access: [{ taker: f.accounts.taker.address, sponsorIds: [0n] }],
      })
      expect(rejected).toBeGreaterThan(0)
      expect(snapshot.state).toStrictEqual(
        await Info.venueState(f.client, { venue: f.venue }),
      )
      expect(snapshot.accounts[0]?.ok).toBe(true)
      expect(snapshot.sponsors[0]?.ok).toBe(true)
      expect(snapshot.pairs[1]?.ok).toBe(true)
      expect(snapshot.access[1]?.ok).toBe(true)
      const failed =
        functionName === 'takerAccess' ? snapshot.access[0] : snapshot.pairs[0]
      expect(failed?.ok).toBe(false)
      if (failed && !failed.ok)
        expect((failed.error as BaseError).walk((e) => e === failure)).toBe(
          failure,
        )
      if (functionName === 'takerAccess')
        expect(snapshot.pairs[0]?.ok).toBe(true)
    },
  )

  test('retains configured deployless with a chain Multicall3 address that has no code', async () => {
    const client = createClient({
      chain: {
        ...f.client.chain,
        contracts: {
          ...f.client.chain.contracts,
          multicall3: { address: f.accounts.stranger.address },
        },
      },
      batch: { multicall: { deployless: true, batchSize: 8 } },
      transport: custom({
        request: ({ method, params }) =>
          f.client.request({ method, params } as never),
      }),
    })
    expect(await Info.venueState(client, { venue: f.venue })).toStrictEqual(
      await Info.venueState(f.client, { venue: f.venue }),
    )
    expect((await Snapshot.get(client, { venue: f.venue })).pairs[0]?.ok).toBe(
      true,
    )
  })

  test('keeps per-view malformed data separate from aggregate failures', async () => {
    const [result] = await readMany(
      f.client,
      [readOf(f.venue, Abis.venueAbi, 'owner')],
      {
        // Real EVM execution returning one byte, inside a valid aggregate3.
        stateOverride: [{ address: f.venue, code: '0x60126000526001601ff3' }],
      },
    )
    expect(result?.status).toBe('failure')
    if (result?.status === 'failure') {
      expect(result.error.name).toBe('ContractFunctionExecutionError')
      expect(result.read.functionName).toBe('owner')
    }
    const calls: Hex[] = []
    const client = createClient({
      chain: f.client.chain,
      batch: { multicall: { batchSize: 8 } },
      transport: custom({
        request: ({ method, params }) => {
          if (method === 'eth_call')
            calls.push((params as [{ data: Hex }])[0].data)
          return f.client.request({ method, params } as never)
        },
      }),
    })
    expect(await Info.venueState(client, { venue: f.venue })).toStrictEqual(
      await Info.venueState(f.client, { venue: f.venue }),
    )
    expect(calls.length).toBeGreaterThan(1)
  })

  test.each(
    [false, true].flatMap((batching) =>
      [new DOMException('aggregate aborted', 'AbortError'), '0x12', '0x'].map(
        (failure) => ({ batching, failure }),
      ),
    ),
  )(
    'preserves aggregate failure $failure with client batching $batching',
    async ({ batching, failure }) => {
      const client = createClient({
        chain: f.client.chain,
        batch: { multicall: batching ? { batchSize: 8 } : false },
        transport: custom(
          {
            request: ({ method, params }) => {
              if (method === 'eth_call') {
                if (typeof failure !== 'string') throw failure
                return Promise.resolve(failure)
              }
              return f.client.request({ method, params } as never)
            },
          },
          { retryCount: 0 },
        ),
      })
      // Exercise the same viem transport directly to compare its error, not
      // a fabricated viem error or a mock of multicall/readContract.
      const direct = await readContract(client, {
        abi: Abis.venueAbi,
        address: f.venue,
        functionName: 'owner',
      }).catch((error: unknown) => error)
      for (const read of [Snapshot.get, Info.venueState]) {
        const error = await read(client, { venue: f.venue }).catch(
          (error: unknown) => error,
        )
        expect(error).not.toBeInstanceOf(Errors.UnknownVenueError)
        expect(error).toBeInstanceOf(BaseError)
        if (failure instanceof DOMException) {
          expect((error as BaseError).walk((e) => e === failure)).toBe(failure)
        } else {
          expect((error as BaseError).name).toBe((direct as BaseError).name)
        }
      }
    },
  )

  test("reads the pair count once: three multicalls for 'all' pairs, two for named ones", async () => {
    // A transport that forwards every request to anvil and records the calls: nothing is faked.
    const calls: Hex[] = []
    const client = createClient({
      chain: f.client.chain,
      transport: custom({
        request: ({ method, params }) => {
          if (method === 'eth_call')
            calls.push((params as [{ data: Hex }])[0].data)
          return f.client.request({ method, params } as never)
        },
      }),
    })
    const pairCount = toFunctionSelector('pairCount()').slice(2)
    const reads = () => ({
      multicalls: calls.length,
      pairCountReads: calls.reduce(
        (n, data) => n + data.split(pairCount).length - 1,
        0,
      ),
    })
    const all = await Snapshot.get(client, { venue: f.venue })
    expect(reads()).toStrictEqual({ multicalls: 3, pairCountReads: 1 })
    expect(all.pairs.length).toBe(all.state.pairCount)
    calls.length = 0
    await Snapshot.get(client, { venue: f.venue, pairs: [p.pairIndex] })
    expect(reads()).toStrictEqual({ multicalls: 2, pairCountReads: 1 })
  })

  test('fails only the entry a read fails for, and reads under state and block overrides', async () => {
    // The venue's storage slot of `_hot[pairIndex]`, found by its value: Solidity's mapping layout, no other assumption.
    const word = await readContract(f.client, {
      address: f.venue,
      abi: Abis.venueAbi,
      functionName: 'hotWord',
      args: [p.pairIndex],
    })
    let slot: Hex | undefined
    for (let s = 0n; s < 64n && slot === undefined; s++) {
      const key = keccak256(
        encodeAbiParameters(
          [{ type: 'uint16' }, { type: 'uint256' }],
          [p.pairIndex, s],
        ),
      )
      if (
        (await getStorageAt(f.client, { address: f.venue, slot: key })) === word
      )
        slot = key
    }
    assert(slot, "no slot holds the pair's hot word")
    // A stored word never carries a refill bit: the SDK refuses to decode one.
    const malformed = numberToHex(BigInt(word) | (4n << 240n), { size: 32 })
    const { taker, stranger } = f.accounts
    const s = await Snapshot.get(f.client, {
      venue: f.venue,
      sponsorIds: [42n],
      accounts: [stranger.address],
      access: [{ taker: taker.address, sponsorIds: [0n] }],
      stateOverride: [
        { address: f.venue, stateDiff: [{ slot, value: malformed }] },
      ],
      blockOverrides: { time: 2_000_000_000n },
    })
    expect(
      s.pairs.map((x) =>
        x.ok ? [x.pairIndex, 'ok'] : [x.pairIndex, x.error.name],
      ),
    ).toMatchInlineSnapshot(`
      [
        [
          0,
          "InvalidHotWordError",
        ],
        [
          1,
          "ok",
        ],
      ]
    `)
    expect(
      [...s.sponsors, ...s.accounts, ...s.access].map((x) => x.ok),
      'every other entry stands',
    ).toStrictEqual([true, true, true, true])
    expect(s.block.timestamp, 'the overridden time, which the reads saw').toBe(
      2_000_000_000n,
    )
    expect(() =>
      Snapshot.pair(s, p.pairIndex),
    ).toThrowErrorMatchingInlineSnapshot(`
      [SnapshotIncompleteError: pair 0 could not be read: stored hot words carry only the off flags (0-3), got flags 4

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
    await expect(
      Snapshot.get(f.client, {
        venue: f.venue,
        blockNumber: 1n,
        blockTag: 'latest',
      }),
    ).rejects.toThrowErrorMatchingInlineSnapshot(`
      [InvalidArgumentError: pass blockNumber or blockTag, not both: they could name two blocks

      Version: @tempoxyz/propamm-sdk@<version>]
    `)
  })
})

describe('Snapshot.get, against the chain moving', () => {
  test('throws SnapshotReorgedError with verifyHash when the pinned block changes while it reads', async () => {
    // An empty block to pin, so re-mining it (anvil_reorg) drops no transaction a later test relies on.
    await f.client.request({ method: 'evm_mine' as never, params: [] as never })
    let reorged = false
    // A transport that forwards every request to anvil, and reorganizes the pinned block after the first read.
    const client = createClient({
      chain: f.client.chain,
      transport: custom({
        request: async ({ method, params }) => {
          const result = await f.client.request({ method, params } as never)
          if (method === 'eth_call' && !reorged) {
            reorged = true
            await f.client.request({
              method: 'anvil_reorg' as never,
              params: [1, []] as never,
            })
          }
          return result
        },
      }),
    })
    const error = await Snapshot.get(client, {
      venue: f.venue,
      pairs: [p.pairIndex],
      verifyHash: true,
    }).catch((e: unknown) => e)
    assert(error instanceof Errors.SnapshotReorgedError)
    expect(error.blockNumber).toBe(
      await getBlockNumber(f.client, { cacheTime: 0 }),
    )
    expect(error.newHash !== null && error.newHash !== error.hash).toBe(true)
    // Without a reorg, the same snapshot verifies.
    const verified = await Snapshot.get(f.client, {
      venue: f.venue,
      pairs: [p.pairIndex],
      verifyHash: true,
    })
    expect(verified.block.hash).toBe(
      (await getBlock(f.client, { blockNumber: verified.block.number })).hash,
    )
  })

  test("counts a BEFORE_FILL hook's liquidity toward the inventory, as venue.quote does", async () => {
    const { owner } = f.accounts
    // A pair on the venue's shared inventory, at a size unit that puts its balance well inside the ladder; the hook
    // holds 5 base tokens of its own.
    const q = await setupPair(f, { sizeUnit: 100_000_000n, fund: 0n })
    const { abi, bytecode } = artifact('MockVenueHook.sol', 'MockVenueHook')
    const deployed = await sendTransactionSync(f.client, {
      account: owner,
      data: encodeDeployData({
        abi,
        bytecode,
        args: [f.venue, VenueHookFlags.beforeFill],
      } as never),
      chain: f.client.chain,
    } as never)
    assert(deployed.contractAddress)
    const hook = getAddress(deployed.contractAddress)
    await Actions.venue.setPairHookSync(f.client, {
      venue: f.venue,
      pairIndex: q.pairIndex,
      hook,
      flags: VenueHookFlags.beforeFill,
      account: owner,
    })
    await TempoActions.token.transferSync(f.client, {
      token: f.base,
      to: hook,
      amount: 5_000_000n,
      account: owner,
    })
    const snapshot = await Snapshot.get(f.client, {
      venue: f.venue,
      pairs: [q.pairIndex],
    })
    const pair = Snapshot.pair(snapshot, q.pairIndex)
    expect([pair.hook, pair.hookFlags]).toStrictEqual([
      hook,
      VenueHookFlags.beforeFill,
    ])
    const held = pair.inventory.base
    expect(held).toBe(
      (
        await TempoActions.token.getBalance(f.client, {
          token: f.base,
          account: f.venue,
        })
      ).amount,
    )
    expect(pair.hookLiquidity).toStrictEqual({ base: 5_000_000n, quote: 0n })
    const buy = (amount: bigint) => ({
      pairIndex: q.pairIndex,
      tokenIn: f.quote,
      tokenOut: f.base,
      amount,
      exactIn: false,
    })
    const at = { blockNumber: snapshot.block.number }
    // 3 base tokens more than the venue holds: within what the hook adds.
    const covered = Quote.local(snapshot, {
      ...buy(held + 3_000_000n),
      priorityFee: 0n,
    })
    assert(covered.ok)
    expect(
      await Info.quote(f.client, {
        venue: f.venue,
        ...buy(held + 3_000_000n),
        ...at,
      }),
    ).toStrictEqual({
      amountIn: covered.amountIn,
      amountOut: covered.amountOut,
    })
    // 7 more: beyond both, the venue's own revert with the same arguments.
    const short = Quote.local(snapshot, {
      ...buy(held + 7_000_000n),
      priorityFee: 0n,
    })
    assert(!short.ok)
    expect(short.error).toStrictEqual({
      errorName: 'InsufficientInventory',
      args: [getAddress(f.base), held + 5_000_000n, held + 7_000_000n],
    })
    const onchain = await Info.quote(f.client, {
      venue: f.venue,
      ...buy(held + 7_000_000n),
      ...at,
    }).catch((e: unknown) => e)
    const decoded = Errors.decode(onchain)
    expect([decoded?.errorName, decoded?.args]).toStrictEqual([
      short.error.errorName,
      short.error.args,
    ])
  })
})

describe('generated constants', () => {
  test('equal the deployed contracts', async () => {
    const read = (functionName: string) =>
      readContract(f.client, {
        address: f.venue,
        abi: Abis.venueAbi,
        functionName: functionName as never,
      })
    expect(await read('MAX_BATCH')).toBe(Venue.maxBatch)
    expect(await read('NO_PRIORITY_FEE_CAP')).toBe(Venue.noPriorityFeeCap)
    expect(await read('DEFAULT_TAKER_PRIORITY_FEE_CAP')).toBe(
      Venue.defaultTakerPriorityFeeCap,
    )
    expect(await read('HOOK_VIEW_GAS')).toBe(Venue.hookViewGas)
    // A fresh venue has no cap: the stored zero reads as NO_PRIORITY_FEE_CAP.
    expect(
      (await Info.venueState(f.client, { venue: f.venue })).maxTakerPriorityFee,
    ).toBe(Venue.noPriorityFeeCap)
    expect(
      await readContract(f.client, {
        address: f.venue,
        abi: Abis.venueAbi,
        functionName: 'hotWord',
        args: [65_000],
      }),
    ).toBe(`0x${'0'.repeat(64)}`)
    expect(HotWord.initial).toBe(
      '0x0000000000010000000000000000000000000000000000000000000000000000',
    )
  })
})
