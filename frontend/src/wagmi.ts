import { createConfig, http } from 'wagmi'
import { arbitrumSepolia } from 'wagmi/chains'
import { injected, metaMask } from 'wagmi/connectors'

export const config = createConfig({
  chains: [arbitrumSepolia],
  connectors: [
    injected(),
    metaMask(),
  ],
  transports: {
    [arbitrumSepolia.id]: http(
      import.meta.env.VITE_RPC_URL ?? 'https://sepolia-rollup.arbitrum.io/rpc'
    ),
  },
})

declare module 'wagmi' {
  interface Register {
    config: typeof config
  }
}
