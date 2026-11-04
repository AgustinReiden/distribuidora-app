/**
 * La diferencia de precio de un canje (#1370): `cambios_productos.diferencia_monto`,
 * lo entregado menos lo devuelto, a los precios de lista del momento.
 *
 * Es informativa por decisión del dueño (#1329, #1370): no toca `saldo_cuenta`, a favor
 * ni en contra. Si hay que cobrarla se hace un pedido; si hay que devolver algo, se hace
 * aparte. Estas leyendas lo dicen donde se consulta el canje.
 */

export type SentidoDiferenciaCanje = 'a_cobrar' | 'a_favor_cliente' | 'sin_diferencia'

/** Debajo de un centavo no hay diferencia: los precios son numeric(12,2). */
const CENTAVO = 0.005

export function sentidoDiferenciaCanje(diferencia: number | null | undefined): SentidoDiferenciaCanje {
  const d = Number(diferencia) || 0
  if (d > CENTAVO) return 'a_cobrar'
  if (d < -CENTAVO) return 'a_favor_cliente'
  return 'sin_diferencia'
}

const MOTIVOS: Record<string, string> = {
  erroneo: 'Cambio común',
  vencimiento: 'Vencido',
  rotura: 'Roto o dañado',
  mal_estado: 'En mal estado',
  otro: 'Otro',
}

/** El motivo de `cambios_productos.motivo`, para leer. */
export function motivoCanjeLabel(motivo: string | null | undefined): string {
  return MOTIVOS[motivo || 'erroneo'] ?? motivo ?? ''
}

export function leyendaDiferenciaCanje(diferencia: number | null | undefined): string {
  switch (sentidoDiferenciaCanje(diferencia)) {
    case 'a_cobrar':
      return 'El cliente se llevó más de lo que devolvió. Es informativa: no fue a su cuenta. Si hay que cobrarla, se hace un pedido.'
    case 'a_favor_cliente':
      return 'El cliente devolvió más de lo que se llevó. Es informativa: no quedó saldo a favor. Si hay que devolverle algo, se hace aparte.'
    default:
      return 'Sin diferencia de precio.'
  }
}
