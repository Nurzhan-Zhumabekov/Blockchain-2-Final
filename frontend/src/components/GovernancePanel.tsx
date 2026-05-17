import { useEffect, useState } from 'react'
import {
  useAccount,
  useReadContracts,
  useWriteContract,
  useWaitForTransactionReceipt,
  useBlockNumber,
} from 'wagmi'
import { formatEther } from 'viem'
import { ADDRESSES, isDeployed } from '../addresses'
import { GOV_TOKEN_ABI, RWA_GOVERNOR_ABI } from '../abis'

// ── Types ─────────────────────────────────────────────────────────────────────

interface GqlProposal {
  id: string
  proposer: string
  description: string
  state: string
  forVotes: string
  againstVotes: string
  abstainVotes: string
  startBlock: string
  endBlock: string
  createdAt: string
}

// ── The Graph query ───────────────────────────────────────────────────────────

const SUBGRAPH_URL = import.meta.env.VITE_SUBGRAPH_URL as string | undefined

const PROPOSALS_QUERY = `
  query {
    governanceProposals(
      first: 20
      orderBy: createdAt
      orderDirection: desc
    ) {
      id
      proposer
      description
      state
      forVotes
      againstVotes
      abstainVotes
      startBlock
      endBlock
      createdAt
    }
  }
`

async function fetchProposals(): Promise<GqlProposal[]> {
  if (!SUBGRAPH_URL) return []
  const res = await fetch(SUBGRAPH_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: PROPOSALS_QUERY }),
  })
  const json = await res.json()
  return json?.data?.governanceProposals ?? []
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const PROPOSAL_STATES = [
  'Pending', 'Active', 'Canceled', 'Defeated',
  'Succeeded', 'Queued', 'Expired', 'Executed',
]

function stateColor(state: string): string {
  if (state === 'Active')    return '#68d391'
  if (state === 'Executed')  return '#4299e1'
  if (state === 'Queued')    return '#f6e05e'
  if (state === 'Succeeded') return '#9ae6b4'
  if (state === 'Canceled' || state === 'Defeated' || state === 'Expired') return '#fc8181'
  return '#a0aec0'
}

function secondsToHuman(secs: bigint): string {
  const s = Number(secs)
  if (s >= 86400) return `${Math.round(s / 86400)} day(s)`
  if (s >= 3600)  return `${Math.round(s / 3600)} hr(s)`
  return `${s} sec`
}

function shortAddr(addr: string): string {
  return addr.length >= 10 ? `${addr.slice(0, 8)}…` : addr
}

function fmt(v: bigint | undefined, d = 2): string {
  if (v == null) return '—'
  return parseFloat(formatEther(v)).toLocaleString('en-US', { maximumFractionDigits: d })
}

function fmtBD(v: string, d = 2): string {
  const n = parseFloat(v) / 1e18
  return isNaN(n) ? '0' : n.toLocaleString('en-US', { maximumFractionDigits: d })
}

// ── Sub-components ────────────────────────────────────────────────────────────

function Row({ label, value, highlight }: { label: string; value: string; highlight?: boolean }) {
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '0.55rem' }}>
      <span style={{ fontSize: '0.82rem', color: '#718096' }}>{label}</span>
      <span style={{ fontSize: '0.82rem', fontWeight: 600, color: highlight ? '#fc8181' : '#f7fafc' }}>
        {value}
      </span>
    </div>
  )
}

// ── ProposalCard ──────────────────────────────────────────────────────────────

