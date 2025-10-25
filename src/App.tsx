import './App.css';
import Testnet from './pages/Testnet';

function App() {
  const searchParams = new URLSearchParams(location.search);
  const network = searchParams.get('network') ?? 'mainnet';
  const otherNetwork = network === 'mainnet' ? 'sepolia' : 'mainnet';

  return (
    <>
      <header>
        Valinity Monitor&nbsp;
        <a href={`?network=${otherNetwork}`}>[{network}]</a>
      </header>

      {network === 'mainnet' ? null : <Testnet />}
    </>
  )
}

export default App
