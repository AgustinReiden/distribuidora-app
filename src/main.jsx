console.log('%c 🚀 VERSIÓN NUEVA CARGADA2 ', 'background: #222; color: #bada55; font-size: 20px');
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
// --- TRAMPA DE ERRORES GLOBAL ---
// Esto atrapará cualquier error que mate a tu app y te lo mostrará en la cara.
window.onerror = function (message, source, lineno, colno, error) {
  alert(`CRASH DETECTADO:\n${message}\nEn: ${source}:${lineno}`);
  return false;
};

// Verificación de variables de entorno (Causa #1 de muerte súbita en producción)
const url = import.meta.env.VITE_SUPABASE_URL;
const key = import.meta.env.VITE_SUPABASE_ANON_KEY;

if (!url || !key) {
  alert("FATAL: Faltan las variables de entorno VITE_SUPABASE_URL o KEY. Revisa Coolify.");
} else {
  console.log("✅ Variables de entorno detectadas correctamente.");
}

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
