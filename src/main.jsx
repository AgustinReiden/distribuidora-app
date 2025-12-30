console.log('%c 🚀 VERSIÓN NUEVA CARGADA ', 'background: #222; color: #bada55; font-size: 20px');
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.jsx'

// --- AGREGAR ESTO PARA EL DIAGNÓSTICO ---
import { supabase } from './lib/supabase' // Asegúrate que la ruta sea correcta

console.log('🔍 TEST DIAGNÓSTICO: Iniciando prueba de conexión directa...');

// Esta función intenta hablar con Supabase fuera de React
supabase.auth.getSession().then(({ data, error }) => {
  if (error) {
    console.error('❌ ERROR Supabase (Diagnóstico):', error);
  } else {
    console.log('✅ ÉXITO Supabase (Diagnóstico). Usuario:', data.session?.user?.email || 'No hay usuario');
  }
}).catch(err => {
  console.error('💀 CRASH Supabase (Diagnóstico):', err);
});
// ----------------------------------------

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