function ProposalCard({ proposal }: { proposal: GqlProposal }) {
  const { address, isConnected } = useAccount()
  const [votePending, setVotePending] = useState(false)

  const { writeContract, data: txHash, isPending } = useWriteContract()
  const { isSuccess, isError } = useWaitForTransactionReceipt({ hash: txHash })

  const canVote = proposal.state === 'Active' && isConnected

  function castVote(support: number) {
    if (!isDeployed(ADDRESSES.rwaGovernor)) return
    setVotePending(true)
    writeContract({
      address: ADDRESSES.rwaGovernor,
      abi: RWA_GOVERNOR_ABI,
      functionName: 'castVote',
      args: [BigInt(proposal.id), support as 0 | 1 | 2],
    })
  }

  const totalVotes =
    parseFloat(proposal.forVotes) +
    parseFloat(proposal.againstVotes) +
    parseFloat(proposal.abstainVotes)

  const forPct   = totalVotes > 0 ? (parseFloat(proposal.forVotes)     / totalVotes) * 100 : 0
  const againPct = totalVotes > 0 ? (parseFloat(proposal.againstVotes) / totalVotes) * 100 : 0

  const desc = proposal.description.length > 120
    ? proposal.description.slice(0, 120) + '…'
    : proposal.description

  return (
    <div style={styles.proposalCard}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: '0.6rem' }}>
        <span style={{ fontSize: '0.72rem', color: '#718096', maxWidth: '70%', wordBreak: 'break-all' }}>
          #{proposal.id.slice(0, 20)}…
        </span>
        <span style={{ fontSize: '0.72rem', fontWeight: 700, color: stateColor(proposal.state) }}>
          {proposal.state}
        </span>
      </div>

      <p style={{ fontSize: '0.85rem', color: '#f7fafc', marginBottom: '0.8rem', lineHeight: 1.5 }}>
        {desc}
      </p>

      <div style={{ fontSize: '0.75rem', color: '#718096', marginBottom: '0.8rem' }}>
        Proposer: {shortAddr(proposal.proposer)}
      </div>

      {/* Vote bars */}
      <div style={styles.voteRow}>
        <div style={{ ...styles.voteBar, background: '#276749' }}>
          <div style={{ ...styles.voteFill, width: `${forPct}%`, background: '#68d391' }} />
        </div>
        <span style={styles.voteLabel}>For: {fmtBD(proposal.forVotes)}</span>
      </div>
      <div style={styles.voteRow}>
        <div style={{ ...styles.voteBar, background: '#742a2a' }}>
          <div style={{ ...styles.voteFill, width: `${againPct}%`, background: '#fc8181' }} />
        </div>
        <span style={styles.voteLabel}>Against: {fmtBD(proposal.againstVotes)}</span>
      </div>
      <div style={{ fontSize: '0.72rem', color: '#4a5568', marginBottom: '0.8rem' }}>
        Abstain: {fmtBD(proposal.abstainVotes)}
      </div>

      {/* Vote buttons — only shown for Active proposals */}
      {canVote && (
        <div style={{ display: 'flex', gap: '0.5rem', flexWrap: 'wrap' }}>
          <button
            style={{ ...styles.voteBtn, background: '#276749' }}
            disabled={isPending || votePending}
            onClick={() => castVote(1)}
          >
            {isPending ? '…' : 'For'}
          </button>
          <button
            style={{ ...styles.voteBtn, background: '#742a2a' }}
            disabled={isPending || votePending}
            onClick={() => castVote(0)}
          >
            {isPending ? '…' : 'Against'}
          </button>
          <button
            style={{ ...styles.voteBtn, background: '#2d3748' }}
            disabled={isPending || votePending}
            onClick={() => castVote(2)}
          >
            {isPending ? '…' : 'Abstain'}
          </button>
        </div>
      )}
      {isSuccess && <p style={{ color: '#68d391', fontSize: '0.75rem', marginTop: '6px' }}>Vote confirmed!</p>}
      {isError   && <p style={{ color: '#fc8181', fontSize: '0.75rem', marginTop: '6px' }}>Transaction failed.</p>}
    </div>
  )
}

// ── Main panel ────────────────────────────────────────────────────────────────

