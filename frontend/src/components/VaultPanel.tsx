import { useState } from 'react'
import { useAccount, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { parseEther, formatEther, maxUint256 } from 'viem'
import { ADDRESSES, isDeployed } from '../addresses'
import { RWA_VAULT_ABI, ERC20_ABI } from '../abis'

export function VaultPanel() {
  const { address, isConnected } = useAccount()
  const [depositAmount, setDepositAmount] = useState('')
  const [redeemAmount, setRedeemAmount] = useState('')
  const deployed = isDeployed(ADDRESSES.rwaVault)

  const { data, refetch } = useReadContracts({
    contracts: [
      { address: ADDRESSES.rwaVault, abi: RWA_VAULT_ABI, functionName: 'totalAssets' },
      { address: ADDRESSES.rwaVault, abi: RWA_VAULT_ABI, functionName: 'totalSupply' },
      { address: ADDRESSES.rwaVault, abi: RWA_VAULT_ABI, functionName: 'totalYieldAccrued' },
      { address: ADDRESSES.rwaVault, abi: RWA_VAULT_ABI, functionName: 'balanceOf', args: [address ?? '0x0'] },
      { address: ADDRESSES.rwaToken, abi: ERC20_ABI,     functionName: 'balanceOf', args: [address ?? '0x0'] },
      { address: ADDRESSES.rwaToken, abi: ERC20_ABI,     functionName: 'allowance', args: [address ?? '0x0', ADDRESSES.rwaVault] },
    ],
    query: { enabled: deployed },
  })

  const totalAssets     = data?.[0]?.result as bigint | undefined
  const totalShares     = data?.[1]?.result as bigint | undefined
  const totalYield      = data?.[2]?.result as bigint | undefined
  const userShares      = data?.[3]?.result as bigint | undefined
  const rwaBalance      = data?.[4]?.result as bigint | undefined
  const allowance       = data?.[5]?.result as bigint | undefined

  const depositWei = (() => { try { return depositAmount ? parseEther(depositAmount) : 0n } catch { return 0n } })()
  const redeemWei  = (() => { try { return redeemAmount  ? parseEther(redeemAmount)  : 0n } catch { return 0n } })()

  const needsApproval = allowance !== undefined && depositWei > 0n && allowance < depositWei

  const sharePrice = totalShares && totalShares > 0n && totalAssets
    ? (Number(formatEther(totalAssets)) / Number(formatEther(totalShares))).toFixed(6)
    : '1.000000'

  const userAssetsValue = userShares && totalShares && totalShares > 0n && totalAssets
    ? formatEther((userShares * totalAssets) / totalShares)
    : '0'

  const { writeContract, data: txHash, isPending } = useWriteContract()
  const { isSuccess } = useWaitForTransactionReceipt({ hash: txHash })
  if (isSuccess) refetch()

  const handleApprove = () => writeContract({
    address: ADDRESSES.rwaToken, abi: ERC20_ABI, functionName: 'approve',
    args: [ADDRESSES.rwaVault, maxUint256],
  })

  const handleDeposit = () => writeContract({
    address: ADDRESSES.rwaVault, abi: RWA_VAULT_ABI, functionName: 'deposit',
    args: [depositWei, address!],
  })

  const handleRedeem = () => {
    try {
      const s = parseEther(redeemAmount)
      writeContract({
        address: ADDRESSES.rwaVault, abi: RWA_VAULT_ABI, functionName: 'redeem',
        args: [s, address!, address!],
      })
    } catch { /* invalid input */ }
  }

  if (!deployed) {
    return <p style={{ color: '#718096' }}>Vault not yet deployed. Set VITE_RWA_VAULT in .env</p>
  }

  return (
    <div style={styles.grid}>
      {/* Vault stats */}
      <div style={styles.card}>
        <h3 style={styles.cardTitle}>Vault Stats (ERC-4626)</h3>
        <Row label="Total assets (RWA)"  value={`${fmt(totalAssets)} RWA`} />
        <Row label="Total shares (vRWA)" value={fmt(totalShares)} />
        <Row label="Share price"         value={`${sharePrice} RWA/vRWA`} highlight />
        <Row label="Total yield accrued" value={`${fmt(totalYield)} RWA`} />

        <div style={styles.divider} />
        <h3 style={styles.cardTitle}>Your Position</h3>
        <Row label="Shares (vRWA)"  value={fmt(userShares)} />
        <Row label="Value (RWA)"    value={`${parseFloat(userAssetsValue).toLocaleString('en-US', { maximumFractionDigits: 4 })} RWA`} highlight />
        <Row label="Wallet (RWA)"   value={`${fmt(rwaBalance)} RWA`} />
      </div>

      {/* Deposit / Redeem */}
      <div style={styles.card}>
        <h3 style={styles.cardTitle}>Deposit RWA</h3>
        <label style={styles.label}>Amount of RWA to deposit</label>
        <div style={styles.inputRow}>
          <input
            style={styles.input} type="number" min="0" placeholder="0.0"
            value={depositAmount} onChange={e => setDepositAmount(e.target.value)}
          />
          <button
            style={styles.maxBtn}
            onClick={() => rwaBalance != null && setDepositAmount(formatEther(rwaBalance))}
          >MAX</button>
        </div>

        {!isConnected ? (
          <p style={styles.warn}>Connect wallet to deposit.</p>
        ) : needsApproval ? (
          <button style={styles.btnPrimary} disabled={isPending} onClick={handleApprove}>
            {isPending ? 'Approving…' : 'Approve RWA'}
          </button>
        ) : (
          <button
            style={{ ...styles.btnPrimary, opacity: depositWei <= 0n ? 0.5 : 1 }}
            disabled={isPending || depositWei <= 0n}
            onClick={handleDeposit}
          >
            {isPending ? 'Depositing…' : 'Deposit'}
          </button>
        )}

        <h3 style={{ ...styles.cardTitle, marginTop: '1.5rem' }}>Redeem Shares</h3>
        <label style={styles.label}>Shares (vRWA) to redeem</label>
        <div style={styles.inputRow}>
          <input
            style={styles.input} type="number" min="0" placeholder="0.0"
            value={redeemAmount} onChange={e => setRedeemAmount(e.target.value)}
          />
          <button
            style={styles.maxBtn}
            onClick={() => userShares != null && setRedeemAmount(formatEther(userShares))}
          >MAX</button>
        </div>
        <button
          style={{ ...styles.btnPrimary, background: '#4a5568', opacity: redeemWei <= 0n ? 0.5 : 1 }}
          disabled={isPending || redeemWei <= 0n}
          onClick={handleRedeem}
        >
          {isPending ? 'Redeeming…' : 'Redeem'}
        </button>

        {isSuccess && <p style={styles.success}>Transaction confirmed!</p>}
      </div>
    </div>
  )
}

function fmt(v: bigint | undefined, d = 4): string {
  if (v == null) return '—'
  return parseFloat(formatEther(v)).toLocaleString('en-US', { maximumFractionDigits: d })
}

function Row({ label, value, highlight }: { label: string; value: string; highlight?: boolean }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '0.55rem' }}>
      <span style={{ fontSize: '0.82rem', color: '#718096' }}>{label}</span>
      <span style={{ fontSize: '0.82rem', fontWeight: 600, color: highlight ? '#68d391' : '#f7fafc' }}>{value}</span>
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  grid: { display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))', gap: '1rem' },
  card: { background: '#161b26', border: '1px solid #2d3748', borderRadius: '12px', padding: '1.5rem' },
  cardTitle: { fontSize: '0.95rem', fontWeight: 700, color: '#a78bfa', marginBottom: '1rem' },
  divider: { borderTop: '1px solid #2d3748', margin: '1rem 0' },
  label: { display: 'block', fontSize: '0.78rem', color: '#718096', marginBottom: '6px' },
  inputRow: { display: 'flex', gap: '8px', marginBottom: '6px' },
  input: {
    flex: 1, background: '#0f1117', border: '1px solid #4a5568', borderRadius: '8px',
    color: '#f7fafc', padding: '10px 12px', fontSize: '0.95rem', outline: 'none',
  },
  maxBtn: {
    background: '#7c3aed', border: 'none', borderRadius: '8px',
    color: '#fff', cursor: 'pointer', padding: '0 14px', fontSize: '0.8rem', fontWeight: 700,
  },
  btnPrimary: {
    display: 'block', width: '100%', marginTop: '10px',
    padding: '11px', borderRadius: '10px', border: 'none', cursor: 'pointer',
    background: '#7c3aed', color: '#fff', fontSize: '0.9rem', fontWeight: 700,
  },
  warn: { color: '#718096', fontSize: '0.85rem', marginTop: '12px', textAlign: 'center' },
  success: { color: '#68d391', fontSize: '0.82rem', marginTop: '10px', textAlign: 'center' },
}
