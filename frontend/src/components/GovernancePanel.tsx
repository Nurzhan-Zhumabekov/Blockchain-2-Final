import { useAccount, useReadContracts, useWriteContract, useWaitForTransactionReceipt, useBlockNumber } from 'wagmi'
import { formatEther } from 'viem'
import { ADDRESSES, isDeployed } from '../addresses'
import { GOV_TOKEN_ABI, RWA_GOVERNOR_ABI } from '../abis'

const PROPOSAL_STATES = [
  'Pending', 'Active', 'Canceled', 'Defeated', 'Succeeded', 'Queued', 'Expired', 'Executed',
]

function secondsToHuman(secs: bigint): string {
  const s = Number(secs)
  if (s >= 86400) return `${Math.round(s / 86400)} day(s)`
  if (s >= 3600)  return `${Math.round(s / 3600)} hour(s)`
  return `${s} sec`
}

export function GovernancePanel() {
  const { address, isConnected } = useAccount()
  const deployed = isDeployed(ADDRESSES.rwaGovernor)
  const { data: blockNumber } = useBlockNumber()

  const { data, refetch } = useReadContracts({
    contracts: [
      { address: ADDRESSES.rwaGovernor, abi: RWA_GOVERNOR_ABI, functionName: 'votingDelay' },
      { address: ADDRESSES.rwaGovernor, abi: RWA_GOVERNOR_ABI, functionName: 'votingPeriod' },
      { address: ADDRESSES.rwaGovernor, abi: RWA_GOVERNOR_ABI, functionName: 'proposalThreshold' },
      { address: ADDRESSES.rwaGovernor, abi: RWA_GOVERNOR_ABI, functionName: 'quorumNumerator' },
      { address: ADDRESSES.rwaGovernor, abi: RWA_GOVERNOR_ABI, functionName: 'timelock' },
      { address: ADDRESSES.govToken,    abi: GOV_TOKEN_ABI,    functionName: 'getVotes',  args: [address ?? '0x0'] },
      { address: ADDRESSES.govToken,    abi: GOV_TOKEN_ABI,    functionName: 'delegates', args: [address ?? '0x0'] },
      { address: ADDRESSES.govToken,    abi: GOV_TOKEN_ABI,    functionName: 'balanceOf', args: [address ?? '0x0'] },
    ],
    query: { enabled: isConnected && deployed },
  })

  const votingDelay  = data?.[0]?.result as bigint | undefined
  const votingPeriod = data?.[1]?.result as bigint | undefined
  const threshold    = data?.[2]?.result as bigint | undefined
  const quorum       = data?.[3]?.result as bigint | undefined
  const timelockAddr = data?.[4]?.result as string | undefined
  const votingPower  = data?.[5]?.result as bigint | undefined
  const delegatee    = data?.[6]?.result as string | undefined
  const govBalance   = data?.[7]?.result as bigint | undefined

  const selfDelegated = delegatee && address &&
    delegatee.toLowerCase() === address.toLowerCase()

  const { writeContract, data: txHash, isPending } = useWriteContract()
  const { isSuccess } = useWaitForTransactionReceipt({ hash: txHash })
  if (isSuccess) refetch()

  const handleDelegateSelf = () => writeContract({
    address: ADDRESSES.govToken, abi: GOV_TOKEN_ABI, functionName: 'delegate',
    args: [address!],
  })

  if (!deployed) {
    return <p style={{ color: '#718096' }}>Governor not deployed. Set VITE_RWA_GOVERNOR in .env</p>
  }

  return (
    <div style={styles.grid}>
      {/* Governor parameters */}
      <div style={styles.card}>
        <h3 style={styles.cardTitle}>Governor Parameters</h3>
        <Row label="Voting delay"         value={votingDelay  != null ? secondsToHuman(votingDelay)  : '—'} />
        <Row label="Voting period"        value={votingPeriod != null ? secondsToHuman(votingPeriod) : '—'} />
        <Row label="Proposal threshold"   value={threshold    != null ? `${parseFloat(formatEther(threshold)).toLocaleString()} RWAGOV` : '—'} />
        <Row label="Quorum numerator"     value={quorum       != null ? `${quorum.toString()}%` : '—'} />
        <Row label="Timelock address"     value={timelockAddr ? `${timelockAddr.slice(0, 10)}…` : '—'} />
        <Row label="Current block"        value={blockNumber ? blockNumber.toString() : '—'} />
      </div>

      {/* Voting power */}
      <div style={styles.card}>
        <h3 style={styles.cardTitle}>Your Voting Power</h3>
        <Row label="GOV balance"    value={`${fmt(govBalance)} RWAGOV`} />
        <Row label="Voting power"   value={`${fmt(votingPower)} RWAGOV`} highlight={!selfDelegated} />
        <Row label="Delegated to"
          value={selfDelegated ? 'Self (active)' : delegatee ? `${delegatee.slice(0, 10)}…` : '—'}
        />

        {!selfDelegated && (
          <div style={styles.delegateBox}>
            <p style={styles.hint}>
              Your voting power is 0 because you haven't delegated. Delegate to yourself to activate it.
            </p>
            <button
              style={styles.btnPrimary}
              disabled={isPending || !isConnected}
              onClick={handleDelegateSelf}
            >
              {isPending ? 'Delegating…' : 'Delegate to Self'}
            </button>
          </div>
        )}
        {selfDelegated && (
          <p style={{ ...styles.hint, color: '#68d391', marginTop: '10px' }}>
            Voting power is active.
          </p>
        )}
        {isSuccess && <p style={styles.success}>Delegation confirmed!</p>}
      </div>

      {/* How governance works */}
      <div style={{ ...styles.card, gridColumn: '1 / -1' }}>
        <h3 style={styles.cardTitle}>How to Create a Proposal</h3>
        <ol style={styles.howto}>
          <li>Hold at least <strong>1,000 RWAGOV</strong> and delegate to yourself.</li>
          <li>Call <code>governor.propose(targets, values, calldatas, description)</code> on-chain.</li>
          <li>Wait for the voting delay (<strong>1 day</strong>) before voting opens.</li>
          <li>Voting runs for <strong>1 week</strong>. Quorum requires <strong>4%</strong> of total supply to vote.</li>
          <li>On success, queue in the Timelock. After the <strong>2-day</strong> delay, anyone can execute.</li>
        </ol>
        <p style={{ ...styles.hint, marginTop: '10px' }}>
          For on-chain proposals use Tally, Boardroom, or a direct contract call. This UI supports
          reading governor state and casting votes once a proposal ID is known.
        </p>
      </div>
    </div>
  )
}

