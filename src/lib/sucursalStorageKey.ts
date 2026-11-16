/**
 * La clave de `localStorage` con la sucursal activa. Vive aparte de `SucursalContext`
 * para que quien sólo necesita la clave (la limpieza de datos locales, que usa el
 * `ErrorBoundary`) no arrastre el cliente de Supabase al importarla.
 */
export const SUCURSAL_STORAGE_KEY = 'distribuidora_sucursal_activa'
