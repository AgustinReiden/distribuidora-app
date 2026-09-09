/**
 * Aviso de deuda del cliente. AVISA, NO BLOQUEA.
 *
 * Este módulo sólo DA FORMA a un monto que ya viene decidido: quién llama elige
 * qué monto es deuda. Hoy lo usa el alta de pedido, con `clientes.saldo_cuenta`
 * (positivo = debe, negativo = a favor), que es la pregunta correcta ahí: el
 * pedido todavía no existe, así que "cuánto debe ahora" es exactamente lo que el
 * preventista necesita saber antes de cargarle más mercadería.
 *
 * POR QUE ESTO NO SIRVE PARA FECHAR UNA TARJETA
 * ---------------------------------------------
 * `saldo_cuenta` es un escalar del PRESENTE: contiene lo impago de todos los
 * pedidos del cliente, sin importar cuándo se cargaron. La primera versión de
 * este aviso intentó reusarlo en la tarjeta del pedido restándole la parte
 * impaga de ESE pedido, con la idea de quedarse con "lo anterior". No funciona:
 * lo que queda incluye también los pedidos POSTERIORES, así que cada pedido
 * nuevo inflaba el badge de todas las tarjetas viejas del mismo cliente. Medido
 * sobre producción: de 1.083 tarjetas que mostraban el aviso, 1.009 eran falsas
 * —el 93%— con hasta $1.834.150 de sobreestimación en una sola.
 *
 * La deuda que había AL MOMENTO de un pedido no se puede derivar del saldo: hay
 * que sumar lo impago de los pedidos anteriores de ese cliente, y eso se calcula
 * en la base. Si volvés a necesitar el aviso en la tarjeta, traé el monto ya
 * calculado y pasalo acá — no lo derives de `saldo_cuenta`.
 *
 * OFFLINE
 * -------
 * El saldo que ve un teléfono sin señal es el del último sync y no incluye lo
 * que se haya cobrado después. Por eso `saldoAl`: cuando el dato puede estar
 * viejo el texto lo dice y habla en pasado, en vez de afirmar una deuda de
 * ahora.
 */
import { formatPrecio } from './formatters'

/** Un peso: por debajo de un centavo no hay deuda que avisar, hay ruido de float. */
const EPSILON = 0.01

export interface AvisoDeuda {
  /** Deuda en $. Siempre > 0: si no hay deuda no hay aviso. */
  monto: number
  /** Etiqueta corta, para un badge. */
  etiqueta: string
  /** Texto largo, para el alta del pedido. */
  detalle: string
}

export interface AvisoDeudaOpts {
  /**
   * Fecha del dato, ya formateada, cuando el monto puede estar viejo (sin
   * conexión). Si viene, el texto habla en pasado y la incluye.
   */
  saldoAl?: string | null
}

function aNumero(valor: number | null | undefined): number {
  const n = Number(valor)
  return Number.isFinite(n) ? n : 0
}

/** Aviso a mostrar, o null si no hay deuda que avisar. */
export function avisoDeudaCliente(
  montoAdeudado: number | null | undefined,
  opts: AvisoDeudaOpts = {},
): AvisoDeuda | null {
  const monto = Math.round(aNumero(montoAdeudado) * 100) / 100
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

// ---------------------------------------------------------------------------
// Bloque de deuda para la comanda impresa
// ---------------------------------------------------------------------------

/** Una boleta anterior sin pagar, tal como la devuelve `deuda_previa_detalle`. */
export interface BoletaAdeudada {
  id: string | number
  /** Fecha del pedido, `YYYY-MM-DD`. */
  fecha?: string | null
  monto: number
}

export interface LineaDeuda {
  /** Ya formateada para el ticket: "#1234 15/08". */
  etiqueta: string
  monto: number
}

export interface BloqueDeudaComanda {
  /** El total que encabeza el bloque. Es `deuda_previa`, el numero canonico. */
  total: number
  /** Las lineas del desglose. Siempre suman `total`. */
  lineas: LineaDeuda[]
}

/** Cuantas boletas entran en un ticket de 75mm sin comerse el papel. */
const MAX_LINEAS = 6

/** "2026-09-08" -> "08/09". Sin Date: es date-only, y `new Date` la correria de dia. */
function fechaCorta(fecha: string | null | undefined): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(fecha ?? '')
  return m ? `${m[3]}/${m[2]}` : ''
}

/**
 * Desglose de la deuda para imprimir en la comanda, o null si no hay nada que
 * cobrar. El transportista necesita saber QUE boletas reclamar, no solo cuanto:
 * con el numero suelto no puede imputar el cobro.
 *
 * Las lineas SIEMPRE suman el total:
 *  - si hay mas boletas que las que entran en el papel, las que sobran se
 *    agrupan en una linea ("y N boletas mas") con su suma;
 *  - si el total es menor que la suma de las boletas, la diferencia es un pago
 *    a cuenta sin imputar y sale como linea aparte. Hoy no puede pasar (no hay
 *    un solo pago a cuenta en la base), pero si aparece uno, el ticket cuadra
 *    igual en vez de mostrar un desglose que no da.
 */
export function bloqueDeudaComanda(
  total: number | null | undefined,
  boletas: BoletaAdeudada[] | null | undefined,
  opts: { maxLineas?: number } = {},
): BloqueDeudaComanda | null {
  const totalRedondeado = Math.round(aNumero(total) * 100) / 100
  if (totalRedondeado < EPSILON) return null

  const maxLineas = opts.maxLineas ?? MAX_LINEAS
  const items = (boletas ?? []).filter(b => aNumero(b.monto) >= EPSILON)

  const lineas: LineaDeuda[] = []
  const visibles = items.length > maxLineas ? items.slice(0, maxLineas - 1) : items
  for (const b of visibles) {
    const fecha = fechaCorta(b.fecha)
    lineas.push({
      etiqueta: fecha ? `#${b.id} ${fecha}` : `#${b.id}`,
      monto: Math.round(aNumero(b.monto) * 100) / 100,
    })
  }

  const restantes = items.slice(visibles.length)
  if (restantes.length > 0) {
    const suma = restantes.reduce((t, b) => t + aNumero(b.monto), 0)
    lineas.push({
      etiqueta: `y ${restantes.length} boleta${restantes.length === 1 ? '' : 's'} mas`,
      monto: Math.round(suma * 100) / 100,
    })
  }

  // Lo que el total no explica: un pago a cuenta que no esta imputado a
  // ninguna boleta. Va como linea negativa para que el desglose cierre.
  const sumado = lineas.reduce((t, l) => t + l.monto, 0)
  const diferencia = Math.round((totalRedondeado - sumado) * 100) / 100
  if (Math.abs(diferencia) >= EPSILON) {
    lineas.push({ etiqueta: diferencia < 0 ? 'A cuenta' : 'Otros', monto: diferencia })
  }

  return { total: totalRedondeado, lineas }
}
