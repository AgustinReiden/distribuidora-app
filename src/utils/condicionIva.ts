/**
 * Condiciones frente al IVA disponibles en la UI (mig 177).
 *
 * Vive aparte de los modales por dos razones: es la única fuente de verdad para
 * la ficha de producto y las dos pantallas de compra (antes había dos listas
 * que podían divergir), y es un módulo puro — importarlo desde un modal no
 * arrastra supabase a los tests.
 *
 * El par (condición, alícuota) se elige SIEMPRE junto: la BD tiene un CHECK
 * cruzado y la condición manda sobre la tasa.
 */
import type { CondicionIva } from './calculations';

export interface OpcionCondicionIva {
  /** Clave del <select>: 'gravado:21' | 'gravado:10.5' | 'exento' | 'no_gravado' */
  clave: string;
  label: string;
  /** Variante corta para la grilla de compra, donde la columna es angosta. */
  labelCorto: string;
  condicion: CondicionIva;
  porcentaje: number;
}

export const OPCIONES_CONDICION_IVA: OpcionCondicionIva[] = [
  { clave: 'gravado:21', label: '21%', labelCorto: '21%', condicion: 'gravado', porcentaje: 21 },
  { clave: 'gravado:10.5', label: '10,5%', labelCorto: '10,5%', condicion: 'gravado', porcentaje: 10.5 },
  { clave: 'exento', label: 'Exento', labelCorto: 'Exento', condicion: 'exento', porcentaje: 0 },
  { clave: 'no_gravado', label: 'No gravado', labelCorto: 'No grav.', condicion: 'no_gravado', porcentaje: 0 },
];

/** Clave del selector para un par (condición, alícuota) cargado. */
export function claveCondicionIva(
  condicion: CondicionIva | null | undefined,
  porcentaje: number | null | undefined,
): string {
  const cond = condicion ?? 'gravado';
  return cond === 'gravado' ? `gravado:${porcentaje ?? 21}` : cond;
}

/** Opción correspondiente a una clave (undefined si es un par legacy). */
export function opcionPorClave(clave: string): OpcionCondicionIva | undefined {
  return OPCIONES_CONDICION_IVA.find(o => o.clave === clave);
}

/** Etiqueta legible de una clave; devuelve la clave si no la reconoce. */
export function labelCondicionIva(clave: string): string {
  return opcionPorClave(clave)?.label ?? clave;
}
