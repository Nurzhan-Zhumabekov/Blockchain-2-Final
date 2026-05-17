import { createConfig, http } from 'wagmi'
import { arbitrumSepolia } from 'wagmi/chains'
import { injected, metaMask } from 'wagmi/connectors'

const rpcUrl =
  import.meta.env.VITE_RPC_URL ||
  'https://sepolia-rollup.arbitrum.io/rpc'

export const config = createConfig({
  chains: [arbitrumSepolia],
  connectors: [
    metaMask(),
    injected(),
  ],
  transports: {
    [arbitrumSepolia.id]: http(rpcUrl),
  },
})

declare module 'wagmi' {
  interface Register {
    config: typeof config
  }
}
