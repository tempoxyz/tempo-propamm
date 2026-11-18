// A fresh `anvil --network tempo` per test file: real TIP-20 precompiles (AlphaUSD and BetaUSD, which every dev
// account holds), real 0x76 batches, and the v2 core deployed as DeployV2 deploys it. Never an environment RPC; anvil
// dev keys only.
import { type ChildProcess, spawn } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { createServer } from 'node:net'
import {
  type Address,
  type Client,
  createClient,
  encodeDeployData,
  encodeFunctionData,
  getAddress,
  getContractAddress,
  type Hex,
  http,
  keccak256,
  type LocalAccount,
  type TransactionReceipt,
  toHex,
} from 'viem'
import { mnemonicToAccount } from 'viem/accounts'
import {
  getChainId,
  getTransactionCount,
  sendTransactionSync,
} from 'viem/actions'
import { tempoLocalnet } from 'viem/chains'
import { Abis as TempoAbis, Actions as TempoActions } from 'viem/tempo'
import {
  Abis,
  Actions,
  Events,
  Info,
  Price,
  Quote,
  Sequencer,
  Shape,
  Snapshot,
} from '../../src/index.js'

const OUT = new URL('../../.forge/solar/out/', import.meta.url)
const MNEMONIC = 'test test test test test test test test test test test junk'

export const PATH_USD: Address = '0x20C0000000000000000000000000000000000000'
export const ALPHA_USD: Address = '0x20C0000000000000000000000000000000000001'
export const BETA_USD: Address = '0x20c0000000000000000000000000000000000002'
export const THETA_USD: Address = '0x20C0000000000000000000000000000000000003'

const ROLES = [
  'owner',
  'agent',
  'sponsorAdmin',
  'taker',
  'stranger',
  'newOwner',
  'newAdmin',
  'other',
  'deployer',
] as const
export type Role = (typeof ROLES)[number]

export type Fixture = {
  rpc: string
  client: Client<ReturnType<typeof http>, typeof tempoLocalnet>
  accounts: Record<Role, LocalAccount>
  core: {
    implementation: Address
    settler: Address
    factory: Address
  }
  venue: Address
  base: Address
  quote: Address
  increaseTime(seconds: number): Promise<void>
  stop(): Promise<void>
}

export function artifact(
  file: string,
  name: string,
): { abi: readonly unknown[]; bytecode: Hex } {
  const path = new URL(`${file}/${name}.json`, OUT)
  let text: string
  try {
    text = readFileSync(path, 'utf8')
  } catch {
    throw new Error(
      `${path.pathname} is missing: run npm run contracts:build first`,
    )
  }
  const json = JSON.parse(text) as { abi: unknown[]; bytecode: { object: Hex } }
  return { abi: json.abi, bytecode: json.bytecode.object }
}

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer()
    server.unref()
    server.on('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const address = server.address()
      server.close(() =>
        typeof address === 'object' && address
          ? resolve(address.port)
          : reject(new Error('no port')),
      )
    })
  })
}

/** Starts anvil, deploys the core and one venue owned by `owner`, and returns the clients and addresses. */
export async function start(): Promise<Fixture> {
  const port = await freePort()
  const rpc = `http://127.0.0.1:${port}`
  const node: ChildProcess = spawn(
    process.env.ANVIL_BIN ?? 'anvil',
    [
      '--network',
      'tempo',
      '--chain-id',
      String(tempoLocalnet.id),
      '--port',
      String(port),
      '--silent',
    ],
    {
      stdio: 'ignore',
    },
  )
  const exited = new Promise<void>((resolve) =>
    node.once('exit', () => resolve()),
  )
  const stop = async () => {
    if (node.exitCode === null) node.kill()
    await exited
  }
  try {
    const chain = {
      ...tempoLocalnet,
      rpcUrls: { default: { http: [rpc] } },
    } as typeof tempoLocalnet
    const client = createClient({
      chain,
      transport: http(rpc),
      pollingInterval: 50,
    })
    let ready = false
    for (let i = 0; i < 200 && !ready; i++) {
      try {
        await getChainId(client)
        ready = true
      } catch {
        await new Promise((r) => setTimeout(r, 50))
      }
    }
    if (!ready) throw new Error('anvil did not start within 10 seconds')

    const accounts = Object.fromEntries(
      ROLES.map((role, i) => [
        role,
        // Keep fixture addresses stable; index 5 is retired.
        mnemonicToAccount(MNEMONIC, { addressIndex: i >= 5 ? i + 1 : i }),
      ]),
    ) as unknown as Record<Role, LocalAccount>
    const core = await deployCore(client, accounts.deployer)

    const salt = keccak256(toHex('propamm-sdk-e2e'))
    await Actions.factory.createVenueSync(client, {
      factory: core.factory,
      owner: accounts.owner.address,
      salt,
      account: accounts.owner,
    })
    const venue = await Info.predictVenue(client, {
      factory: core.factory,
      owner: accounts.owner.address,
      salt,
    })

    return {
      rpc,
      client,
      accounts,
      core,
      venue,
      base: ALPHA_USD,
      quote: BETA_USD,
      increaseTime: async (seconds: number) => {
        await client.request({
          method: 'evm_increaseTime' as never,
          params: [toHex(seconds)] as never,
        })
        await client.request({
          method: 'evm_mine' as never,
          params: [] as never,
        })
      },
      stop,
    }
  } catch (e) {
    await stop()
    throw e
  }
}

