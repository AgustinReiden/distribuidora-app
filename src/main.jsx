import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.jsx'

console.log('%c 🚀 Distribuidora App v2.0 ', 'background: #2563eb; color: white; font-size: 16px; padding: 4px 8px; border-radius: 4px');

const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!url || !key) {
  console.error("⚠️ Faltan variables de entorno VITE_SUPABASE_URL o VITE_SUPABASE_ANON_KEY");
} else {
  console.log("✅ Variables de entorno configuradas");
}

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