function fmt(v: bigint | undefined, d = 2): string {
  if (v == null) return '—'
  return parseFloat(formatEther(v)).toLocaleString('en-US', { maximumFractionDigits: d })
}

function Row({ label, value, highlight }: { label: string; value: string; highlight?: boolean }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '0.55rem' }}>
      <span style={{ fontSize: '0.82rem', color: '#718096' }}>{label}</span>
      <span style={{ fontSize: '0.82rem', fontWeight: 600, color: highlight ? '#fc8181' : '#f7fafc' }}>{value}</span>
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  grid: { display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))', gap: '1rem' },
  card: { background: '#161b26', border: '1px solid #2d3748', borderRadius: '12px', padding: '1.5rem' },
  cardTitle: { fontSize: '0.95rem', fontWeight: 700, color: '#a78bfa', marginBottom: '1rem' },
  delegateBox: { background: '#1a1f2e', borderRadius: '8px', padding: '12px', marginTop: '10px' },
  hint: { fontSize: '0.78rem', color: '#a0aec0' },
  btnPrimary: {
    display: 'block', width: '100%', marginTop: '10px',
    padding: '11px', borderRadius: '10px', border: 'none', cursor: 'pointer',
    background: '#7c3aed', color: '#fff', fontSize: '0.9rem', fontWeight: 700,
  },
  success: { color: '#68d391', fontSize: '0.82rem', marginTop: '10px', textAlign: 'center' },
  howto: { paddingLeft: '1.3rem', lineHeight: 2, fontSize: '0.85rem', color: '#a0aec0' },
}