/** DeployV2's order: the implementation against the factory's predicted address, then the Settler, the factory, as the deployer's three consecutive CREATEs. */
async function deployCore(
  client: Fixture['client'],
  deployer: LocalAccount,
): Promise<Fixture['core']> {
  const nonce = await getTransactionCount(client, { address: deployer.address })
  const at = (n: number) =>
    getContractAddress({ from: deployer.address, nonce: BigInt(nonce + n) })
  const deploy = async (
    file: string,
    name: string,
    args: readonly unknown[],
  ) => {
    const { abi, bytecode } = artifact(file, name)
    const data = encodeDeployData({ abi, bytecode, args } as never)
    const receipt = await sendTransactionSync(client, {
      account: deployer,
      data,
      chain: client.chain,
    } as never)
    if (receipt.status !== 'success' || !receipt.contractAddress)
      throw new Error(`deploying ${name} failed`)
    return getAddress(receipt.contractAddress)
  }
  const implementation = await deploy('Venue.sol', 'Venue', [at(2)])
  const settler = await deploy('Settler.sol', 'Settler', [implementation])
  const factory = await deploy('VenueFactory.sol', 'VenueFactory', [
    implementation,
    settler,
  ])
  if (factory.toLowerCase() !== at(2).toLowerCase())
    throw new Error('the factory is not at its predicted address')
  return { implementation, settler, factory }
}

/**
 * A `*Sync` result whose receipt must be a success, narrowed to the variant that carries the event's arguments: a
 * pending or reverted receipt fails the test with its status.
 */
export function mined<result extends { status: string }>(
  result: result,
): Extract<result, { status: 'success' }> {
  if (result.status !== 'success')
    throw new Error(`the transaction is ${result.status}, not mined`)
  return result as never
}

export type PairSetup = {
  pairIndex: number
  shapeId: number
  shape: Shape.Shape
  sequencer: Sequencer.Sequencer
  validUntil: number
}

/** The default test ladder: five bid and five ask levels, sloped, at `sizeUnit` 1e6 (1 token per size step). */
export const LADDER = Shape.from({
  bids: [
    { size: 1_000, spread: 10 },
    { size: 2_000, spread: 20 },
    { size: 3_000, spread: 40 },
    { size: 4_000, spread: 80 },
    { size: 5_000, spread: 160 },
  ],
  asks: [
    { size: 1_000, spread: 10 },
    { size: 2_000, spread: 25 },
    { size: 3_000, spread: 50 },
    { size: 4_000, spread: 100 },
    { size: 5_000, spread: 200 },
  ],
})

/**
 * Adds a pair (base AlphaUSD, quote BetaUSD), approves `agent` as an agent, sets shape 7 (as the agent), home-lists
 * `taker`, sets the pair `Listed`, funds the venue with `fund` of each token and posts a first order at `mid`.
 */
