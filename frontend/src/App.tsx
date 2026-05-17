import { useState } from 'react'
import { Header } from './components/Header'
import { Overview } from './components/Overview'
import { SwapPanel } from './components/SwapPanel'
import { StakePanel } from './components/StakePanel'
import { GovernancePanel } from './components/GovernancePanel'

type Tab = 'overview' | 'swap' | 'stake' | 'governance'

const TABS: { id: Tab; label: string }[] = [
  { id: 'overview',    label: 'Overview' },
  { id: 'swap',        label: 'Swap' },
  { id: 'stake',       label: 'Stake' },
  { id: 'governance',  label: 'Governance' },
]

export default function App() {
  const [tab, setTab] = useState<Tab>('overview')

  return (
    <div style={styles.root}>
      <Header />

      <nav style={styles.nav}>
        {TABS.map(t => (
          <button
            key={t.id}
            style={{ ...styles.tab, ...(tab === t.id ? styles.tabActive : {}) }}
            onClick={() => setTab(t.id)}
          >
            {t.label}
          </button>
        ))}
      </nav>

      <main style={styles.main}>
        {tab === 'overview'   && <Overview />}
        {tab === 'swap'       && <SwapPanel />}
        {tab === 'stake'      && <StakePanel />}
        {tab === 'governance' && <GovernancePanel />}
      </main>

      <footer style={styles.footer}>
        RWA Tokenization Platform &nbsp;·&nbsp; Blockchain Technologies 2 &nbsp;·&nbsp;
        Arbitrum Sepolia &nbsp;·&nbsp;
        <a
          href="https://sepolia.arbiscan.io"
          target="_blank"
          rel="noreferrer"
          style={{ color: '#7c3aed' }}
        >
          Arbiscan
        </a>
      </footer>
    </div>
  )
}

const styles: Record<string, React.CSSProperties> = {
  root: { display: 'flex', flexDirection: 'column', minHeight: '100vh' },
  nav: {
    display: 'flex', gap: '4px', padding: '12px 2rem',
    background: '#161b26', borderBottom: '1px solid #2d3748',
  },
  tab: {
    padding: '7px 18px', borderRadius: '8px', border: 'none', cursor: 'pointer',
    background: 'transparent', color: '#718096', fontSize: '0.88rem', fontWeight: 500,
    transition: 'all 0.15s',
  },
  tabActive: {
    background: '#2d3748', color: '#f7fafc', fontWeight: 700,
  },
  main: { flex: 1, padding: '1.5rem 2rem', maxWidth: '1100px', width: '100%', margin: '0 auto' },
  footer: {
    textAlign: 'center', padding: '1rem', fontSize: '0.75rem',
    color: '#4a5568', borderTop: '1px solid #2d3748',
  },
}
