/**
 * Saldo a favor aplicado a una boleta (#1469).
 *
 * Una boleta nueva absorbe el saldo a favor del cliente al crearse (FIFO, como
 * `aplicar_credito_cliente`: primero la boleta impaga más vieja). El pago que
 * llega a una boleta desde un crédito queda marcado `pagos.de_saldo_a_favor`
 * (lo pone un trigger, nadie lo escribe a mano): de ahí sale lo que se muestra
 * en la tarjeta, el modal de cobro y la boleta impresa.
 */
import { formatPrecio } from './formatters'

interface PagoConMarca {
  monto: number | string | null | undefined
  de_saldo_a_favor?: boolean | null
}

const redondear = (n: number): number => Math.round(n * 100) / 100

/** Lo que los pagos de la boleta trajeron de saldo a favor. 0 si no hay. */
export function saldoAFavorAplicado(pagos: readonly PagoConMarca[] | null | undefined): number {
  if (!pagos) return 0
  const suma = pagos.reduce((s, p) => (p.de_saldo_a_favor ? s + (Number(p.monto) || 0) : s), 0)
  return redondear(suma)
}

/** "Saldo a favor aplicado: $X", o null si no se aplicó nada. */
export function textoSaldoAFavorAplicado(monto: number): string | null {
  return monto > 0.005 ? `Saldo a favor aplicado: ${formatPrecio(monto)}` : null
}

/**
 * El aviso del alta. `aplicado` es lo que cayó en la boleta nueva y `otras` lo
 * que fue a boletas más viejas del cliente. null si no se aplicó nada.
 */
export function mensajeSaldoAFavorAlta(pedidoId: string | number, aplicado: number, otras: number): string | null {
  const partes: string[] = []
  if (aplicado > 0.005) partes.push(`al pedido #${pedidoId} se le aplicaron ${formatPrecio(aplicado)} de saldo a favor del cliente`)
  if (otras > 0.005) partes.push(`${formatPrecio(otras)} de saldo a favor fueron a boletas anteriores impagas`)
  if (partes.length === 0) return null
  const texto = partes.join(', y ')
  return texto.charAt(0).toUpperCase() + texto.slice(1) + '.'
}

/**
 * Lo que se cobra al crear el pedido, descontado el saldo a favor que la boleta
 * ya absorbió: sin eso, el cobro "pagado" de un pedido que absorbió $400 pedía
 * $400 de más y el servidor lo rechazaba (nunca más de lo que falta).
 *
 * - `pagado`: el total con envío menos lo absorbido.
 * - `parcial`: lo declarado, con tope en lo que falta.
 * - cualquier otro: 0.
 */
export function montoCobroAlta(args: {
  estadoPago: string
  montoDeclarado: number
  totalConEnvio: number
  totalGuardado: number
  saldoAplicado: number
}): number {
  const falta = Math.max(0, redondear(args.totalGuardado - args.saldoAplicado))
  if (args.estadoPago === 'pagado') return Math.min(Math.max(0, redondear(args.totalConEnvio - args.saldoAplicado)), falta)
  if (args.estadoPago === 'parcial') return Math.min(Math.max(0, Number(args.montoDeclarado) || 0), falta)
  return 0
}

/**
 * Lo que el cliente tiene a favor según `clientes.saldo_cuenta` (negativo = a
 * favor). 0 si debe, si no hay dato o si es ruido de centavos.
 */
export function saldoAFavorDelCliente(saldoCuenta: number | string | null | undefined): number {
  const n = Number(saldoCuenta)
  if (!Number.isFinite(n)) return 0
  const aFavor = redondear(-n)
  return aFavor >= 0.01 ? aFavor : 0
}

/**
 * Lo que la boleta nueva va a absorber del saldo a favor (#1503), estimado con
 * el saldo de hoy: todo lo que el cliente tiene a favor, con tope en el total.
 * Si el saldo da deuda, sus créditos sueltos van antes a las boletas impagas más
 * viejas (FIFO) y a ésta no le llega nada. Lo que se aplica de verdad lo decide
 * el servidor al crearla, y lo dice `mensajeSaldoAFavorAlta`.
 */
