import { useState } from 'react'
import { useAccount, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { parseEther, formatEther, maxUint256 } from 'viem'
import { ADDRESSES, isDeployed } from '../addresses'
import { RWA_STAKING_ABI, ERC20_ABI } from '../abis'

export function StakePanel() {
  const { address, isConnected } = useAccount()
  const [stakeAmount, setStakeAmount] = useState('')
  const [withdrawAmount, setWithdrawAmount] = useState('')
  const deployed = isDeployed(ADDRESSES.rwaStaking)

  const { data, refetch } = useReadContracts({
    contracts: [
      { address: ADDRESSES.rwaStaking, abi: RWA_STAKING_ABI, functionName: 'staked', args: [address ?? '0x0'] },
      { address: ADDRESSES.rwaStaking, abi: RWA_STAKING_ABI, functionName: 'earned', args: [address ?? '0x0'] },
      { address: ADDRESSES.rwaStaking, abi: RWA_STAKING_ABI, functionName: 'totalStaked' },
      { address: ADDRESSES.rwaStaking, abi: RWA_STAKING_ABI, functionName: 'rewardRate' },
      {
        address: ADDRESSES.govToken, abi: ERC20_ABI, functionName: 'balanceOf',
        args: [address ?? '0x0'],
      },
      {
        address: ADDRESSES.govToken, abi: ERC20_ABI, functionName: 'allowance',
        args: [address ?? '0x0', ADDRESSES.rwaStaking],
      },
    ],
    query: { enabled: isConnected && deployed },
  })

  const userStaked  = data?.[0]?.result as bigint | undefined
  const earned      = data?.[1]?.result as bigint | undefined
  const totalStaked = data?.[2]?.result as bigint | undefined
  const rewardRate  = data?.[3]?.result as bigint | undefined
  const govBalance  = data?.[4]?.result as bigint | undefined
  const allowance   = data?.[5]?.result as bigint | undefined

  const stakeWei = (() => { try { return stakeAmount ? parseEther(stakeAmount) : 0n } catch { return 0n } })()
  const needsApproval = allowance !== undefined && stakeWei > 0n && allowance < stakeWei

  const { writeContract, data: txHash, isPending } = useWriteContract()
  const { isSuccess } = useWaitForTransactionReceipt({ hash: txHash })
  if (isSuccess) refetch()

  const handleApprove = () => writeContract({
    address: ADDRESSES.govToken, abi: ERC20_ABI, functionName: 'approve',
    args: [ADDRESSES.rwaStaking, maxUint256],
  })

  const handleStake = () => writeContract({
    address: ADDRESSES.rwaStaking, abi: RWA_STAKING_ABI, functionName: 'stake',
    args: [stakeWei],
  })

  const handleWithdraw = () => {
    try {
      const w = parseEther(withdrawAmount)
      writeContract({ address: ADDRESSES.rwaStaking, abi: RWA_STAKING_ABI, functionName: 'withdraw', args: [w] })
    } catch { /* invalid input */ }
  }

  const handleClaim = () => writeContract({
    address: ADDRESSES.rwaStaking, abi: RWA_STAKING_ABI, functionName: 'claimReward',
  })

  const handleExit = () => writeContract({
    address: ADDRESSES.rwaStaking, abi: RWA_STAKING_ABI, functionName: 'exit',
  })

  const apr = rewardRate && totalStaked && totalStaked > 0n
    ? ((Number(formatEther(rewardRate)) * 365 * 24 * 3600) / Number(formatEther(totalStaked)) * 100).toFixed(2)
    : '—'

  if (!deployed) {
    return <p style={{ color: '#718096' }}>Staking not yet deployed. Set VITE_RWA_STAKING in .env</p>
  }

  return (
    <div style={styles.grid}>
      {/* Stats card */}
      <div style={styles.card}>
        <h3 style={styles.cardTitle}>Your Position</h3>
        <Row label="Staked"         value={`${fmt(userStaked)} RWAGOV`} />
        <Row label="Earned rewards" value={`${fmt(earned)} RWAGOV`} highlight />
        <Row label="Total staked"   value={`${fmt(totalStaked)} RWAGOV`} />
        <Row label="Reward rate"    value={`${fmt(rewardRate)} / sec`} />
        <Row label="Est. APR"       value={`${apr}%`} />
        <Row label="Wallet balance" value={`${fmt(govBalance)} RWAGOV`} />

        {!!(earned && earned > 0n) && (
          <button style={{ ...styles.btn, marginTop: '14px' }} onClick={handleClaim} disabled={isPending}>
            {isPending ? 'Claiming…' : `Claim ${fmt(earned)} RWAGOV`}
          </button>
        )}
        {!!(userStaked && userStaked > 0n) && (
          <button style={{ ...styles.btnDanger, marginTop: '8px' }} onClick={handleExit} disabled={isPending}>
            Exit (withdraw all + claim)
          </button>
        )}
        {isSuccess && <p style={styles.success}>Transaction confirmed!</p>}
      </div>

      {/* Stake form */}
      <div style={styles.card}>
        <h3 style={styles.cardTitle}>Stake RWAGOV</h3>
        <label style={styles.label}>Amount</label>
        <div style={styles.inputRow}>
          <input
            style={styles.input} type="number" min="0" placeholder="0.0"
            value={stakeAmount} onChange={e => setStakeAmount(e.target.value)}
          />
          <button
            style={styles.maxBtn}
            onClick={() => govBalance != null && setStakeAmount(formatEther(govBalance))}
          >MAX</button>
        </div>

        {!isConnected ? (
          <p style={styles.warn}>Connect wallet to stake.</p>
        ) : needsApproval ? (
          <button style={styles.btnPrimary} disabled={isPending} onClick={handleApprove}>
            {isPending ? 'Approving…' : 'Approve RWAGOV'}
          </button>
        ) : (
          <button
            style={{ ...styles.btnPrimary, opacity: stakeWei <= 0n ? 0.5 : 1 }}
            disabled={isPending || stakeWei <= 0n}
            onClick={handleStake}
          >
            {isPending ? 'Staking…' : 'Stake'}
          </button>
        )}

        <h3 style={{ ...styles.cardTitle, marginTop: '1.5rem' }}>Withdraw</h3>
        <label style={styles.label}>Amount to withdraw</label>
        <div style={styles.inputRow}>
          <input
            style={styles.input} type="number" min="0" placeholder="0.0"
            value={withdrawAmount} onChange={e => setWithdrawAmount(e.target.value)}
          />
          <button
            style={styles.maxBtn}
            onClick={() => userStaked != null && setWithdrawAmount(formatEther(userStaked))}
          >MAX</button>
        </div>
        <button
          style={{ ...styles.btnPrimary, background: '#4a5568', opacity: !withdrawAmount ? 0.5 : 1 }}
          disabled={isPending || !withdrawAmount}
          onClick={handleWithdraw}
        >
          {isPending ? 'Withdrawing…' : 'Withdraw'}
        </button>
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
  btn: {
    display: 'block', width: '100%',
    padding: '11px', borderRadius: '10px', border: 'none', cursor: 'pointer',
    background: '#2f855a', color: '#fff', fontSize: '0.9rem', fontWeight: 700,
  },
  btnDanger: {
    display: 'block', width: '100%',
    padding: '11px', borderRadius: '10px', border: 'none', cursor: 'pointer',
    background: '#742a2a', color: '#fff', fontSize: '0.88rem', fontWeight: 600,
  },
  warn: { color: '#718096', fontSize: '0.85rem', marginTop: '12px', textAlign: 'center' },
  success: { color: '#68d391', fontSize: '0.82rem', marginTop: '10px', textAlign: 'center' },
}
