import { useAccount } from 'wagmi'
import { useReadContracts } from 'wagmi'
import { formatEther } from 'viem'
import { ADDRESSES, isDeployed } from '../addresses'
import { GOV_TOKEN_ABI, RWA_TOKEN_ABI, RWA_POOL_ABI } from '../abis'

function fmt(v: bigint | undefined, decimals = 4): string {
  if (v == null) return '—'
  const s = formatEther(v)
  const n = parseFloat(s)
  return n.toLocaleString('en-US', { maximumFractionDigits: decimals })
}

export function Overview() {
  const { address, isConnected } = useAccount()
  const deployed = isDeployed(ADDRESSES.govToken)

  const { data } = useReadContracts({
    contracts: [
      { address: ADDRESSES.govToken, abi: GOV_TOKEN_ABI, functionName: 'balanceOf', args: [address ?? '0x0'] },
      { address: ADDRESSES.govToken, abi: GOV_TOKEN_ABI, functionName: 'getVotes',  args: [address ?? '0x0'] },
      { address: ADDRESSES.govToken, abi: GOV_TOKEN_ABI, functionName: 'delegates', args: [address ?? '0x0'] },
      { address: ADDRESSES.govToken, abi: GOV_TOKEN_ABI, functionName: 'totalSupply' },
      { address: ADDRESSES.govToken, abi: GOV_TOKEN_ABI, functionName: 'MAX_SUPPLY' },
      { address: ADDRESSES.rwaToken, abi: RWA_TOKEN_ABI, functionName: 'balanceOf', args: [address ?? '0x0'] },
      { address: ADDRESSES.rwaToken, abi: RWA_TOKEN_ABI, functionName: 'assetType' },
      { address: ADDRESSES.rwaToken, abi: RWA_TOKEN_ABI, functionName: 'collateralValue' },
      { address: ADDRESSES.rwaPool,  abi: RWA_POOL_ABI,  functionName: 'reserve0' },
      { address: ADDRESSES.rwaPool,  abi: RWA_POOL_ABI,  functionName: 'reserve1' },
      { address: ADDRESSES.rwaPool,  abi: RWA_POOL_ABI,  functionName: 'totalSupply' },
      { address: ADDRESSES.rwaPool,  abi: RWA_POOL_ABI,  functionName: 'balanceOf', args: [address ?? '0x0'] },
    ],
    query: { enabled: isConnected && deployed },
  })

  const [
    govBal, votingPower, delegatee, totalSupply, maxSupply,
    rwaBal, assetType, collateral,
    reserve0, reserve1, lpTotal, lpBal,
  ] = (data ?? []).map(r => r?.result)

  const selfDelegated = delegatee && address &&
    (delegatee as string).toLowerCase() === address.toLowerCase()

  if (!deployed) {
    return (
      <div style={styles.placeholder}>
        <p>Contracts not yet deployed.</p>
        <p style={{ fontSize: '0.85rem', color: '#718096', marginTop: '8px' }}>
          Set <code>VITE_GOV_TOKEN</code>, <code>VITE_RWA_TOKEN</code>, and <code>VITE_RWA_POOL</code> in <code>.env</code>.
        </p>
      </div>
    )
  }

  return (
    <div style={styles.grid}>
      {/* GOV Token card */}
      <div style={styles.card}>
        <h3 style={styles.cardTitle}>RWAGOV Token</h3>
        <Row label="Your balance"    value={`${fmt(govBal as bigint)} RWAGOV`} />
        <Row label="Voting power"    value={fmt(votingPower as bigint)} highlight={!selfDelegated} />
        {!selfDelegated && votingPower === 0n && (
          <p style={styles.hint}>Delegate to yourself on the Governance tab to activate voting power.</p>
        )}
        <Row label="Total supply"    value={`${fmt(totalSupply as bigint)} RWAGOV`} />
        <Row label="Max supply"      value={`${fmt(maxSupply as bigint)} RWAGOV`} />
      </div>

      {/* RWA Token card */}
      <div style={styles.card}>
        <h3 style={styles.cardTitle}>RWA Token</h3>
        <Row label="Your balance"    value={`${fmt(rwaBal as bigint)} RWA`} />
        <Row label="Asset type"      value={(assetType as string) ?? '—'} />
        <Row label="Collateral value" value={`$${fmt(collateral as bigint, 2)}`} />
      </div>

      {/* Pool card */}
      <div style={styles.card}>
        <h3 style={styles.cardTitle}>AMM Pool</h3>
        <Row label="Reserve (RWAGOV)" value={`${fmt(reserve0 as bigint)} RWAGOV`} />
        <Row label="Reserve (RWA)"   value={`${fmt(reserve1 as bigint)} RWA`} />
        <Row label="LP total supply" value={fmt(lpTotal as bigint)} />
        <Row label="Your LP shares"  value={fmt(lpBal as bigint)} />
        {!!(reserve0 && reserve1 && (reserve0 as bigint) > 0n && (reserve1 as bigint) > 0n) && (
          <Row
            label="Price (GOV/RWA)"
            value={`${(Number(formatEther(reserve1 as bigint)) / Number(formatEther(reserve0 as bigint))).toFixed(4)}`}
          />
        )}
      </div>
    </div>
  )
}

function Row({ label, value, highlight }: { label: string; value: string; highlight?: boolean }) {
  return (
    <div style={styles.row}>
      <span style={styles.label}>{label}</span>
      <span style={{ ...styles.value, color: highlight ? '#fc8181' : '#f7fafc' }}>{value}</span>
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  grid: {
    display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))', gap: '1rem',
  },
  card: {
    background: '#161b26', border: '1px solid #2d3748', borderRadius: '12px', padding: '1.25rem',
  },
  cardTitle: { fontSize: '0.95rem', fontWeight: 700, color: '#a78bfa', marginBottom: '1rem' },
  row: { display: 'flex', justifyContent: 'space-between', marginBottom: '0.6rem' },
  label: { fontSize: '0.82rem', color: '#718096' },
  value: { fontSize: '0.82rem', fontWeight: 600 },
  hint: { fontSize: '0.75rem', color: '#e2a541', marginTop: '6px' },
  placeholder: {
    background: '#161b26', border: '1px solid #2d3748', borderRadius: '12px',
    padding: '2rem', textAlign: 'center', color: '#718096',
  },
}