export function GovernancePanel() {
  const { address, isConnected } = useAccount()
  const deployed = isDeployed(ADDRESSES.rwaGovernor)
  const { data: blockNumber } = useBlockNumber()

  // — On-chain governor params —
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
    query: { enabled: deployed },
  })

  const votingDelay  = data?.[0]?.result as bigint | undefined
  const votingPeriod = data?.[1]?.result as bigint | undefined
  const threshold    = data?.[2]?.result as bigint | undefined
  const quorum       = data?.[3]?.result as bigint | undefined
  const timelockAddr = data?.[4]?.result as string | undefined
  const votingPower  = data?.[5]?.result as bigint | undefined
  const delegatee    = data?.[6]?.result as string | undefined
  const govBalance   = data?.[7]?.result as bigint | undefined

  const selfDelegated =
    delegatee && address &&
    delegatee.toLowerCase() === address.toLowerCase()

  // — Delegate tx —
  const { writeContract: delegateWrite, data: delegateTxHash, isPending: delegatingPending } = useWriteContract()
  const { isSuccess: delegateSuccess } = useWaitForTransactionReceipt({ hash: delegateTxHash })
  if (delegateSuccess) refetch()

  // — Proposals from The Graph —
  const [proposals, setProposals] = useState<GqlProposal[]>([])
  const [loadingProposals, setLoadingProposals] = useState(false)
  const [proposalError, setProposalError] = useState('')

  useEffect(() => {
    if (!SUBGRAPH_URL) return
    setLoadingProposals(true)
    fetchProposals()
      .then(setProposals)
      .catch(() => setProposalError('Failed to load proposals from subgraph.'))
      .finally(() => setLoadingProposals(false))
  }, [])

  if (!deployed) {
    return <p style={{ color: '#718096' }}>Governor not deployed. Set VITE_RWA_GOVERNOR in .env</p>
  }

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '1.25rem' }}>

      {/* ── Top row: params + voting power ── */}
      <div style={styles.twoCol}>
        <div style={styles.card}>
          <h3 style={styles.cardTitle}>Governor Parameters</h3>
          <Row label="Voting delay"       value={votingDelay  != null ? secondsToHuman(votingDelay)  : '—'} />
          <Row label="Voting period"      value={votingPeriod != null ? secondsToHuman(votingPeriod) : '—'} />
          <Row label="Proposal threshold" value={threshold    != null ? `${fmt(threshold)} RWAGOV` : '—'} />
          <Row label="Quorum"             value={quorum       != null ? `${quorum.toString()}%` : '—'} />
          <Row label="Timelock"           value={timelockAddr ? shortAddr(timelockAddr) : '—'} />
          <Row label="Current block"      value={blockNumber  ? blockNumber.toString() : '—'} />
        </div>

        <div style={styles.card}>
          <h3 style={styles.cardTitle}>Your Voting Power</h3>
          <Row label="GOV balance"  value={`${fmt(govBalance)} RWAGOV`} />
          <Row label="Voting power" value={`${fmt(votingPower)} RWAGOV`} highlight={!selfDelegated} />
          <Row
            label="Delegated to"
            value={selfDelegated ? 'Self (active)' : delegatee ? shortAddr(delegatee) : '—'}
          />

          {!selfDelegated && (
            <div style={styles.delegateBox}>
              <p style={styles.hint}>
                Voting power is 0 — delegate to yourself to activate it.
              </p>
              <button
                style={styles.btnPrimary}
                disabled={delegatingPending || !isConnected}
                onClick={() => delegateWrite({
                  address: ADDRESSES.govToken, abi: GOV_TOKEN_ABI,
                  functionName: 'delegate', args: [address!],
                })}
              >
                {delegatingPending ? 'Delegating…' : 'Delegate to Self'}
              </button>
            </div>
          )}
          {selfDelegated && (
            <p style={{ ...styles.hint, color: '#68d391', marginTop: '10px' }}>
              Voting power is active.
            </p>
          )}
          {delegateSuccess && <p style={styles.success}>Delegation confirmed!</p>}
        </div>
      </div>

      {/* ── Proposals from The Graph ── */}
      <div style={styles.card}>
        <h3 style={styles.cardTitle}>
          Governance Proposals
          {SUBGRAPH_URL
            ? <span style={styles.badge}>via The Graph</span>
            : <span style={{ ...styles.badge, background: '#4a5568' }}>VITE_SUBGRAPH_URL not set</span>
          }
        </h3>

        {!SUBGRAPH_URL && (
          <p style={styles.hint}>
            Set <code>VITE_SUBGRAPH_URL</code> in <code>frontend/.env</code> to display live proposals.
          </p>
        )}

        {SUBGRAPH_URL && loadingProposals && (
          <p style={styles.hint}>Loading proposals…</p>
        )}

        {proposalError && (
          <p style={{ color: '#fc8181', fontSize: '0.8rem' }}>{proposalError}</p>
        )}

        {!loadingProposals && proposals.length === 0 && SUBGRAPH_URL && !proposalError && (
          <p style={styles.hint}>No proposals found in the subgraph yet.</p>
        )}

        <div style={styles.proposalGrid}>
          {proposals.map(p => <ProposalCard key={p.id} proposal={p} />)}
        </div>
      </div>

      {/* ── How governance works ── */}
      <div style={styles.card}>
        <h3 style={styles.cardTitle}>How to Create a Proposal</h3>
        <ol style={styles.howto}>
          <li>Hold ≥ <strong>1,000 RWAGOV</strong> and delegate to yourself.</li>
          <li>Call <code>governor.propose(targets, values, calldatas, description)</code> on-chain.</li>
          <li>Wait for the voting delay (<strong>1 day</strong>) before voting opens.</li>
          <li>Voting runs for <strong>1 week</strong>. Quorum: <strong>4%</strong> of total supply.</li>
          <li>On success, queue in Timelock. After the <strong>2-day</strong> delay, anyone can execute.</li>
        </ol>
      </div>
    </div>
  )
}

