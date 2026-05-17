import { useState } from 'react'
import { useAccount, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { parseEther, formatEther, maxUint256 } from 'viem'
import { ADDRESSES, isDeployed } from '../addresses'
import { GOV_TOKEN_ABI, RWA_TOKEN_ABI, RWA_POOL_ABI, ERC20_ABI } from '../abis'

export function SwapPanel() {
  const { address, isConnected } = useAccount()
  const [inputIsGov, setInputIsGov] = useState(true)
  const [amountIn, setAmountIn] = useState('')
  const [slippage, setSlippage] = useState('0.5')
  const deployed = isDeployed(ADDRESSES.rwaPool)

  const { data, refetch } = useReadContracts({
    contracts: [
      { address: ADDRESSES.rwaPool, abi: RWA_POOL_ABI, functionName: 'reserve0' },
      { address: ADDRESSES.rwaPool, abi: RWA_POOL_ABI, functionName: 'reserve1' },
      {
        address: inputIsGov ? ADDRESSES.govToken : ADDRESSES.rwaToken,
        abi: ERC20_ABI, functionName: 'allowance',
        args: [address ?? '0x0', ADDRESSES.rwaPool],
      },
      {
        address: inputIsGov ? ADDRESSES.govToken : ADDRESSES.rwaToken,
        abi: ERC20_ABI, functionName: 'balanceOf',
        args: [address ?? '0x0'],
      },
    ],
    query: { enabled: isConnected && deployed },
  })

  const reserve0 = data?.[0]?.result as bigint | undefined
  const reserve1 = data?.[1]?.result as bigint | undefined
  const allowance = data?.[2]?.result as bigint | undefined
  const balance = data?.[3]?.result as bigint | undefined

  const amountInWei = (() => {
    try { return amountIn ? parseEther(amountIn) : 0n } catch { return 0n }
  })()

  // Compute estimated output using pool formula
  const { data: estimatedOut } = useReadContracts({
    contracts: [{
      address: ADDRESSES.rwaPool, abi: RWA_POOL_ABI, functionName: 'getAmountOut',
      args: [
        amountInWei,
        inputIsGov ? (reserve0 ?? 0n) : (reserve1 ?? 0n),
        inputIsGov ? (reserve1 ?? 0n) : (reserve0 ?? 0n),
      ],
    }],
    query: { enabled: amountInWei > 0n && !!reserve0 && !!reserve1 },
  })
  const outWei = estimatedOut?.[0]?.result as bigint | undefined

  const slippagePct = parseFloat(slippage) / 100
  const minOut = outWei ? (outWei * BigInt(Math.floor((1 - slippagePct) * 10000))) / 10000n : 0n

  const needsApproval = allowance !== undefined && amountInWei > 0n && allowance < amountInWei

  const { writeContract: approveWrite, data: approveTxHash, isPending: approvePending } = useWriteContract()
  const { writeContract: swapWrite, data: swapTxHash, isPending: swapPending } = useWriteContract()

  const { isSuccess: approveSuccess } = useWaitForTransactionReceipt({ hash: approveTxHash })
  const { isSuccess: swapSuccess } = useWaitForTransactionReceipt({ hash: swapTxHash })

  if (approveSuccess || swapSuccess) {
    refetch()
  }

  const handleApprove = () => {
    approveWrite({
      address: inputIsGov ? ADDRESSES.govToken : ADDRESSES.rwaToken,
      abi: ERC20_ABI, functionName: 'approve',
      args: [ADDRESSES.rwaPool, maxUint256],
    })
  }

  const handleSwap = () => {
    swapWrite({
      address: ADDRESSES.rwaPool, abi: RWA_POOL_ABI, functionName: 'swap',
      args: [
        inputIsGov ? ADDRESSES.govToken : ADDRESSES.rwaToken,
        amountInWei,
        minOut,
      ],
    })
  }

  if (!deployed) {
    return <p style={{ color: '#718096' }}>Pool not yet deployed. Set VITE_RWA_POOL in .env</p>
  }

  const inputLabel  = inputIsGov ? 'RWAGOV' : 'RWA'
  const outputLabel = inputIsGov ? 'RWA' : 'RWAGOV'
  const balFmt = balance != null ? `${parseFloat(formatEther(balance)).toFixed(4)} ${inputLabel}` : '—'
  const outFmt = outWei != null ? `~${parseFloat(formatEther(outWei)).toFixed(6)} ${outputLabel}` : '—'

  return (
    <div style={styles.card}>
      <h3 style={styles.cardTitle}>Swap Tokens</h3>

      {/* Direction toggle */}
      <div style={styles.directionRow}>
        <span style={styles.tokenBadge}>{inputLabel}</span>
        <button style={styles.arrowBtn} onClick={() => setInputIsGov(v => !v)} title="Flip direction">
          ⇄
        </button>
        <span style={styles.tokenBadge}>{outputLabel}</span>
      </div>

      {/* Amount input */}
      <label style={styles.label}>Amount in ({inputLabel})</label>
      <div style={styles.inputRow}>
        <input
          style={styles.input}
          type="number"
          min="0"
          placeholder="0.0"
          value={amountIn}
          onChange={e => setAmountIn(e.target.value)}
        />
        <button
          style={styles.maxBtn}
          onClick={() => balance != null && setAmountIn(formatEther(balance))}
        >
          MAX
        </button>
      </div>
      <p style={styles.hint}>Balance: {balFmt}</p>

      {/* Slippage */}
      <label style={styles.label}>Slippage tolerance (%)</label>
      <input
        style={{ ...styles.input, width: '100px' }}
        type="number" min="0.01" max="50" step="0.1"
        value={slippage}
        onChange={e => setSlippage(e.target.value)}
      />

      {/* Output estimate */}
      <div style={styles.outputBox}>
        <span style={styles.outputLabel}>Estimated output</span>
        <span style={styles.outputValue}>{outFmt}</span>
      </div>
      {!!(outWei && outWei > 0n) && (
        <p style={styles.hint}>
          Min received (after {slippage}% slippage): {parseFloat(formatEther(minOut)).toFixed(6)} {outputLabel}
        </p>
      )}

      {/* CTA */}
      {!isConnected ? (
        <p style={styles.warn}>Connect wallet to swap.</p>
      ) : needsApproval ? (
        <button
          style={styles.btnPrimary}
          disabled={approvePending}
          onClick={handleApprove}
        >
          {approvePending ? 'Approving…' : `Approve ${inputLabel}`}
        </button>
      ) : (
        <button
          style={{ ...styles.btnPrimary, opacity: amountInWei <= 0n ? 0.5 : 1 }}
          disabled={swapPending || amountInWei <= 0n}
          onClick={handleSwap}
        >
          {swapPending ? 'Swapping…' : 'Swap'}
        </button>
      )}

      {swapSuccess && <p style={styles.success}>Swap confirmed!</p>}
      {approveSuccess && <p style={styles.success}>Approval confirmed! You can now swap.</p>}
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  card: {
    background: '#161b26', border: '1px solid #2d3748', borderRadius: '12px',
    padding: '1.5rem', maxWidth: '460px',
  },
  cardTitle: { fontSize: '0.95rem', fontWeight: 700, color: '#a78bfa', marginBottom: '1.2rem' },
  directionRow: { display: 'flex', alignItems: 'center', gap: '12px', marginBottom: '1.2rem' },
  tokenBadge: {
    background: '#2d3748', color: '#a0aec0', padding: '5px 14px',
    borderRadius: '20px', fontSize: '0.88rem', fontWeight: 600,
  },
  arrowBtn: {
    background: '#3d4a63', border: 'none', borderRadius: '8px',
    color: '#a0aec0', cursor: 'pointer', fontSize: '1.1rem', padding: '4px 10px',
  },
  label: { display: 'block', fontSize: '0.78rem', color: '#718096', marginBottom: '6px', marginTop: '14px' },
  inputRow: { display: 'flex', gap: '8px' },
  input: {
    flex: 1, background: '#0f1117', border: '1px solid #4a5568', borderRadius: '8px',
    color: '#f7fafc', padding: '10px 12px', fontSize: '0.95rem', outline: 'none', width: '100%',
  },
  maxBtn: {
    background: '#7c3aed', border: 'none', borderRadius: '8px',
    color: '#fff', cursor: 'pointer', padding: '0 14px', fontSize: '0.8rem', fontWeight: 700,
  },
  hint: { fontSize: '0.75rem', color: '#718096', marginTop: '4px' },
  outputBox: {
    display: 'flex', justifyContent: 'space-between', alignItems: 'center',
    background: '#0f1117', border: '1px solid #2d3748', borderRadius: '8px',
    padding: '12px', marginTop: '16px',
  },
  outputLabel: { fontSize: '0.8rem', color: '#718096' },
  outputValue: { fontSize: '1rem', fontWeight: 700, color: '#68d391' },
  btnPrimary: {
    display: 'block', width: '100%', marginTop: '18px',
    padding: '12px', borderRadius: '10px', border: 'none', cursor: 'pointer',
    background: '#7c3aed', color: '#fff', fontSize: '0.95rem', fontWeight: 700,
  },
  warn: { color: '#718096', fontSize: '0.85rem', marginTop: '12px', textAlign: 'center' },
  success: { color: '#68d391', fontSize: '0.82rem', marginTop: '10px', textAlign: 'center' },
}
