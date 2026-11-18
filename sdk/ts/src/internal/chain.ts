import type { Chain } from 'viem'
import { Chain as TempoChain } from 'viem/tempo'

// Every viem/tempo chain spreads one config, so they all share its serializer and formatter objects.
const tempoSerializer = TempoChain.tempo.serializers?.transaction
const tempoRequestFormatter = TempoChain.tempo.formatters?.transactionRequest

/**
 * Whether the chain is a viem/tempo chain: it serializes transactions with viem/tempo's serializer and formats requests
 * with its formatter, which a `calls` batch (0x76) needs, since viem sends `calls` only through them. That holds for
 * `viem/chains`' `tempo`, `tempoModerato`, `tempoDevnet` and `tempoLocalnet`, for any chain spread or `extend`ed from
 * one, and for a chain defined from viem/tempo's config under another id. A chain id alone isn't a signal: Tempo's
 * localnet is 1337, as many other dev chains are.
 *
 * @param chain - The client's chain, if any.
 * @returns Whether it is a viem/tempo chain.
 */
export function isTempoChain(chain: Chain | undefined): boolean {
  if (!chain || !tempoSerializer || !tempoRequestFormatter) return false
  return (
    chain.serializers?.transaction === tempoSerializer &&
    chain.formatters?.transactionRequest === tempoRequestFormatter
  )
}
