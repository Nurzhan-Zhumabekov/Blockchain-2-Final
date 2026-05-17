// Contract addresses on Arbitrum Sepolia.
// Set these via a .env file in the frontend/ directory:
//   VITE_GOV_TOKEN=0x...
//   VITE_RWA_TOKEN=0x...
//   VITE_RWA_POOL=0x...
//   VITE_RWA_STAKING=0x...
//   VITE_RWA_GOVERNOR=0x...
//   VITE_TIMELOCK=0x...

function addr(key: string): `0x${string}` {
  const v = import.meta.env[key]
  if (!v) return '0x0000000000000000000000000000000000000000'
  return v as `0x${string}`
}

export const ADDRESSES = {
  govToken:    addr('VITE_GOV_TOKEN'),
  rwaToken:    addr('VITE_RWA_TOKEN'),
  rwaPool:     addr('VITE_RWA_POOL'),
  rwaStaking:  addr('VITE_RWA_STAKING'),
  rwaGovernor: addr('VITE_RWA_GOVERNOR'),
  timelock:    addr('VITE_TIMELOCK'),
} as const

export const ZERO_ADDR = '0x0000000000000000000000000000000000000000' as const

export function isDeployed(addr: string): boolean {
  return addr !== ZERO_ADDR
}
