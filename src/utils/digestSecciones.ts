/**
 * Catálogo de secciones del digest de Telegram y helpers de presentación (#691).
 *
 * Vive en `utils/` y no en el hook porque es lógica pura y así se testea sin
 * arrastrar el cliente de Supabase (los tests corren sin `.env`).
 *
 * La lista de claves tiene TRES puntas y se mueven juntas:
 *   1. el CHECK `bot_digest_config_secciones_ck` en la base — el gate;
 *   2. `SECCIONES` en `supabase/functions/telegram-digest/secciones.ts` — qué
 *      datos entran realmente al mensaje;
 *   3. `SECCIONES_DIGEST` de acá — cómo se llama cada una en el panel.
 * Cada punta tiene un test con la lista literal: `secciones.test.ts` del lado
 * de la edge function y `digestSecciones.test.ts` de este lado.
 */

/** Las secciones que puede llevar el digest, con la etiqueta que ve el admin. */
export const SECCIONES_DIGEST = [
  {
    key: 'ventas',
    label: 'Ventas del día',
    detalle: 'Total, pedidos y comparación con el promedio de 7 días',
  },
  { key: 'top_clientes', label: 'Top clientes', detalle: 'Los 3 clientes que más compraron' },
  { key: 'top_productos', label: 'Top productos', detalle: 'Los 3 productos más vendidos' },
  { key: 'stock_critico', label: 'Stock crítico', detalle: 'Productos por debajo del mínimo' },
  { key: 'deuda', label: 'Deuda', detalle: 'Vencida y total por cobrar' },
  {
    key: 'pendientes_entrega',
    label: 'Pendientes de entrega',
    detalle: 'Pedidos cargados y sin entregar',
  },
  {
    key: 'pendientes_pago',
    label: 'Pendientes de pago',
    detalle: 'Pedidos entregados y sin cobrar',
  },
  { key: 'recorridos', label: 'Recorridos', detalle: 'Recorridos del día y paradas' },
  {
    key: 'rendiciones',
    label: 'Rendiciones',
    detalle: 'Rendiciones sin controlar y la más vieja',
  },
  {
    key: 'vencimientos',
    label: 'Lotes por vencer',
    detalle: 'Lotes que vencen dentro del plazo crítico de la sucursal',
  },
] as const

export type SeccionDigestKey = (typeof SECCIONES_DIGEST)[number]['key']

/** Días ISO tal como los guarda `bot_digest_config.dias_semana` (1 = lunes). */
export const DIAS_SEMANA = [
  { iso: 1, corto: 'Lun', largo: 'lunes' },
  { iso: 2, corto: 'Mar', largo: 'martes' },
  { iso: 3, corto: 'Mié', largo: 'miércoles' },
  { iso: 4, corto: 'Jue', largo: 'jueves' },
  { iso: 5, corto: 'Vie', largo: 'viernes' },
  { iso: 6, corto: 'Sáb', largo: 'sábado' },
  { iso: 7, corto: 'Dom', largo: 'domingo' },
] as const

/** "07:00" a partir de la hora entera que guarda la base. */
export function formatHora(hora: number): string {
  return `${String(hora).padStart(2, '0')}:00`
}

/**
 * Resume los días en una frase corta: "todos los días", "lun a vie", o la
 * lista de abreviaturas. Es lo que se muestra en la fila de la tabla, donde
 * siete casilleros no entran.
 */
export function resumirDias(dias: number[]): string {
  const orden = [...dias].sort((a, b) => a - b)
  if (orden.length === 0) return 'ningún día'
  if (orden.length === 7) return 'todos los días'
  // Los cinco, no cuatro: "lun a jue" escrito "lun a vie" agregaría un día que
  // no eligió.
  if (orden.length === 5 && orden.every((d, i) => d === i + 1)) return 'lun a vie'
  if (orden.length === 2 && orden[0] === 6 && orden[1] === 7) return 'fines de semana'
  return orden.map((d) => DIAS_SEMANA.find((x) => x.iso === d)?.corto ?? d).join(', ')
}

/**
 * Etiqueta de una sección por su clave; la clave cruda si no está en el
 * catálogo. Devolver la clave y no vacío es a propósito: con una fila vieja
 * cuya sección se sacó del catálogo, es mejor que el admin vea algo raro a que
 * la fila parezca tener una sección menos.
 */
export function labelSeccion(key: string): string {
  return SECCIONES_DIGEST.find((s) => s.key === key)?.label ?? key
}