export function saldoQueAbsorbeAlta(
  saldoCuenta: number | string | null | undefined,
  totalConEnvio: number,
): number {
  return Math.min(saldoAFavorDelCliente(saldoCuenta), Math.max(0, redondear(totalConEnvio)))
}

/**
 * El aviso del alta al elegir el cliente (#1503), o null si no tiene nada a
 * favor. Como el de la deuda, sin conexión habla en pasado y dice la fecha del
 * dato.
 */
export function avisoSaldoAFavorCliente(
  saldoCuenta: number | string | null | undefined,
  opts: { saldoAl?: string | null } = {},
): string | null {
  const monto = saldoAFavorDelCliente(saldoCuenta)
  if (monto === 0) return null
  const importe = formatPrecio(monto)
  const saldoAl = opts.saldoAl?.trim()
  return saldoAl
    ? `Sin conexión: al ${saldoAl} este cliente tenía ${importe} a favor. ` +
        'Se descuenta de esta boleta al crearla; no incluye lo que haya cambiado después.'
    : `Este cliente tiene ${importe} a favor: se descuenta de esta boleta al crearla.`
}

/**
 * El aviso de un cobro del alta menor que lo declarado (#1503), o null si se
 * registró lo declarado. "pagado" declara el total con envío; "parcial", lo que
 * se tipeó. `registrado` es lo que salió de `montoCobroAlta`. Sin este aviso,
 * quien cobró el total veía "Pedido creado correctamente" y la diferencia no
 * quedaba en ningún lado.
 */
export function avisoCobroAltaRecortado(args: {
  pedidoId: string | number
  estadoPago: string
  montoDeclarado: number
  totalConEnvio: number
  registrado: number
  saldoAplicado: number
}): string | null {
  const declarado = args.estadoPago === 'pagado'
    ? redondear(args.totalConEnvio)
    : args.estadoPago === 'parcial'
      ? redondear(Math.max(0, Number(args.montoDeclarado) || 0))
      : 0
  const sinRegistrar = redondear(declarado - args.registrado)
  if (sinRegistrar < 0.01) return null
  const causa = args.saldoAplicado > 0.005
    ? `el saldo a favor del cliente cubrió ${formatPrecio(args.saldoAplicado)}`
    : 'la boleta no debía más que eso'
  const registro = args.registrado > 0.005
    ? `En el pedido #${args.pedidoId} se registró un cobro de ${formatPrecio(args.registrado)}`
    : `En el pedido #${args.pedidoId} no se registró ningún cobro`
  return `${registro}: ${causa}. Si cobraste ${formatPrecio(declarado)}, ` +
    `${formatPrecio(sinRegistrar)} no quedaron registrados.`
}

interface PagoDeBoleta extends PagoConMarca {
  a_cuenta?: boolean | null
}

/**
 * Lo cobrado de una boleta, partido como lo trata `cambiar_cliente_pedido` (#1489).
 *
 * - `delCliente`: lo que llegó del saldo a favor del cliente (`de_saldo_a_favor`) o de un
 *   pago a cuenta de su ficha (`a_cuenta`). Es plata del cliente, no el cobro de esta
 *   venta: con cualquier destino vuelve a quedarle a favor y nunca viaja al cliente nuevo.
 * - `cobro`: el resto de `monto_pagado`, el cobro de la boleta. Es lo único por lo que el
 *   modal pregunta si viaja o queda a favor.
 *
 * Sin la lista de pagos, todo cuenta como cobro (lo que se veía antes).
 */
export function partesCobroCambioCliente(
  montoPagado: number | string | null | undefined,
  pagos: readonly PagoDeBoleta[] | null | undefined,
): { delCliente: number; cobro: number } {
  const total = redondear(Number(montoPagado) || 0)
  const delCliente = Math.min(
    total,
    redondear((pagos ?? []).reduce((s, p) => (p.de_saldo_a_favor || p.a_cuenta ? s + (Number(p.monto) || 0) : s), 0)),
  )
  return { delCliente, cobro: redondear(Math.max(0, total - delCliente)) }
}