export async function setupPair(
  f: Fixture,
  options: {
    sizeUnit?: bigint | undefined
    shape?: Shape.Shape | undefined
    mid?: bigint | undefined
    fund?: bigint | undefined
    refill?: boolean | undefined
  } = {},
): Promise<PairSetup> {
  const { client, venue, base, quote } = f
  const { owner, agent, taker } = f.accounts
  const { pairIndex } = mined(
    await Actions.venue.addPairSync(client, {
      venue,
      base,
      quote,
      sizeUnit: options.sizeUnit ?? 1_000_000n,
      account: owner,
    }),
  )
  await Actions.venue.approveAgentSync(client, {
    venue,
    agent: agent.address,
    account: owner,
  })
  const shape = options.shape ?? LADDER
  await Actions.venue.setShapeSync(client, {
    venue,
    pairIndex,
    shapeId: 7,
    shape,
    account: agent,
  })
  await Actions.venue.setMembersSync(client, {
    venue,
    pairIndex,
    sponsorId: 0n,
    accounts: [taker.address],
    allowed: true,
    account: owner,
  })
  await Actions.venue.setPairAccessSync(client, {
    venue,
    pairIndex,
    mode: 'listed',
    account: owner,
  })
  const fund = options.fund ?? 100_000_000_000n
  if (fund > 0n) {
    await TempoActions.token.transferSync(client, {
      token: base,
      to: venue,
      amount: fund,
      account: owner,
    })
    await TempoActions.token.transferSync(client, {
      token: quote,
      to: venue,
      amount: fund,
      account: owner,
    })
  }
  const sequencer = await Sequencer.seed(client, { venue, pairs: [pairIndex] })
  const block = await client.request({
    method: 'eth_getBlockByNumber',
    params: ['latest', false],
  })
  const validUntil =
    Number(BigInt((block as { timestamp: Hex }).timestamp)) + 3_600
  await Actions.maker.orderSync(client, {
    venue,
    order: {
      pairIndex,
      mid: options.mid ?? Price.parse('1.085'),
      shapeId: 7,
      sequence: Sequencer.next(sequencer, pairIndex),
      validUntil,
      refill: options.refill ? 'both' : 'neither',
    },
    account: agent,
  })
  return { pairIndex, shapeId: 7, shape, sequencer, validUntil }
}

export type Swap = {
  venue: Address
  pairIndex: number
  tokenIn: Address
  tokenOut: Address
  exactIn: boolean
  /** Exact in: what the batch pays. Exact out: the most it pays. */
  amountIn: bigint
  /** Exact in: the least it takes. Exact out: what it takes. */
  amountOut: bigint
  sponsorId?: bigint | undefined
  account?: LocalAccount | undefined
}

let swaps = 0

/**
 * A taker's swap through the core's Settler as one 0x76 batch, from the test's own amounts: the SDK is maker-only and
 * builds no swap. Exact in is `[approve(settler, amountIn), swapExactIn]`, exact out `[approve(settler, amountIn),
 * swapExactOut, approve(settler, 0)]`. Returns the receipt and the venue's `Fill`, or throws if the batch reverts.
 */
export async function swap(
  f: Fixture,
  s: Swap,
): Promise<{
  receipt: TransactionReceipt
  fill: Record<string, unknown> | null
}> {
  const settler = f.core.settler
  const approve = (amount: bigint) => ({
    to: s.tokenIn,
    data: encodeFunctionData({
      abi: TempoAbis.tip20,
      functionName: 'approve',
      args: [settler, amount],
    }),
  })
  const swapArgs = (amount: bigint, bound: bigint) =>
    [
      s.venue,
      s.pairIndex,
      s.tokenIn,
      s.tokenOut,
      amount,
      bound,
      s.sponsorId ?? 0n,
      2 ** 40 - 1,
      keccak256(toHex(`swap ${++swaps}`)),
    ] as const
  const calls = s.exactIn
    ? [
        approve(s.amountIn),
        {
          to: settler,
          data: encodeFunctionData({
            abi: Abis.settlerAbi,
            functionName: 'swapExactIn',
            args: swapArgs(s.amountIn, s.amountOut),
          }),
        },
      ]
    : [
        approve(s.amountIn),
        {
          to: settler,
          data: encodeFunctionData({
            abi: Abis.settlerAbi,
            functionName: 'swapExactOut',
            args: swapArgs(s.amountOut, s.amountIn),
          }),
        },
        approve(0n),
      ]
  const receipt = (await sendTransactionSync(f.client, {
    account: s.account ?? f.accounts.taker,
    calls,
    chain: f.client.chain,
    throwOnReceiptRevert: true,
  } as never)) as TransactionReceipt
  return {
    receipt,
    fill:
      Events.venue(receipt.logs, { venue: s.venue, eventName: 'Fill' })[0]
        ?.args ?? null,
  }
}

/** {@link swap} at exactly the venue's quote now (`Quote.local` on a fresh snapshot), which it returns too. */
export async function swapAtQuote(
  f: Fixture,
  s: Omit<Swap, 'amountIn' | 'amountOut'> & { amount: bigint },
) {
  const snapshot = await Snapshot.get(f.client, {
    venue: s.venue,
    pairs: [s.pairIndex],
  })
  // The tests swap only while their venue has no fee cap, which any priority fee passes.
  const quote = Quote.local(snapshot, { ...s, priorityFee: 0n })
  if (!quote.ok)
    throw new Error(`the venue would revert ${quote.error.errorName}`)
  return {
    quote,
    ...(await swap(f, {
      ...s,
      amountIn: quote.amountIn,
      amountOut: quote.amountOut,
    })),
  }
}
