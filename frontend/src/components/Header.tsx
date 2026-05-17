import { useAccount, useConnect, useDisconnect, useChainId } from 'wagmi'
import { arbitrumSepolia } from 'wagmi/chains'

export function Header() {
  const { address, isConnected } = useAccount()
  const { connectors, connect, isPending } = useConnect()
  const { disconnect } = useDisconnect()
  const chainId = useChainId()

  const wrongNetwork = isConnected && chainId !== arbitrumSepolia.id

  return (
    <header style={styles.header}>
      <div style={styles.logo}>
        <span style={styles.logoIcon}>◈</span>
        <span style={styles.logoText}>RWA Platform</span>
        <span style={styles.logoSub}>Arbitrum Sepolia</span>
      </div>

      <div style={styles.right}>
        {wrongNetwork && (
          <span style={styles.wrongNet}>Wrong network — switch to Arbitrum Sepolia</span>
        )}

        {isConnected ? (
          <div style={styles.accountRow}>
            <span style={styles.address}>
              {address?.slice(0, 6)}…{address?.slice(-4)}
            </span>
            <button style={styles.btnSecondary} onClick={() => disconnect()}>
              Disconnect
            </button>
          </div>
        ) : (
          <div style={styles.connectRow}>
            {connectors.map((c) => (
              <button
                key={c.id}
                style={styles.btnPrimary}
                disabled={isPending}
                onClick={() => connect({ connector: c })}
              >
                {isPending ? 'Connecting…' : `Connect ${c.name}`}
              </button>
            ))}
          </div>
        )}
      </div>
    </header>
  )
}

const styles: Record<string, React.CSSProperties> = {
  header: {
    display: 'flex', alignItems: 'center', justifyContent: 'space-between',
    padding: '0 2rem', height: '64px',
    background: '#161b26', borderBottom: '1px solid #2d3748',
    position: 'sticky', top: 0, zIndex: 100,
  },
  logo: { display: 'flex', alignItems: 'center', gap: '10px' },
  logoIcon: { fontSize: '1.5rem', color: '#7c3aed' },
  logoText: { fontSize: '1.1rem', fontWeight: 700, color: '#f7fafc' },
  logoSub: { fontSize: '0.72rem', color: '#718096', marginTop: '2px' },
  right: { display: 'flex', alignItems: 'center', gap: '12px' },
  wrongNet: {
    fontSize: '0.8rem', color: '#fc8181',
    background: '#2d1b1b', padding: '4px 10px', borderRadius: '6px',
  },
  accountRow: { display: 'flex', alignItems: 'center', gap: '10px' },
  address: {
    fontSize: '0.85rem', color: '#a0aec0',
    background: '#2d3748', padding: '5px 10px', borderRadius: '8px',
  },
  connectRow: { display: 'flex', gap: '8px' },
  btnPrimary: {
    padding: '7px 16px', borderRadius: '8px', border: 'none', cursor: 'pointer',
    background: '#7c3aed', color: '#fff', fontSize: '0.85rem', fontWeight: 600,
  },
  btnSecondary: {
    padding: '7px 14px', borderRadius: '8px', border: '1px solid #4a5568', cursor: 'pointer',
    background: 'transparent', color: '#a0aec0', fontSize: '0.82rem',
  },
}
