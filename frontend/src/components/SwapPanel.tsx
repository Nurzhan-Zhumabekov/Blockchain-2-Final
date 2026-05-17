import { useState } from 'react'
import { useAccount, useReadContracts, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { parseEther, formatEther, maxUint256 } from 'viem'
import { ADDRESSES, isDeployed } from '../addresses'
import { GOV_TOKEN_ABI, RWA_TOKEN_ABI, RWA_POOL_ABI, ERC20_ABI } from '../abis'

export function SwapPanel() {
  const { address, isConnected } = useAccount()
  const [inputIsGov, setInputIsGov]   = useState(true)
  const [amountIn, setAmountIn]       = useState('')
  const [slippage, setSlippage]       = useState('0.5')
  const [govAmt, setGovAmt]           = useState('')
  const [rwaAmt, setRwaAmt]           = useState('')
  const [lpRedeem, setLpRedeem]       = useState('')
  const deployed = isDeployed(ADDRESSES.rwaPool)

  const { data, refetch } = useReadContracts({
    contracts: [
      { address: ADDRESSES.rwaPool,  abi: RWA_POOL_ABI, functionName: 'reserve0' },
      { address: ADDRESSES.rwaPool,  abi: RWA_POOL_ABI, functionName: 'reserve1' },
      { address: ADDRESSES.rwaPool,  abi: RWA_POOL_ABI, functionName: 'totalSupply' },
      { address: ADDRESSES.rwaPool,  abi: RWA_POOL_ABI, functionName: 'balanceOf', args: [address ?? '0x0'] },
      { address: ADDRESSES.govToken, abi: ERC20_ABI,    functionName: 'balanceOf', args: [address ?? '0x0'] },
      { address: ADDRESSES.rwaToken, abi: ERC20_ABI,    functionName: 'balanceOf', args: [address ?? '0x0'] },
      { address: ADDRESSES.govToken, abi: ERC20_ABI,    functionName: 'allowance', args: [address ?? '0x0', ADDRESSES.rwaPool] },
      { address: ADDRESSES.rwaToken, abi: ERC20_ABI,    functionName: 'allowance', args: [address ?? '0x0', ADDRESSES.rwaPool] },
    ],
    query: { enabled: deployed },
  })

  const reserve0    = data?.[0]?.result as bigint | undefined
  const reserve1    = data?.[1]?.result as bigint | undefined
  const lpTotal     = data?.[2]?.result as bigint | undefined
  const lpBalance   = data?.[3]?.result as bigint | undefined
  const govBalance  = data?.[4]?.result as bigint | undefined
  const rwaBalance  = data?.[5]?.result as bigint | undefined
  const govAllowance = data?.[6]?.result as bigint | undefined
  const rwaAllowance = data?.[7]?.result as bigint | undefined

  // ── Swap logic ──────────────────────────────────────────────────────────────
  const swapBalance  = inputIsGov ? govBalance  : rwaBalance
  const swapAllowance = inputIsGov ? govAllowance : rwaAllowance

  const amountInWei = (() => { try { return amountIn ? parseEther(amountIn) : 0n } catch { return 0n } })()

  const { data: estimatedOut } = useReadContracts({
    contracts: [{
      address: ADDRESSES.rwaPool, abi: RWA_POOL_ABI, functionName: 'getAmountOut',
      args: [amountInWei, inputIsGov ? (reserve0 ?? 0n) : (reserve1 ?? 0n), inputIsGov ? (reserve1 ?? 0n) : (reserve0 ?? 0n)],
    }],
    query: { enabled: amountInWei > 0n && !!reserve0 && !!reserve1 },
  })
  const outWei = estimatedOut?.[0]?.result as bigint | undefined
  const slippagePct = parseFloat(slippage) / 100
  const minOut = outWei ? (outWei * BigInt(Math.floor((1 - slippagePct) * 10000))) / 10000n : 0n

  const swapNeedsApproval = swapAllowance !== undefined && amountInWei > 0n && swapAllowance < amountInWei

  // ── Liquidity logic ──────────────────────────────────────────────────────────
  const govAmtWei = (() => { try { return govAmt ? parseEther(govAmt) : 0n } catch { return 0n } })()
  const rwaAmtWei = (() => { try { return rwaAmt ? parseEther(rwaAmt) : 0n } catch { return 0n } })()
  const lpRedeemWei = (() => { try { return lpRedeem ? parseEther(lpRedeem) : 0n } catch { return 0n } })()

  const govNeedsApproval = govAllowance !== undefined && govAmtWei > 0n && govAllowance < govAmtWei
  const rwaNeedsApproval = rwaAllowance !== undefined && rwaAmtWei > 0n && rwaAllowance < rwaAmtWei

  // Auto-fill the paired token amount based on current pool ratio
  const handleGovAmtChange = (v: string) => {
    setGovAmt(v)
    if (reserve0 && reserve1 && reserve0 > 0n && v) {
      try {
        const g = parseEther(v)
        setRwaAmt(formatEther((g * reserve1) / reserve0))
      } catch { /* ignore */ }
    }
  }
  const handleRwaAmtChange = (v: string) => {
    setRwaAmt(v)
    if (reserve0 && reserve1 && reserve1 > 0n && v) {
      try {
        const r = parseEther(v)
        setGovAmt(formatEther((r * reserve0) / reserve1))
      } catch { /* ignore */ }
    }
  }

  // ── Write contracts ──────────────────────────────────────────────────────────
  const { writeContract: approveGov,  data: approveGovHash,  isPending: approvingGov }  = useWriteContract()
  const { writeContract: approveRwa,  data: approveRwaHash,  isPending: approvingRwa }  = useWriteContract()
  const { writeContract: swapWrite,   data: swapHash,         isPending: swapPending }   = useWriteContract()
  const { writeContract: addLiqWrite, data: addLiqHash,       isPending: addLiqPending } = useWriteContract()
  const { writeContract: remLiqWrite, data: remLiqHash,       isPending: remLiqPending } = useWriteContract()

  const { isSuccess: approveGovOk } = useWaitForTransactionReceipt({ hash: approveGovHash })
  const { isSuccess: approveRwaOk } = useWaitForTransactionReceipt({ hash: approveRwaHash })
  const { isSuccess: swapOk }       = useWaitForTransactionReceipt({ hash: swapHash })
  const { isSuccess: addLiqOk }     = useWaitForTransactionReceipt({ hash: addLiqHash })
  const { isSuccess: remLiqOk }     = useWaitForTransactionReceipt({ hash: remLiqHash })

  if (approveGovOk || approveRwaOk || swapOk || addLiqOk || remLiqOk) refetch()

  const handleApproveSwap = () => {
    const write = inputIsGov ? approveGov : approveRwa
    write({
      address: inputIsGov ? ADDRESSES.govToken : ADDRESSES.rwaToken,
      abi: ERC20_ABI, functionName: 'approve',
      args: [ADDRESSES.rwaPool, maxUint256],
    })
  }

  const handleSwap = () => swapWrite({
    address: ADDRESSES.rwaPool, abi: RWA_POOL_ABI, functionName: 'swap',
    args: [inputIsGov ? ADDRESSES.govToken : ADDRESSES.rwaToken, amountInWei, minOut],
  })

  const handleApproveGov = () => approveGov({
    address: ADDRESSES.govToken, abi: ERC20_ABI, functionName: 'approve',
    args: [ADDRESSES.rwaPool, maxUint256],
  })
  const handleApproveRwa = () => approveRwa({
    address: ADDRESSES.rwaToken, abi: ERC20_ABI, functionName: 'approve',
    args: [ADDRESSES.rwaPool, maxUint256],
  })

  const handleAddLiquidity = () => {
    const slipBps = BigInt(Math.floor((1 - slippagePct) * 10000))
    addLiqWrite({
      address: ADDRESSES.rwaPool, abi: RWA_POOL_ABI, functionName: 'addLiquidity',
      args: [govAmtWei, rwaAmtWei, (govAmtWei * slipBps) / 10000n, (rwaAmtWei * slipBps) / 10000n],
    })
  }

  const handleRemoveLiquidity = () => remLiqWrite({
    address: ADDRESSES.rwaPool, abi: RWA_POOL_ABI, functionName: 'removeLiquidity',
    args: [lpRedeemWei, 0n, 0n],
  })

  if (!deployed) {
    return <p style={{ color: '#718096' }}>Pool not yet deployed. Set VITE_RWA_POOL in .env</p>
  }

  const inputLabel  = inputIsGov ? 'RWAGOV' : 'RWA'
  const outputLabel = inputIsGov ? 'RWA' : 'RWAGOV'
  const swapBalFmt  = swapBalance != null ? `${parseFloat(formatEther(swapBalance)).toFixed(4)} ${inputLabel}` : '—'
  const outFmt      = outWei != null ? `~${parseFloat(formatEther(outWei)).toFixed(6)} ${outputLabel}` : '—'
  const anyLiqPending = addLiqPending || remLiqPending || approvingGov || approvingRwa

  return (
    <div style={styles.grid}>
      {/* Swap card */}
      <div style={styles.card}>
        <h3 style={styles.cardTitle}>Swap Tokens</h3>

        <div style={styles.directionRow}>
          <span style={styles.tokenBadge}>{inputLabel}</span>
          <button style={styles.arrowBtn} onClick={() => setInputIsGov(v => !v)} title="Flip direction">⇄</button>
          <span style={styles.tokenBadge}>{outputLabel}</span>
        </div>

        <label style={styles.label}>Amount in ({inputLabel})</label>
        <div style={styles.inputRow}>
          <input
            style={styles.input} type="number" min="0" placeholder="0.0"
            value={amountIn} onChange={e => setAmountIn(e.target.value)}
          />
          <button style={styles.maxBtn} onClick={() => swapBalance != null && setAmountIn(formatEther(swapBalance))}>MAX</button>
        </div>
        <p style={styles.hint}>Balance: {swapBalFmt}</p>

        <label style={styles.label}>Slippage tolerance (%)</label>
        <input
          style={{ ...styles.input, width: '100px' }} type="number" min="0.01" max="50" step="0.1"
          value={slippage} onChange={e => setSlippage(e.target.value)}
        />

        <div style={styles.outputBox}>
          <span style={styles.outputLabel}>Estimated output</span>
          <span style={styles.outputValue}>{outFmt}</span>
        </div>
        {!!(outWei && outWei > 0n) && (
          <p style={styles.hint}>
            Min received ({slippage}% slippage): {parseFloat(formatEther(minOut)).toFixed(6)} {outputLabel}
          </p>
        )}

        {!isConnected ? (
          <p style={styles.warn}>Connect wallet to swap.</p>
        ) : swapNeedsApproval ? (
          <button style={styles.btnPrimary} disabled={approvingGov || approvingRwa} onClick={handleApproveSwap}>
            {(approvingGov || approvingRwa) ? 'Approving…' : `Approve ${inputLabel}`}
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
        {swapOk         && <p style={styles.success}>Swap confirmed!</p>}
        {(approveGovOk || approveRwaOk) && <p style={styles.success}>Approval confirmed!</p>}
      </div>

      {/* Liquidity card */}
      <div style={styles.card}>
        <h3 style={styles.cardTitle}>Liquidity</h3>
        <Row label="Pool reserve (RWAGOV)" value={`${fmt(reserve0)} RWAGOV`} />
        <Row label="Pool reserve (RWA)"    value={`${fmt(reserve1)} RWA`} />
        <Row label="LP total supply"       value={fmt(lpTotal)} />
        <Row label="Your LP shares"        value={fmt(lpBalance)} highlight={!!(lpBalance && lpBalance > 0n)} />

        <div style={styles.divider} />
        <h3 style={{ ...styles.cardTitle, marginBottom: '0.75rem' }}>Add Liquidity</h3>

        <label style={styles.label}>RWAGOV amount</label>
        <div style={styles.inputRow}>
          <input style={styles.input} type="number" min="0" placeholder="0.0"
            value={govAmt} onChange={e => handleGovAmtChange(e.target.value)} />
          <button style={styles.maxBtn} onClick={() => govBalance != null && handleGovAmtChange(formatEther(govBalance))}>MAX</button>
        </div>

        <label style={styles.label}>RWA amount</label>
        <div style={styles.inputRow}>
          <input style={styles.input} type="number" min="0" placeholder="0.0"
            value={rwaAmt} onChange={e => handleRwaAmtChange(e.target.value)} />
          <button style={styles.maxBtn} onClick={() => rwaBalance != null && handleRwaAmtChange(formatEther(rwaBalance))}>MAX</button>
        </div>

        {govNeedsApproval && (
          <button style={styles.btnSecondary} disabled={anyLiqPending} onClick={handleApproveGov}>
            {approvingGov ? 'Approving…' : 'Approve RWAGOV'}
          </button>
        )}
        {rwaNeedsApproval && (
          <button style={{ ...styles.btnSecondary, marginTop: '6px' }} disabled={anyLiqPending} onClick={handleApproveRwa}>
            {approvingRwa ? 'Approving…' : 'Approve RWA'}
          </button>
        )}
        {!govNeedsApproval && !rwaNeedsApproval && (
          <button
            style={{ ...styles.btnPrimary, opacity: govAmtWei <= 0n || rwaAmtWei <= 0n ? 0.5 : 1 }}
            disabled={anyLiqPending || govAmtWei <= 0n || rwaAmtWei <= 0n}
            onClick={handleAddLiquidity}
          >
            {addLiqPending ? 'Adding…' : 'Add Liquidity'}
          </button>
        )}

        <div style={styles.divider} />
        <h3 style={{ ...styles.cardTitle, marginBottom: '0.75rem' }}>Remove Liquidity</h3>
        <label style={styles.label}>LP shares to burn</label>
        <div style={styles.inputRow}>
          <input style={styles.input} type="number" min="0" placeholder="0.0"
            value={lpRedeem} onChange={e => setLpRedeem(e.target.value)} />
          <button style={styles.maxBtn} onClick={() => lpBalance != null && setLpRedeem(formatEther(lpBalance))}>MAX</button>
        </div>
        <button
          style={{ ...styles.btnPrimary, background: '#4a5568', opacity: lpRedeemWei <= 0n ? 0.5 : 1 }}
          disabled={remLiqPending || lpRedeemWei <= 0n}
          onClick={handleRemoveLiquidity}
        >
          {remLiqPending ? 'Removing…' : 'Remove Liquidity'}
        </button>

        {addLiqOk && <p style={styles.success}>Liquidity added!</p>}
        {remLiqOk && <p style={styles.success}>Liquidity removed!</p>}
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
  grid: { display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(340px, 1fr))', gap: '1rem' },
  card: { background: '#161b26', border: '1px solid #2d3748', borderRadius: '12px', padding: '1.5rem' },
  cardTitle: { fontSize: '0.95rem', fontWeight: 700, color: '#a78bfa', marginBottom: '1rem' },
  divider: { borderTop: '1px solid #2d3748', margin: '1rem 0' },
  directionRow: { display: 'flex', alignItems: 'center', gap: '12px', marginBottom: '1.2rem' },
  tokenBadge: {
    background: '#2d3748', color: '#a0aec0', padding: '5px 14px',
    borderRadius: '20px', fontSize: '0.88rem', fontWeight: 600,
  },
  arrowBtn: {
    background: '#3d4a63', border: 'none', borderRadius: '8px',
    color: '#a0aec0', cursor: 'pointer', fontSize: '1.1rem', padding: '4px 10px',
  },
  label: { display: 'block', fontSize: '0.78rem', color: '#718096', marginBottom: '6px', marginTop: '12px' },
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
    display: 'block', width: '100%', marginTop: '10px',
    padding: '11px', borderRadius: '10px', border: 'none', cursor: 'pointer',
    background: '#7c3aed', color: '#fff', fontSize: '0.9rem', fontWeight: 700,
  },
  btnSecondary: {
    display: 'block', width: '100%', marginTop: '10px',
    padding: '11px', borderRadius: '10px', border: 'none', cursor: 'pointer',
    background: '#2d3748', color: '#a0aec0', fontSize: '0.88rem', fontWeight: 600,
  },
  warn: { color: '#718096', fontSize: '0.85rem', marginTop: '12px', textAlign: 'center' },
  success: { color: '#68d391', fontSize: '0.82rem', marginTop: '10px', textAlign: 'center' },
}
