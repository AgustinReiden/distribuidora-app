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
