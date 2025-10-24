import './App.css';
import Testnet from './pages/Testnet';

function App() {
  const searchParams = new URLSearchParams(location.search);
  const network = searchParams.get('network') ?? 'mainnet';
  const otherNetwork = network === 'mainnet' ? 'sepolia' : 'mainnet';

  return (
    <>
      <div style={{ display: 'flex', justifyContent: 'center', padding: '0.5rem', borderBottom: '1px solid gray' }}>
        Valinity Monitor&nbsp;
        <a href={`?network=${otherNetwork}`}>[{network}]</a>
      </div>

      {network === 'mainnet' ? null : <Testnet />}
    </>
  )
}

export default App
