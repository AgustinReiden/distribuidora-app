import { fechaLocalISO } from './formatters'

/**
 * Hasta dónde puede ir la fecha de entrega programada de un pedido (1559-b6, #1559).
 *
 * Decisión del dueño (D21 del plan #1603): de hoy hasta 60 días adelante. Es el espejo del
 * techo de `_fecha_entrega_programada_fuera_de_rango` (mig NNN), que decide en el server el
 * alta (`crear_pedido_completo`, con piso en la fecha del pedido si es anterior a hoy) y el
 * cambio en la edición (`pedidos_proteger_columnas`, con piso en hoy). La pantalla lo usa
 * como `max` del input; el server rechaza lo que pase igual.
 */
export const DIAS_ADELANTE_ENTREGA_PROGRAMADA = 60

/** 'YYYY-MM-DD' más `dias` días, sobre el día calendario (no depende de la zona). */
function sumarDias(iso: string, dias: number): string {
  const [y, m, d] = iso.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d) + dias * 86_400_000).toISOString().slice(0, 10)
}

/** La fecha de entrega programada más lejana que se puede cargar. */
export function techoFechaEntregaProgramada(hoy = fechaLocalISO()): string {
  return sumarDias(hoy, DIAS_ADELANTE_ENTREGA_PROGRAMADA)
}
