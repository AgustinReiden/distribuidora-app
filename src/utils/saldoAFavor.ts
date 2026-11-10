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
 * Lo que se cobra al crear el pedido. Es lo que quien carga recibió en la mano,
 * con tope en lo que la boleta debe después del saldo a favor que absorbió: el
 * servidor rechaza un cobro mayor que lo que falta.
 *
 * - `pagado`: lo que el modal le dijo que cobrara, o sea el total con envío
 *   menos el saldo a favor que el modal mostró (`saldoMostrado`, 0 si no lo
 *   mostró). #1509: antes era el total menos lo que absorbió el servidor. Si el
 *   servidor absorbía menos que lo mostrado (el saldo del modal era de un caché
 *   viejo, u otra alta del mismo cliente lo tomó antes), el sistema registraba
 *   un cobro mayor que la plata que se recibió.
 * - `parcial`: lo declarado, con tope en lo que falta.
 * - cualquier otro: 0.
 */
export function montoCobroAlta(args: {
  estadoPago: string
  montoDeclarado: number
  totalConEnvio: number
  totalGuardado: number
  saldoAplicado: number
  saldoMostrado?: number
}): number {
  const falta = Math.max(0, redondear(args.totalGuardado - args.saldoAplicado))
  if (args.estadoPago === 'pagado') return Math.min(aCobrarMostrado(args.totalConEnvio, args.saldoMostrado), falta)
  if (args.estadoPago === 'parcial') return Math.min(Math.max(0, Number(args.montoDeclarado) || 0), falta)
  return 0
}

/** Lo que el modal dice "a cobrar" con "Pagado": el total menos el saldo mostrado. */
function aCobrarMostrado(totalConEnvio: number, saldoMostrado: number | undefined): number {
  return Math.max(0, redondear(totalConEnvio - (Number(saldoMostrado) || 0)))
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
 * El saldo a favor que el modal del alta descuenta de lo que hay que cobrar
 * (#1509), o 0 si no lo descuenta. Lo usan los dos llamadores del alta: el
 * modal, que lo muestra, y el container, que registra el cobro con lo que el
 * modal mostró. Tienen que dar lo mismo.
 *
 * Se descuenta sólo si quien carga puede ver la deuda, no es un VB y hay
 * conexión: sin conexión el alta queda pendiente de cobro y el saldo del caché
 * puede ser viejo.
 */
export function saldoMostradoAlta(args: {
  saldoCuenta: number | string | null | undefined
  totalConEnvio: number
  puedeVerDeuda: boolean | undefined
  esVB: boolean
  isOffline: boolean | undefined
}): number {
  if (!args.puedeVerDeuda || args.esVB || args.isOffline) return 0
  return saldoQueAbsorbeAlta(args.saldoCuenta, args.totalConEnvio)
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
 * El aviso del cobro del alta, o null si no hay nada que avisar. Son dos casos:
 *
 * - Se registró menos de lo declarado (#1503). "pagado" declara lo que el modal
 *   dijo que había que cobrar (el total con envío menos `saldoMostrado`);
 *   "parcial", lo que se tipeó. `registrado` es lo que salió de
 *   `montoCobroAlta`. Sin este aviso, quien cobró veía "Pedido creado
 *   correctamente" y la diferencia no quedaba en ningún lado.
 * - Con "pagado", el servidor absorbió menos saldo a favor que el que mostró el
 *   modal y la boleta quedó debiendo (#1509).
 */
export function avisoCobroAltaRecortado(args: {
  pedidoId: string | number
  estadoPago: string
  montoDeclarado: number
  totalConEnvio: number
  registrado: number
  saldoAplicado: number
  /** El saldo a favor que el modal descontó de lo que había que cobrar (#1509). */
  saldoMostrado?: number
  /** El total que guardó el servidor. Sin él, se toma `totalConEnvio`. */
  totalGuardado?: number
}): string | null {
  const mostrado = redondear(Number(args.saldoMostrado) || 0)
  // #1509: con "Pagado", lo declarado es lo que el modal dijo que había que
  // cobrar, no el total: el saldo a favor que mostró ya estaba descontado.
  const declarado = args.estadoPago === 'pagado'
    ? aCobrarMostrado(args.totalConEnvio, mostrado)
    : args.estadoPago === 'parcial'
      ? redondear(Math.max(0, Number(args.montoDeclarado) || 0))
      : 0
  const distintoDeLoMostrado = mostrado > 0.005 && Math.abs(redondear(args.saldoAplicado) - mostrado) >= 0.01
  const causaSaldo = distintoDeLoMostrado
    ? `el saldo a favor del cliente cubrió ${formatPrecio(args.saldoAplicado)} y no ${formatPrecio(mostrado)}, como mostraba el pedido`
    : `el saldo a favor del cliente cubrió ${formatPrecio(args.saldoAplicado)}`

  const sinRegistrar = redondear(declarado - args.registrado)
  if (sinRegistrar >= 0.01) {
    const causa = args.saldoAplicado > 0.005 ? causaSaldo : 'la boleta no debía más que eso'
    const registro = args.registrado > 0.005
      ? `En el pedido #${args.pedidoId} se registró un cobro de ${formatPrecio(args.registrado)}`
      : `En el pedido #${args.pedidoId} no se registró ningún cobro`
    return `${registro}: ${causa}. Si cobraste ${formatPrecio(declarado)}, ` +
      `${formatPrecio(sinRegistrar)} no quedaron registrados.`
  }

  // #1509: el servidor absorbió menos saldo a favor que el que mostró el modal.
  // Se registró lo que se cobró, y la boleta quedó debiendo la diferencia: con
  // "Pagado" quien carga cree que está saldada.
  if (args.estadoPago === 'pagado' && distintoDeLoMostrado) {
    const total = args.totalGuardado ?? args.totalConEnvio
    const debe = redondear(total - args.saldoAplicado - args.registrado)
    if (debe >= 0.01) {
      return `El pedido #${args.pedidoId} quedó debiendo ${formatPrecio(debe)}: ${causaSaldo}. ` +
        `Se registró el cobro de ${formatPrecio(args.registrado)}.`
    }
  }
  return null
}

interface PagoDeBoleta extends PagoConMarca {
  a_cuenta?: boolean | null
}

/**
 * Si el pago de una boleta es saldo a favor del cliente aplicado a ella (COB-2, #1512): llegó
 * del saldo a favor (`de_saldo_a_favor`), de un pago a cuenta de la ficha (`a_cuenta`) o es un
 * pedazo de otro pago (`pago_origen_id`). Ese pago no se borra: se quita de la boleta y vuelve a
 * ser crédito suelto del cliente (RPC `desimputar_pago`). Un cobro común de la boleta (sin
 * ninguna de las tres marcas) se anula con el DELETE de siempre.
 *
 * Espeja `desimputar_pago` y `trg_pagos_guard_credito_aplicado` (mig 479): si cambia uno,
 * cambian los tres. Un pago suelto (`pedido_id` nulo) no está aplicado a ninguna boleta, aunque
 * conserve las marcas.
 */
export function esSaldoAFavorAplicado(pago: {
  pedido_id?: string | number | null
  de_saldo_a_favor?: boolean | null
  a_cuenta?: boolean | null
  pago_origen_id?: string | number | null
}): boolean {
  if (pago.pedido_id == null) return false
  return Boolean(pago.de_saldo_a_favor) || Boolean(pago.a_cuenta) || pago.pago_origen_id != null
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
