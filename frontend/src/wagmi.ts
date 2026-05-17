import { createConfig, http } from 'wagmi'
import { arbitrumSepolia } from 'wagmi/chains'
import { injected, metaMask } from 'wagmi/connectors'

// Strip multicall3 — it's not pre-deployed on a local Anvil node,
// so wagmi must use individual eth_call requests instead.
const localChain = {
  ...arbitrumSepolia,
  contracts: {},
} as unknown as typeof arbitrumSepolia

export const config = createConfig({
  chains: [localChain],
  connectors: [
    injected(),
    metaMask(),
  ],
  transports: {
    [arbitrumSepolia.id]: http('http://localhost:8545'),
  },
})

declare module 'wagmi' {
  interface Register {
    config: typeof config
  }
}
