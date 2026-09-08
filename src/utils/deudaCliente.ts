/**
 * Aviso de deuda previa del cliente. AVISA, NO BLOQUEA.
 *
 * El dato es `clientes.saldo_cuenta` (positivo = debe, negativo = a favor), que
 * ya viaja en el front sin ninguna consulta extra. No se usa "boletas vencidas"
 * porque esa definición vive en `obtener_deudores_mora` (mig 075), que está
 * cerrada a admin y encargado: el preventista —que es para quien se hizo este
 * aviso— no la puede consultar.
 *
 * EL SALDO INCLUYE AL PROPIO PEDIDO
 * ---------------------------------
 * `trigger_actualizar_saldo_pedido` suma `total - COALESCE(monto_pagado, 0)` al
 * saldo del cliente en el INSERT del pedido, y lo recalcula en cada UPDATE de
 * esas dos columnas. O sea: en la tarjeta del pedido X, el saldo del cliente YA
 * contiene lo que X dejó impago. Mostrarlo crudo diría "debe" en toda tarjeta
 * impaga, que es lo contrario de avisar de un pedido ANTERIOR. Por eso `pedido`
 * descuenta la contribución de ese pedido al saldo.
 *
 * El clamp a 0 de esa contribución no es cosmético: si el pedido está SOBRE
 * pagado (monto_pagado > total) su aporte al saldo es negativo, y restarlo
 * inflaría la deuda mostrada. Ante la duda, este aviso subestima: acusar de una
 * deuda que no existe, delante del cliente, es peor que no avisar.
 *
 * OFFLINE
 * -------
 * El saldo que ve un teléfono sin señal es el del último sync y no incluye lo
 * que se haya cobrado después. Por eso `saldoAl`: cuando el dato puede estar
 * viejo el texto lo dice y habla en pasado, en vez de afirmar una deuda de
 * ahora.
 *
 * OJO: `saldo_cuenta` es denormalizado y tiene historial de descuadres (migs
 * 020, 052, 072, 086, 165, 166, 168). Este aviso vuelve visible en la calle
 * cualquier descuadre viejo que hasta ahora sólo se veía en la ficha.
 */
import { formatPrecio } from './formatters'

/** Un peso: por debajo de un centavo no hay deuda que avisar, hay ruido de float. */
const EPSILON = 0.01

export interface AvisoDeuda {
  /** Deuda en $. Siempre > 0: si no hay deuda no hay aviso. */
  monto: number
  /** Etiqueta corta, para un badge en la tarjeta del pedido. */
  etiqueta: string
  /** Texto largo, para el alta del pedido. */
  detalle: string
}

export interface AvisoDeudaOpts {
  /**
   * Pedido cuya parte impaga YA está sumada en `saldoCuenta` y hay que
   * descontar para quedarse con la deuda ANTERIOR a él. Sin esto, el aviso
   * sería el propio pedido.
   */
  pedido?: { total?: number | null; monto_pagado?: number | null } | null
  /**
   * Fecha del dato, ya formateada, cuando el saldo puede estar viejo (sin
   * conexión). Si viene, el texto habla en pasado y la incluye.
   */
  saldoAl?: string | null
}

function aNumero(valor: number | null | undefined): number {
  const n = Number(valor)
  return Number.isFinite(n) ? n : 0
}

/**
 * Deuda a avisar, o null si no hay nada que avisar.
 *
 * Sin `pedido` responde "¿cuánto debe este cliente?" (alta de pedido).
 * Con `pedido` responde "¿cuánto debía ANTES de este pedido?" (tarjeta).
 */
export function avisoDeudaCliente(
  saldoCuenta: number | null | undefined,
  opts: AvisoDeudaOpts = {},
): AvisoDeuda | null {
  const saldo = aNumero(saldoCuenta)

  // Lo que este pedido aporta hoy al saldo, espejo de actualizar_saldo_pedido.
  const aportePropio = opts.pedido
    ? Math.max(0, aNumero(opts.pedido.total) - aNumero(opts.pedido.monto_pagado))
    : 0

  const monto = Math.round((saldo - aportePropio) * 100) / 100
  if (monto < EPSILON) return null

  const importe = formatPrecio(monto)
  const saldoAl = opts.saldoAl?.trim()

  return saldoAl
    ? {
        monto,
        etiqueta: `Debía ${importe} al ${saldoAl}`,
        detalle:
          `Sin conexión: al ${saldoAl} este cliente debía ${importe}. ` +
          `No incluye lo que se le haya cobrado después.`,
      }
    : {
        monto,
        etiqueta: `Debe ${importe}`,
        detalle: `Este cliente tiene una deuda previa de ${importe}.`,
      }
}
