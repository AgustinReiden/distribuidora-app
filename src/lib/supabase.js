import { createClient } from '@supabase/supabase-js'

const supabaseUrl = import.meta.env.VITE_SUPABASE_URL
const supabaseAnonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

// PASO 2: Agregamos el tercer argumento (opciones) para cambiar el storageKey
export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  auth: {
    // 🔑 CLAVE DE LA SOLUCIÓN:
    // Al cambiar este nombre, Supabase ignora el localStorage viejo/roto
    // y crea uno nuevo. Esto descongela tu PC inmediatamente.
    storageKey: 'distribuidora_v1', 
    
    // Opciones estándar recomendadas
    persistSession: true,
    detectSessionInUrl: true,
  }
})