// ── Styles ────────────────────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  twoCol: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))',
    gap: '1rem',
  },
  card: {
    background: '#161b26',
    border: '1px solid #2d3748',
    borderRadius: '12px',
    padding: '1.5rem',
  },
  cardTitle: {
    fontSize: '0.95rem', fontWeight: 700, color: '#a78bfa',
    marginBottom: '1rem', display: 'flex', alignItems: 'center', gap: '0.5rem',
  },
  badge: {
    fontSize: '0.65rem', fontWeight: 600, padding: '2px 8px',
    borderRadius: '999px', background: '#2d3748', color: '#a0aec0',
  },
  delegateBox: {
    background: '#1a1f2e', borderRadius: '8px', padding: '12px', marginTop: '10px',
  },
  hint:      { fontSize: '0.78rem', color: '#a0aec0' },
  btnPrimary: {
    display: 'block', width: '100%', marginTop: '10px',
    padding: '11px', borderRadius: '10px', border: 'none', cursor: 'pointer',
    background: '#7c3aed', color: '#fff', fontSize: '0.9rem', fontWeight: 700,
  },
  success:  { color: '#68d391', fontSize: '0.82rem', marginTop: '10px', textAlign: 'center' },
  howto: {
    paddingLeft: '1.3rem', lineHeight: 2,
    fontSize: '0.85rem', color: '#a0aec0',
  },
  proposalGrid: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))',
    gap: '0.75rem',
    marginTop: '0.75rem',
  },
  proposalCard: {
    background: '#1a1f2e',
    border: '1px solid #2d3748',
    borderRadius: '10px',
    padding: '1rem',
  },
  voteRow:  { display: 'flex', alignItems: 'center', gap: '0.5rem', marginBottom: '4px' },
  voteBar:  { flex: 1, height: '6px', borderRadius: '3px', overflow: 'hidden' },
  voteFill: { height: '100%', borderRadius: '3px', transition: 'width 0.3s' },
  voteLabel: { fontSize: '0.72rem', color: '#a0aec0', whiteSpace: 'nowrap', width: '120px' },
  voteBtn: {
    flex: 1, padding: '6px 10px', borderRadius: '8px', border: 'none',
    cursor: 'pointer', color: '#fff', fontSize: '0.78rem', fontWeight: 700,
  },
}
