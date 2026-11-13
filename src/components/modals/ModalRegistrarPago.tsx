import React, { useState, useRef, FormEvent, ChangeEvent } from 'react'
import { z } from 'zod'
import { X, DollarSign, FileText, AlertCircle, Check, Plus, Trash2, Calendar } from 'lucide-react'
import { formatPrecio as formatCurrency, fechaLocalISO } from '../../utils/formatters'
import { parsePrecio } from '../../utils/calculations'
import { faltantePedido, TOLERANCIA_CENTAVOS } from '../../utils/imputacionCredito'
import { FORMAS_PAGO_SELECCIONABLES } from '../../constants/formasPago'
import NumberInput from '../ui/NumberInput'
import MontoLeido from '../ui/MontoLeido'
import { Button } from '../ui/Button'
import { Dialog, DialogContent, DialogDescription, DialogTitle } from '../ui/Dialog'
import { useZodValidation } from '../../hooks/useZodValidation'
import { useRequestIdPersistente } from '../../hooks/useRequestIdPersistente'
import { cobroPudoHaberEntrado } from '../../utils/requestIdPersistente'
import { useFechaMinimaPago } from '../../hooks/queries/useUltimaFechaCajaCerradaQuery'
import type { ClienteDB, Pedido, Pago, FormaPago, RegistrarPagoFifoInput, RegistrarPagoCombinadoFifoInput, RegistrarPagoFifoResult, PagoFifoAplicacion } from '../../types'

// Schema CO-LOCADO a propósito (no en lib/schemas.ts): ver ModalCambioProducto.tsx
// para el incidente de chunk desincronizado que motivó la regla.
// eslint-disable-next-line react-refresh/only-export-components
export const modalPagoSchema = z.object({
  monto: z.coerce
    .number({ error: 'El monto debe ser un número' })
    .positive({ message: 'El monto debe ser mayor a $0' }),

  // Las formas que se registran a mano en formas_pago() del server (#1249); lo
  // vigila src/constants/formasPago.espejo.test.ts.
  formaPago: z.enum(['efectivo', 'transferencia', 'cheque', 'tarjeta', 'adelanto_sueldo'], {
    error: 'Forma de pago inválida'
  }),

  referencia: z.string().optional(),
  notas: z.string().optional(),
  pedidoSeleccionado: z.string().optional()
}).refine(
  (data) => {
    if (data.formaPago === 'cheque') {
      return data.referencia && data.referencia.trim().length > 0
    }
    return true
  },
  { message: 'El número de cheque es obligatorio', path: ['referencia'] }
)

// Alias for the Cliente type used in this component
type Cliente = ClienteDB;

interface FormaPagoOption {
  value: string;
  label: string;
}

// Este modal cobra saldo pendiente (cuenta corriente). Por eso `cuenta_corriente`
// no es una opción válida: no se puede saldar una deuda con otra deuda. Esa forma sí
// aplica en ModalPagoPedido (al entregar un pedido, donde significa "no me pagó, va a CC").
// `vale_blanco` ya no es una forma de pago: es un tipo de comprobante de venta (VB).
// Las opciones salen del espejo de `formas_pago()` (#1249, `constants/formasPago`): las
// seleccionables, que ya excluyen `cuenta_corriente`, `otros` y las no seleccionables. No
// es una lista a mano (COB-6): si el server suma una forma, se suma allá y llega acá.
const FORMAS_PAGO_BASE: FormaPagoOption[] = FORMAS_PAGO_SELECCIONABLES.map(m => ({ value: m.value, label: m.label }))

// #832: cancela deuda como cualquier pago pero NO es dinero (no entra a rendiciones
// ni a efectivo). Solo se ofrece cuando el caller es la ficha del cliente.
const FORMA_ADELANTO_SUELDO: FormaPagoOption = { value: 'adelanto_sueldo', label: 'Adelanto de sueldo' }

interface PagoData {
  clienteId: string;
  pedidoId: string | null;
  monto: number;
  formaPago: string;
  referencia: string;
  notas: string;
  /** Fecha contable del pago (YYYY-MM-DD). Default hoy. */
  fecha: string;
  /**
   * UUID de idempotencia (mig 167). Estable mientras no cambien los datos del
   * pago, así un reintento tras un error de red no lo duplica.
   */
  clientRequestId?: string;
}

/**
 * Un pago dividido sobre UNA boleta: todas las formas van juntas, en una sola
 * llamada a `registrar_pagos_pedido`, con una sola clave (#1476, COB-F-3).
 */
export interface PagoDivididoPedidoData {
  clienteId: string;
  pedidoId: string;
  pagos: Array<{ formaPago: string; monto: number }>;
  notas: string;
  fecha: string;
  /** Una para todo el cobro: mientras los pagos no cambien, un reintento lleva la misma. */
  clientRequestId: string;
}

interface PagoRegistrado extends Pago {
  monto: number;
  /** El server ya tenía la clave: devolvió el cobro de un intento anterior (#1410). */
  idempotentReplay?: boolean;
}

interface PagoDividido {
  monto: string;
  formaPago: string;
}

export interface ModalRegistrarPagoProps {
  cliente: Cliente | null;
  saldoPendiente: number;
  /** El resumen de cuenta falló (COB-F-6): se avisa en vez de mostrar un saldo 0 inventado. */
  saldoNoDisponible?: boolean;
  pedidos: Pedido[];
  onClose: () => void;
  onConfirmar: (data: PagoData) => Promise<PagoRegistrado>;
  /**
   * Si se provee, al confirmar sin pedido especifico el modal puede llamar a
   * esta funcion para distribuir el pago automaticamente sobre los pedidos
   * mas antiguos (FIFO). Sobrante queda como saldo a favor.
   */
  onConfirmarFIFO?: (input: RegistrarPagoFifoInput) => Promise<RegistrarPagoFifoResult>;
  /**
   * Si se provee, un pago dividido sin pedido específico se imputa por FIFO de
   * forma atómica (una transacción server-side) en lugar de insertar filas a
   * cuenta general. Sin esto, el dividido a cuenta general quedaría sin imputar.
   */
  onConfirmarCombinadoFIFO?: (input: RegistrarPagoCombinadoFifoInput) => Promise<RegistrarPagoFifoResult>;
  /**
   * Pago dividido sobre una boleta concreta: una sola llamada atómica con todas
   * las formas (`registrar_pagos_pedido` acepta varias). Sin esto, el dividido
   * sobre una boleta no se puede registrar: hacerlo línea por línea deja la
   * primera cobrada si la segunda se rechaza (COB-F-3).
   */
  onConfirmarDividido?: (data: PagoDivididoPedidoData) => Promise<PagoRegistrado>;
  onGenerarRecibo?: (pago: PagoRegistrado, cliente: Cliente) => void;
  /**
   * Si se provee, muestra el botón "Entregar a cuenta corriente (sin cobrar)"
   * (flujo del transportista al entregar): entrega sin registrar pago. Debe
   * rechazar (throw) si falla para mantener el modal abierto.
   */
  onEntregarSinCobrar?: () => void | Promise<void>;
  /**
   * Cobro de UNA parada concreta (ruta activa): imputa el pago a ese pedido y
   * oculta el selector "Aplicar a Pedido". Sin esto el selector arranca en
   * "Pago a cuenta general" y el pago sale con pedido_id NULL, dejando el
   * pedido entregado e impago (el trigger de monto_pagado necesita el pedido).
   * Además, la RLS solo deja cobrar al transportista si el pago apunta a un
   * pedido suyo, así que a cuenta general el INSERT le sería rechazado.
   *
   * Con `pedidoIdFijo`, `saldoPendiente` tiene que ser lo que FALTA de esa boleta, leído en
   * vivo (lo hace la ruta activa): contra eso se miden el tope, los porcentajes y el aviso de
   * que el cobro se va a rechazar si lo pasa (COB-5).
   */
  pedidoIdFijo?: string;
  /**
   * Ofrece la forma "Adelanto de sueldo" (#832). Solo lo activa la ficha del
   * cliente: el empleado es un cliente y el pago no es dinero. El resto de los
   * llamadores (ruta activa, pedidos) no lo pasan.
   */
  permitirAdelantoSueldo?: boolean;
  /**
   * ¿El cliente es la ficha de un empleado? Sólo se mira con `permitirAdelantoSueldo`
   * y el adelanto elegido: `false` lo bloquea (no hay a quién descontárselo),
   * `null`/`undefined` es «todavía comprobando» y también bloquea.
   */
  clienteEsEmpleado?: boolean | null;
}

const AVISO_NO_ES_EMPLEADO =
  'Este cliente no es la ficha de un empleado: el adelanto de sueldo no se le puede descontar. Vinculá la ficha desde Personal o elegí otra forma de pago.'
const AVISO_COMPROBANDO_EMPLEADO = 'Comprobando si es la ficha de un empleado…'

// Las tres pantallas (formulario, éxito simple, éxito FIFO) son UN diálogo de
// `ui/Dialog` (#810): role="dialog" con título, aria-modal, foco adentro al
// montar y Tab que no sale. Antes eran tres `div fixed inset-0 z-50` hechos a
// mano: sin trap, el foco quedaba detrás del overlay (desde la Ficha Cliente
// volvía a «Ver ficha» y un Enter la reabría encima del pago).
//
// Las clases reproducen el aspecto de esos overlays sobre el `DialogContent`
// (`cn` pisa sus defaults de a grupo). El overlay de `ui/Dialog` es el mismo
// `bg-black/50 z-50` que había, ahora portaleado al final de <body>: sigue
// arriba del header (z-50) y de la barra de la parada de la ruta (z-40).

/**
 * Formulario. Celular: bottom sheet de borde a borde, pegado abajo y con las
 * esquinas de arriba redondeadas (`items-end` sin padding del overlay viejo).
 * Ahí se centra con `left/right-0 + mx-auto` y no con `translate`, porque el
 * `slide-up` anima `transform`; y el `dialog-in` de `ui/Dialog`, que lleva el
 * `translate(-50%, -50%)` del centrado, se pisa con `max-sm:` y no con `cn`
 * (tailwind-merge no conoce las animaciones propias y deja las dos clases: la
 * media query es la que gana sin depender del orden del CSS). Desde `sm`:
 * centrado, con 16 px de aire (el `sm:p-4` del overlay viejo) que también
 * acota el alto, y con el `dialog-in` de siempre.
 *
 * Es el único que lleva `data-sheet-movil` (ver `DialogoPago`): en el celular
 * es un sheet y los avisos tienen que subir (#899).
 */
const CLASES_FORMULARIO = [
  'left-0 right-0 top-auto bottom-0 mx-auto w-full translate-x-0 translate-y-0',
  'rounded-none rounded-t-2xl max-h-[95dvh] shadow-none',
  'max-sm:data-[state=open]:animate-slide-up',
  'sm:left-[50%] sm:right-auto sm:top-[50%] sm:bottom-auto sm:mx-0 sm:w-[calc(100%-2rem)]',
  'sm:translate-x-[-50%] sm:translate-y-[-50%] sm:rounded-2xl sm:max-h-[min(95dvh,calc(100dvh-2rem))]',
].join(' ')

/**
 * Pantallas de éxito: centradas en todos los anchos, como el overlay viejo
 * (`items-center p-4`), y en bloque y no en columna flex para que los márgenes
 * de adentro colapsen igual que antes.
 */
const CLASES_EXITO_FIFO = 'block rounded-2xl p-6 shadow-none max-h-[90dvh] overflow-y-auto'
const CLASES_EXITO_SIMPLE = 'block rounded-2xl p-6 shadow-none max-h-none overflow-visible'

/** Cancela el cierre de Radix: ni Escape, ni el fondo, ni el foco afuera. */
const bloquearCierre = (event: Event): void => event.preventDefault()

/**
 * El diálogo que envuelve las tres pantallas. Es un modal de plata: hoy no se
 * cierra con Escape ni con un click en el fondo, y eso no cambia. Lo cierran
 * sólo sus botones, que llaman a `onClose`. Como las tres pantallas lo
 * devuelven en la misma posición, React no lo remonta al pasar del formulario
 * al éxito: no hay segunda animación y «quién abrió» se registra una sola vez.
 */
function DialogoPago({
  className,
  sheetMovil = false,
  onClose,
  children,
}: {
  className: string
  /**
   * Sólo el formulario: en el celular es un sheet pegado abajo y lleva
   * `data-sheet-movil`, el gancho que lee index.css para subir la pila de
   * avisos (#899, la misma regla de #852). Las pantallas de éxito son diálogos
   * centrados y no lo llevan. No reusa `data-slot="bottom-sheet"`, que es de
   * `ui/BottomSheet`.
   */
  sheetMovil?: boolean
  onClose: () => void
  children: React.ReactNode
}): React.ReactElement {
  return (
    <Dialog open onOpenChange={(abierto) => { if (!abierto) onClose() }}>
      <DialogContent
        className={className}
        data-sheet-movil={sheetMovil ? '' : undefined}
        onEscapeKeyDown={bloquearCierre}
        onPointerDownOutside={bloquearCierre}
        onFocusOutside={bloquearCierre}
        onInteractOutside={bloquearCierre}
      >
        {children}
      </DialogContent>
    </Dialog>
  )
}

export default function ModalRegistrarPago({
  cliente,
  saldoPendiente,
  saldoNoDisponible = false,
  pedidos,
  onClose,
  onConfirmar,
  onConfirmarFIFO,
  onConfirmarCombinadoFIFO,
  onConfirmarDividido,
  onGenerarRecibo,
  onEntregarSinCobrar,
  pedidoIdFijo,
  permitirAdelantoSueldo = false,
  clienteEsEmpleado
}: ModalRegistrarPagoProps): React.ReactElement | null {
  // Zod validation hook
  const { validate, getFirstError } = useZodValidation(modalPagoSchema)

  const [monto, setMonto] = useState<string>('')
  const [formaPago, setFormaPago] = useState<string>('efectivo')
  const [referencia, setReferencia] = useState<string>('')
  const [notas, setNotas] = useState<string>('')
  const [pedidoSeleccionado, setPedidoSeleccionado] = useState<string>(pedidoIdFijo ?? '')
  // #1293: una boleta elegida se cobra por `registrar_pagos_pedido`, que sólo
  // toma plata. El adelanto de sueldo va a cuenta, por el FIFO de la ficha, que
  // es de admin y encargado: con una boleta elegida no se ofrece.
  const FORMAS_PAGO = permitirAdelantoSueldo && !pedidoSeleccionado
    ? [...FORMAS_PAGO_BASE, FORMA_ADELANTO_SUELDO]
    : FORMAS_PAGO_BASE
  // COB-5 (#1512): con una boleta elegida el tope es lo que le FALTA a esa boleta, no el
  // saldo del cliente: `registrar_pagos_pedido` rechaza el cobro que pasa lo que falta, y la
  // boleta no deja saldo a favor (eso sólo lo hace el pago a cuenta general, por el FIFO).
  // - Con `pedidoIdFijo` (la parada del chofer) `saldoPendiente` ya es lo que falta de esa
  //   boleta, leído en vivo: es el dato fresco que se relee tras un fallo (#1410). `pedidos`
  //   trae ahí una foto sacada al abrir el modal, con el `monto_pagado` de antes del cobro.
  // - Con la boleta elegida del selector, sale de `pedidos` (`faltantePedido`).
  // `null` = sin boleta: todo se mide contra el saldo del cliente, como siempre.
  const pedidoElegido = pedidoSeleccionado && !pedidoIdFijo
    ? (pedidos || []).find(p => String(p.id) === pedidoSeleccionado)
    : undefined
  const faltaBoleta: number | null = !pedidoSeleccionado
    ? null
    : pedidoElegido
      ? faltantePedido(pedidoElegido)
      : Math.max(0, saldoPendiente)
  // Contra qué se mide: lo que falta de la boleta o el saldo del cliente.
  const baseMedida = faltaBoleta ?? saldoPendiente
  const [loading, setLoading] = useState<boolean>(false)
  const [pagoRegistrado, setPagoRegistrado] = useState<PagoRegistrado | null>(null)
  const [resultadoFIFO, setResultadoFIFO] = useState<RegistrarPagoFifoResult | null>(null)
  const [error, setError] = useState<string>('')
  const [fecha, setFecha] = useState<string>(fechaLocalISO())
  // Fecha minima: dia siguiente al ultimo cierre de caja de la sucursal (mig 134).
  const fechaMinima = useFechaMinimaPago()

  // Idempotencia (mig 167). Dos guardas complementarias:
  //  - `enVueloRef` corta el doble toque instantaneo, que puede disparar dos
  //    submits antes de que React re-renderice con loading=true.
  //  - `requestIdPersistente` hace que el reintento DESPUES de un error use el
  //    mismo UUID, asi el server lo reconoce y no vuelve a cobrar, aunque el
  //    modal se haya cerrado o la app se haya recargado (#1410). Cambiar el monto
  //    o la forma de pago cambia la huella y acuña un UUID nuevo: eso si es otro
  //    pago. Cuando el cobro sale bien, sus huellas se olvidan.
  const enVueloRef = useRef<boolean>(false)
  const { requestId, olvidar } = useRequestIdPersistente()
  // Un cobro a una boleta que falló sin saber si entró (#1410). Si el saldo vivo
  // bajó justo eso, entró: repetirlo igual lo confirma sin cobrar de nuevo, y el
  // aviso de "excede el saldo" mentiría (la boleta no deja saldo a favor).
  const [intentoSinConfirmar, setIntentoSinConfirmar] =
    useState<{ total: number; saldoAlIntentar: number } | null>(null)
  const cobroAnteriorFigura = !!intentoSinConfirmar &&
    baseMedida <= intentoSinConfirmar.saldoAlIntentar - intentoSinConfirmar.total + 0.01

  // Pago dividido
  const [pagoDividido, setPagoDividido] = useState<boolean>(false)
  const [pagos, setPagos] = useState<PagoDividido[]>([
    { monto: '', formaPago: 'efectivo' },
    { monto: '', formaPago: 'transferencia' },
  ])

  const totalDividido = pagos.reduce((sum, p) => sum + parsePrecio(p.monto), 0)

  // COB-5: con una boleta, pasarse de lo que falta NO deja saldo a favor: el server rechaza el
  // cobro. Se avisa y no se deja confirmar. Si un intento anterior sin confirmar ya figura
  // (`cobroAnteriorFigura`), repetirlo igual no cobra de nuevo: ahí no se frena.
  const montoIngresado = pagoDividido ? totalDividido : parsePrecio(monto)
  const pasaDeLaBoleta = faltaBoleta !== null && !cobroAnteriorFigura &&
    montoIngresado > faltaBoleta + TOLERANCIA_CENTAVOS
  const textoPasaDeLaBoleta = faltaBoleta === null ? '' : (
    faltaBoleta > TOLERANCIA_CENTAVOS
      ? `El monto excede lo que falta de la boleta en ${formatCurrency(montoIngresado - faltaBoleta)} y el cobro se va a rechazar: una boleta no deja saldo a favor. ` +
        `Cobrá hasta ${formatCurrency(faltaBoleta)}${pedidoIdFijo ? '.' : ', o elegí «Pago a cuenta general» para que lo que sobre quede a favor.'}`
      : 'Esta boleta no tiene nada pendiente de cobro: el cobro se va a rechazar.'
  )

  // El adelanto de sueldo se descuenta de la ficha del empleado: si el cliente no
  // lo es (o todavía no se sabe), no se puede confirmar. Se mira la forma elegida
  // ahora —en el pago simple o en alguna línea del dividido—, no sólo el permiso.
  const adelantoElegido = permitirAdelantoSueldo && !pedidoSeleccionado && (
    pagoDividido
      ? pagos.some(p => p.formaPago === FORMA_ADELANTO_SUELDO.value)
      : formaPago === FORMA_ADELANTO_SUELDO.value
  )
  const adelantoSinEmpleado = adelantoElegido && clienteEsEmpleado === false
  const adelantoComprobando = adelantoElegido && clienteEsEmpleado == null
  const adelantoBloqueado = adelantoSinEmpleado || adelantoComprobando

  const handleAddPago = () => {
    setPagos(prev => [...prev, { monto: '', formaPago: 'efectivo' }])
  }

  const handleRemovePago = (index: number) => {
    if (pagos.length <= 2) return
    setPagos(prev => prev.filter((_, i) => i !== index))
  }

  const handlePagoChange = (index: number, field: keyof PagoDividido, value: string) => {
    setPagos(prev => prev.map((p, i) => i === index ? { ...p, [field]: value } : p))
  }

  // Al elegir una boleta el adelanto deja de ofrecerse: si ya estaba elegido,
  // vuelve a efectivo en vez de quedar marcado sin botón.
  const handlePedidoChange = (pedidoId: string) => {
    setPedidoSeleccionado(pedidoId)
    if (!pedidoId) return
    const adelanto = FORMA_ADELANTO_SUELDO.value
    if (formaPago === adelanto) setFormaPago('efectivo')
    setPagos(prev => prev.map(p => p.formaPago === adelanto ? { ...p, formaPago: 'efectivo' } : p))
  }

  // Filter pending payment orders
  const pedidosPendientes = (pedidos || []).filter(p =>
    p.cliente_id === cliente?.id && p.estado_pago !== 'pagado'
  )

  const handleSubmit = async (e: FormEvent<HTMLFormElement>): Promise<void> => {
    e.preventDefault()
    if (enVueloRef.current) return
    setError('')

    // Mismo corte para las tres ramas (FIFO, dividido y simple).
    if (adelantoBloqueado) {
      setError(adelantoSinEmpleado ? AVISO_NO_ES_EMPLEADO : AVISO_COMPROBANDO_EMPLEADO)
      return
    }
    if (pasaDeLaBoleta) {
      setError(textoPasaDeLaBoleta)
      return
    }

    // FIFO siempre aplica cuando: no es pago dividido, no hay pedido específico
    // seleccionado, y el caller proveyó onConfirmarFIFO. Si no hay pedidos
    // pendientes el sobrante queda como saldo a favor automaticamente.
    const usarFIFO = !pagoDividido && !pedidoSeleccionado && !!onConfirmarFIFO

    // Huella del pago: todo lo que lo hace "este pago y no otro". Mientras no
    // cambie, los reintentos comparten UUID y el server los deduplica.
    const huellaBase = [cliente!.id, pedidoSeleccionado || 'general', fecha, notas].join('|')

    if (usarFIFO) {
      const montoNumero = parsePrecio(monto)
      if (!montoNumero || montoNumero <= 0) {
        setError('Ingresá un monto válido')
        return
      }
      const huella = `fifo|${huellaBase}|${montoNumero}|${formaPago}|${referencia}`
      enVueloRef.current = true
      setLoading(true)
      try {
        const result = await onConfirmarFIFO!({
          clienteId: cliente!.id,
          monto: montoNumero,
          formaPago,
          fecha,
          referencia: referencia || undefined,
          notas: notas || undefined,
          clientRequestId: requestId(huella),
        })
        olvidar([huella])
        setResultadoFIFO(result)
      } catch (err) {
        const errorMessage = err instanceof Error ? err.message : 'Error al registrar el pago'
        setError(errorMessage)
      } finally {
        setLoading(false)
        enVueloRef.current = false
      }
      return
    }

    if (pagoDividido) {
      // Validar pagos divididos
      const pagosValidos = pagos.filter(p => parsePrecio(p.monto) > 0)
      if (pagosValidos.length < 2) {
        setError('Ingresa al menos 2 formas de pago con monto mayor a 0')
        return
      }

      // Pago dividido a cuenta general (sin pedido específico): imputación FIFO
      // atómica server-side. Cada forma se aplica a los pedidos más antiguos con
      // saldo pendiente y el sobrante queda como saldo a favor. Espeja la
      // condición de `usarFIFO` del pago simple: sin esto, las filas se
      // insertarían con pedido_id NULL y no actualizarían el saldo del cliente.
      const huellaDividido = `${huellaBase}|${pagosValidos.map(p => `${parsePrecio(p.monto)}@${p.formaPago}`).join(',')}`

      if (!pedidoSeleccionado && onConfirmarCombinadoFIFO) {
        enVueloRef.current = true
        setLoading(true)
        try {
          const result = await onConfirmarCombinadoFIFO({
            clienteId: cliente!.id,
            metodos: pagosValidos.map(p => ({ monto: parsePrecio(p.monto), formaPago: p.formaPago })),
            fecha,
            notas: notas || undefined,
            clientRequestId: requestId(`combo|${huellaDividido}`),
          })
          olvidar([`combo|${huellaDividido}`])
          setResultadoFIFO(result)
        } catch (err) {
          const errorMessage = err instanceof Error ? err.message : 'Error al registrar el pago'
          setError(errorMessage)
        } finally {
          setLoading(false)
          enVueloRef.current = false
        }
        return
      }

      // Dividido aplicado a una boleta específica: UNA llamada con todas las
      // formas (COB-F-3). Antes era una RPC por línea: si la segunda se rechazaba
      // la primera quedaba cobrada, y al corregir los montos cambiaban las claves
      // y la primera volvía a entrar. Ahora el cobro es atómico y su clave es una.
      if (!pedidoSeleccionado || !onConfirmarDividido) {
        setError('El pago dividido sobre una boleta no está disponible desde esta pantalla.')
        return
      }
      const huellaBoleta = `divid|${huellaDividido}`
      enVueloRef.current = true
      setLoading(true)
      try {
        const total = pagosValidos.reduce((s, p) => s + parsePrecio(p.monto), 0)
        const cobro = await onConfirmarDividido({
          clienteId: cliente!.id,
          pedidoId: pedidoSeleccionado,
          pagos: pagosValidos.map(p => ({ formaPago: p.formaPago, monto: parsePrecio(p.monto) })),
          notas: notas ? `${notas} (pago dividido)` : 'Pago dividido',
          fecha,
          clientRequestId: requestId(huellaBoleta),
        })
        olvidar([huellaBoleta])
        setIntentoSinConfirmar(null)
        // La pantalla de éxito muestra lo cobrado entero, no sólo la última línea.
        setPagoRegistrado({ ...cobro, monto: total })
      } catch (err) {
        const errorMessage = err instanceof Error ? err.message : 'Error al registrar el pago'
        setError(errorMessage)
        if (pedidoSeleccionado && cobroPudoHaberEntrado(err)) {
          setIntentoSinConfirmar(prev => prev ?? {
            total: pagosValidos.reduce((s, p) => s + parsePrecio(p.monto), 0),
            saldoAlIntentar: baseMedida,
          })
        }
      } finally {
        setLoading(false)
        enVueloRef.current = false
      }
    } else {
      // Pago simple (a pedido específico o a cuenta general sin FIFO)
      const result = validate({ monto: parsePrecio(monto), formaPago, referencia, notas, pedidoSeleccionado })
      if (!result.success) {
        setError(getFirstError() || 'Error de validacion')
        return
      }

      const huella = `simple|${huellaBase}|${result.data.monto}|${formaPago}|${referencia}`
      enVueloRef.current = true
      setLoading(true)
      try {
        const pago = await onConfirmar({
          clienteId: cliente!.id,
          pedidoId: pedidoSeleccionado || null,
          monto: result.data.monto,
          formaPago,
          referencia,
          notas,
          fecha,
          clientRequestId: requestId(huella),
        })
        olvidar([huella])
        setIntentoSinConfirmar(null)
        setPagoRegistrado(pago)
      } catch (err) {
        const errorMessage = err instanceof Error ? err.message : 'Error al registrar el pago'
        setError(errorMessage)
        if (pedidoSeleccionado && cobroPudoHaberEntrado(err)) {
          // Se queda con el primero: es contra ese saldo que se mide si entró.
          setIntentoSinConfirmar(prev => prev ?? { total: result.data.monto, saldoAlIntentar: baseMedida })
        }
      } finally {
        setLoading(false)
        enVueloRef.current = false
      }
    }
  }

  const handleMontoPreset = (porcentaje: number): void => {
    if (baseMedida) {
      setMonto((baseMedida * porcentaje / 100).toFixed(2))
    }
  }

  const handleEntregarSinCobrar = async (): Promise<void> => {
    if (!onEntregarSinCobrar) return
    setError('')
    setLoading(true)
    try {
      await onEntregarSinCobrar()
    } catch (err) {
      // El padre ya notifica el error; mantenemos el modal abierto para reintentar.
      setError(err instanceof Error ? err.message : 'Error al entregar')
    } finally {
      setLoading(false)
    }
  }

  if (!cliente) return null

  // Success screen FIFO: muestra desglose por pedido + sobrante
  if (resultadoFIFO) {
    return (
      <DialogoPago className={CLASES_EXITO_FIFO} onClose={onClose}>
        <div className="text-center">
          <div className="w-16 h-16 bg-green-100 dark:bg-green-900/30 rounded-full flex items-center justify-center mx-auto mb-4">
            <Check className="w-8 h-8 text-green-600" />
          </div>
          <DialogTitle className="text-2xl font-bold text-gray-900 dark:text-white mb-2">
            Pago Registrado
          </DialogTitle>
          <DialogDescription className="text-base text-gray-600 dark:text-gray-400 mb-4">
            Total imputado: <span className="font-bold text-green-600">{formatCurrency(resultadoFIFO.montoTotal)}</span> para {cliente.nombre_fantasia}
          </DialogDescription>
          {resultadoFIFO.creditoAplicado > 0 && (
            <p className="text-sm text-emerald-700 dark:text-emerald-300 mb-4 px-3 py-2 bg-emerald-50 dark:bg-emerald-900/20 rounded-lg">
              Además se usó {formatCurrency(resultadoFIFO.creditoAplicado)} de saldo a favor que el cliente ya tenía.
            </p>
          )}
          {resultadoFIFO.idempotentReplay && (
            <p className="text-sm text-blue-700 dark:text-blue-300 mb-4 px-3 py-2 bg-blue-50 dark:bg-blue-900/20 rounded-lg">
              Este pago ya había entrado en tu intento anterior: no se cobró dos veces. Abajo está el detalle de esa imputación.
            </p>
          )}
        </div>
        <div className="mt-2 space-y-2">
          <p className="text-sm font-medium text-gray-700 dark:text-gray-300">Desglose:</p>
          {resultadoFIFO.aplicaciones.length === 0 ? (
            <p className="text-sm text-gray-500">Sin aplicaciones.</p>
          ) : resultadoFIFO.aplicaciones.map((ap: PagoFifoAplicacion) => (
            <div key={ap.pago_id} className="flex items-center justify-between p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg text-sm">
              <div>
                {ap.pedido_id ? (
                  <>
                    <p className="font-medium text-gray-900 dark:text-white">Pedido #{ap.pedido_id}</p>
                    {ap.pedido_fecha && (
                      <p className="text-xs text-gray-500">{ap.pedido_fecha}</p>
                    )}
                  </>
                ) : (
                  <p className="font-medium text-emerald-700 dark:text-emerald-300">Saldo a favor</p>
                )}
              </div>
              <p className="font-bold text-gray-900 dark:text-white">{formatCurrency(ap.monto)}</p>
            </div>
          ))}
          {resultadoFIFO.sobrante > 0 && (
            <p className="text-xs text-emerald-600 dark:text-emerald-400">
              Quedó un saldo a favor de {formatCurrency(resultadoFIFO.sobrante)} disponible para futuros pedidos.
            </p>
          )}
        </div>
        <div className="mt-6 flex justify-center">
          <Button onClick={onClose} variant="secondary" size="md">
            Cerrar
          </Button>
        </div>
      </DialogoPago>
    )
  }

  // Success screen
  if (pagoRegistrado) {
    return (
      <DialogoPago className={CLASES_EXITO_SIMPLE} onClose={onClose}>
        <div className="text-center">
          <div className="w-16 h-16 bg-green-100 dark:bg-green-900/30 rounded-full flex items-center justify-center mx-auto mb-4">
            <Check className="w-8 h-8 text-green-600" />
          </div>
          <DialogTitle className="text-2xl font-bold text-gray-900 dark:text-white mb-2">
            Pago Registrado
          </DialogTitle>
          <DialogDescription className="text-base text-gray-600 dark:text-gray-400 mb-4">
            Se registro un pago de <span className="font-bold text-green-600">{formatCurrency(pagoRegistrado.monto)}</span> para {cliente.nombre_fantasia}
          </DialogDescription>
          {pagoRegistrado.idempotentReplay && (
            <p className="text-sm text-blue-700 dark:text-blue-300 mb-4 px-3 py-2 bg-blue-50 dark:bg-blue-900/20 rounded-lg">
              Este pago ya había entrado en tu intento anterior: no se cobró dos veces.
            </p>
          )}
          <div className="flex gap-3 justify-center">
            {onGenerarRecibo && (
              <Button onClick={() => onGenerarRecibo(pagoRegistrado, cliente)} variant="primary" size="md">
                <FileText className="w-4 h-4" />
                Generar Recibo
              </Button>
            )}
            <Button onClick={onClose} variant="secondary" size="md">
              Cerrar
            </Button>
          </div>
        </div>
      </DialogoPago>
    )
  }

  return (
    <DialogoPago className={CLASES_FORMULARIO} sheetMovil onClose={onClose}>
      {/* Header */}
      <div className="flex-shrink-0 p-4 sm:p-6 border-b border-gray-200 dark:border-gray-700">
        <div className="flex justify-between items-center">
          <div>
            <DialogTitle className="text-xl font-bold text-gray-900 dark:text-white">Registrar Pago</DialogTitle>
            <DialogDescription className="text-base text-gray-600 dark:text-gray-400">{cliente.nombre_fantasia}</DialogDescription>
          </div>
          <Button onClick={onClose} variant="ghost" size="iconSm" aria-label="Cerrar">
            <X className="w-5 h-5" />
          </Button>
        </div>

        {/* Balance info */}
        {saldoNoDisponible && (
          <div className="mt-4 p-3 bg-yellow-50 dark:bg-yellow-900/20 rounded-lg">
            <span className="text-yellow-700 dark:text-yellow-400">Saldo no disponible</span>
          </div>
        )}
        {saldoPendiente > 0 && (
          <div className="mt-4 p-3 bg-yellow-50 dark:bg-yellow-900/20 rounded-lg">
            <div className="flex justify-between items-center">
              <span className="text-yellow-700 dark:text-yellow-400">Saldo pendiente:</span>
              <span className="text-xl font-bold text-yellow-700 dark:text-yellow-400">
                {formatCurrency(saldoPendiente)}
              </span>
            </div>
          </div>
        )}
        {saldoPendiente < 0 && (
          <div className="mt-4 p-3 bg-green-50 dark:bg-green-900/20 rounded-lg">
            <div className="flex justify-between items-center">
              <span className="text-green-700 dark:text-green-400">Saldo a favor:</span>
              <span className="text-xl font-bold text-green-700 dark:text-green-400">
                {formatCurrency(Math.abs(saldoPendiente))}
              </span>
            </div>
          </div>
        )}
      </div>

      {/* Form */}
      <form onSubmit={handleSubmit} className="flex-1 flex flex-col min-h-0">
        <div className="flex-1 overflow-y-auto p-4 sm:p-6 space-y-4">
        {error && (
          <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg flex items-center gap-2 text-red-700 dark:text-red-400">
            <AlertCircle className="w-4 h-4" />
            {error}
          </div>
        )}

        {/* Fecha contable del pago */}
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1 flex items-center gap-1">
            <Calendar className="w-4 h-4" />
            Fecha del pago
          </label>
          <input
            type="date"
            value={fecha}
            min={fechaMinima}
            max={fechaLocalISO()}
            onChange={(e: ChangeEvent<HTMLInputElement>) => setFecha(e.target.value)}
            className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
          />
          <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
            Se imputa a la rendición de esa fecha. Por defecto hoy; otra fecha la carga solo un admin.
            {fechaMinima && ' No se permiten fechas con la caja ya cerrada.'}
          </p>
        </div>

        {/* Toggle pago dividido */}
        <label className="flex items-center gap-2 cursor-pointer">
          <input
            type="checkbox"
            checked={pagoDividido}
            onChange={e => setPagoDividido(e.target.checked)}
            className="w-4 h-4 rounded border-gray-300 text-blue-600"
          />
          <span className="text-sm font-medium text-gray-700 dark:text-gray-300">
            Pago dividido (multiples formas de pago)
          </span>
        </label>

        {cobroAnteriorFigura && intentoSinConfirmar && (
          <div className="p-3 bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg flex items-start gap-2 text-blue-800 dark:text-blue-200">
            <AlertCircle className="w-4 h-4 mt-0.5 flex-shrink-0" />
            <p className="text-sm">
              El cobro de <span className="font-semibold">{formatCurrency(intentoSinConfirmar.total)}</span> que quedó sin
              confirmar ya figura en la cuenta: el saldo bajó. Para confirmarlo, registralo de nuevo con los mismos datos:
              no se cobra dos veces.
            </p>
          </div>
        )}

        {/* COB-5: con una boleta elegida el cobro no puede pasar lo que falta. */}
        {pasaDeLaBoleta && (
          <div role="alert" className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg flex items-start gap-2 text-red-800 dark:text-red-200">
            <AlertCircle className="w-4 h-4 mt-0.5 flex-shrink-0" />
            <p className="text-sm">{textoPasaDeLaBoleta}</p>
          </div>
        )}

        {/* Warning de saldo a favor (sin boleta: el pago a cuenta deja el sobrante a favor) */}
        {faltaBoleta === null && !cobroAnteriorFigura && !pagoDividido && parsePrecio(monto) > saldoPendiente && saldoPendiente > 0 && (
          <div className="p-3 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg flex items-start gap-2 text-yellow-800 dark:text-yellow-200">
            <AlertCircle className="w-4 h-4 mt-0.5 flex-shrink-0" />
            <p className="text-sm">
              El monto excede el saldo pendiente en{' '}
              <span className="font-semibold">{formatCurrency(parsePrecio(monto) - saldoPendiente)}</span>.{' '}
              La diferencia quedará como saldo a favor.
            </p>
          </div>
        )}

        {pagoDividido ? (
          <>
            {/* Pagos divididos */}
            <div className="space-y-3">
              {pagos.map((pago, index) => (
                <div key={index} className="flex items-center gap-2 p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
                  <div className="flex-1">
                    <div className="relative">
                      <DollarSign className="absolute left-2 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
                      <NumberInput
                        min={0}
                        emptyValue={0}
                        commitOnChange
                        value={Number(pago.monto) || 0}
                        onChange={(n) => handlePagoChange(index, 'monto', String(n))}
                        placeholder="0.00"
                        className="w-full pl-7 pr-2 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white text-sm font-semibold"
                      />
                    </div>
                    <MontoLeido monto={parsePrecio(pago.monto)} />
                  </div>
                  <select
                    value={pago.formaPago}
                    onChange={e => handlePagoChange(index, 'formaPago', e.target.value)}
                    className="px-2 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white text-sm"
                  >
                    {FORMAS_PAGO.map(fp => (
                      <option key={fp.value} value={fp.value}>{fp.label}</option>
                    ))}
                  </select>
                  {pagos.length > 2 && (
                    <button type="button" onClick={() => handleRemovePago(index)} className="p-1 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded">
                      <Trash2 className="w-4 h-4" />
                    </button>
                  )}
                </div>
              ))}
              <Button
                type="button"
                variant="ghost"
                size="md"
                onClick={handleAddPago}
                className="w-full gap-1 text-blue-600 dark:text-blue-400 hover:bg-blue-50 dark:hover:bg-blue-900/20 border border-dashed border-blue-300 dark:border-blue-700"
              >
                <Plus className="w-4 h-4" />
                Agregar forma de pago
              </Button>
            </div>

            {/* Total dividido */}
            <div className="p-3 bg-blue-50 dark:bg-blue-900/20 rounded-lg">
              <div className="flex justify-between items-center">
                <span className="text-sm text-blue-700 dark:text-blue-300">Total a pagar:</span>
                <span className="text-lg font-bold text-blue-700 dark:text-blue-400">
                  {formatCurrency(totalDividido)}
                </span>
              </div>
              {faltaBoleta !== null ? (
                faltaBoleta > 0 && totalDividido !== faltaBoleta && (
                  <p className="text-xs text-blue-500 mt-1">
                    Falta de la boleta: {formatCurrency(faltaBoleta)}
                    {totalDividido > faltaBoleta && ' (excede lo que falta)'}
                  </p>
                )
              ) : saldoPendiente > 0 && totalDividido !== saldoPendiente && (
                <p className="text-xs text-blue-500 mt-1">
                  Saldo pendiente: {formatCurrency(saldoPendiente)}
                  {totalDividido > saldoPendiente && ' (excede el saldo)'}
                </p>
              )}
            </div>
          </>
        ) : (
          <>
            {/* Monto (pago simple) */}
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                Monto *
              </label>
              <div className="relative">
                <DollarSign className="absolute left-3 top-1/2 -translate-y-1/2 w-5 h-5 text-gray-400" />
                <NumberInput
                  min={0}
                  emptyValue={0}
                  commitOnChange
                  value={Number(monto) || 0}
                  onChange={(n) => setMonto(String(n))}
                  placeholder="0.00"
                  className="w-full pl-10 pr-4 py-3 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white text-lg font-semibold"
                  required
                />
              </div>
              <MontoLeido monto={parsePrecio(monto)} />
              {baseMedida > 0 && (
                <div className="flex gap-2 mt-2">
                  <button
                    type="button"
                    onClick={() => handleMontoPreset(100)}
                    className="px-3 py-1 text-xs bg-blue-100 hover:bg-blue-200 dark:bg-blue-900/30 text-blue-700 dark:text-blue-400 rounded"
                  >
                    Total
                  </button>
                  <button
                    type="button"
                    onClick={() => handleMontoPreset(50)}
                    className="px-3 py-1 text-xs bg-gray-100 hover:bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-300 rounded"
                  >
                    50%
                  </button>
                  <button
                    type="button"
                    onClick={() => handleMontoPreset(25)}
                    className="px-3 py-1 text-xs bg-gray-100 hover:bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-300 rounded"
                  >
                    25%
                  </button>
                </div>
              )}
            </div>

            {/* Forma de pago */}
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                Forma de Pago
              </label>
              <div className="grid grid-cols-2 gap-2">
                {FORMAS_PAGO.map(fp => (
                  <button
                    key={fp.value}
                    type="button"
                    onClick={() => setFormaPago(fp.value)}
                    className={`px-3 py-2 rounded-lg text-sm font-medium transition-colors ${
                      formaPago === fp.value
                        ? 'bg-blue-600 text-white'
                        : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600'
                    }`}
                  >
                    {fp.label}
                  </button>
                ))}
              </div>
              {formaPago === 'adelanto_sueldo' && (
                <p className="text-xs text-gray-500 dark:text-gray-400 mt-2">
                  Cancela la deuda del cliente pero no es dinero: no entra a rendiciones ni a caja.
                </p>
              )}
            </div>

            {/* Referencia */}
            {(formaPago === 'transferencia' || formaPago === 'cheque') && (
              <div>
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                  {formaPago === 'cheque' ? 'Numero de Cheque *' : 'Referencia/Comprobante'}
                </label>
                <input
                  type="text"
                  value={referencia}
                  onChange={(e: ChangeEvent<HTMLInputElement>) => setReferencia(e.target.value)}
                  placeholder={formaPago === 'cheque' ? 'Ej: 12345678' : 'Ej: TRF-001234'}
                  className={`w-full px-4 py-2 border rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white ${
                    formaPago === 'cheque' && !referencia.trim()
                      ? 'border-yellow-400 dark:border-yellow-600'
                      : 'border-gray-300 dark:border-gray-600'
                  }`}
                  required={formaPago === 'cheque'}
                />
                {formaPago === 'cheque' && !referencia.trim() && (
                  <p className="text-xs text-yellow-600 mt-1">Campo obligatorio para pagos con cheque</p>
                )}
              </div>
            )}
          </>
        )}

        {adelantoSinEmpleado && (
          <div role="alert" className="p-3 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg flex items-start gap-2 text-amber-800 dark:text-amber-200">
            <AlertCircle className="w-4 h-4 mt-0.5 flex-shrink-0" />
            <p className="text-sm">{AVISO_NO_ES_EMPLEADO}</p>
          </div>
        )}
        {adelantoComprobando && (
          <p role="status" className="text-sm text-gray-500 dark:text-gray-400">{AVISO_COMPROBANDO_EMPLEADO}</p>
        )}

        {/* Aplicar a pedido especifico. Se oculta cuando el cobro es de una
            parada concreta (pedidoIdFijo): ahi el pedido no es opcional. */}
        {!pedidoIdFijo && pedidosPendientes.length > 0 && (
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Aplicar a Pedido (opcional)
            </label>
            <select
              value={pedidoSeleccionado}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => handlePedidoChange(e.target.value)}
              className="w-full px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white"
            >
              <option value="">Pago a cuenta general</option>
              {pedidosPendientes.map(p => (
                <option key={p.id} value={p.id}>
                  {/* Lo que le FALTA, no el total: un pedido con pago parcial
                      mostraba el total y el encargado imputaba de más. */}
                  Pedido #{p.id} - falta {formatCurrency(faltantePedido(p))}
                </option>
              ))}
            </select>
          </div>
        )}

        {/* Notas */}
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
            Notas (opcional)
          </label>
          <textarea
            value={notas}
            onChange={(e: ChangeEvent<HTMLTextAreaElement>) => setNotas(e.target.value)}
            placeholder="Observaciones del pago..."
            rows={2}
            className="w-full px-4 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white resize-none"
          />
        </div>
        </div>

        {/* Actions */}
        <div className="flex-shrink-0 flex flex-col gap-3 p-4 sm:p-6 pt-4 border-t border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 rounded-b-2xl pb-[max(1rem,env(safe-area-inset-bottom))]">
          {/* Flujo transportista: entregar dejando el saldo a cuenta corriente,
              sin registrar pago. Solo aparece si el caller provee el handler. */}
          {onEntregarSinCobrar && (
            <button
              type="button"
              onClick={() => { void handleEntregarSinCobrar() }}
              disabled={loading}
              className="w-full px-4 py-3 bg-amber-100 hover:bg-amber-200 dark:bg-amber-900/30 dark:hover:bg-amber-900/50 text-amber-800 dark:text-amber-300 rounded-lg font-medium disabled:opacity-50"
            >
              Entregar a cuenta corriente (sin cobrar)
            </button>
          )}
          <div className="flex gap-3">
            {/* size="touch" (48px), no "lg": iguala al botón ámbar crudo de
                arriba (py-3 = 48px) para no desnivelar el footer. */}
            <Button type="button" variant="secondary" size="touch" onClick={onClose} className="flex-1">
              Cancelar
            </Button>
            <Button
              type="submit"
              variant="success"
              size="touch"
              disabled={loading || adelantoBloqueado || pasaDeLaBoleta || (pagoDividido ? totalDividido <= 0 : !monto)}
              className="flex-1"
            >
              {loading ? (
                <div className="animate-spin rounded-full h-5 w-5 border-b-2 border-white" />
              ) : (
                <>
                  <Check className="w-5 h-5" />
                  Registrar
                </>
              )}
            </Button>
          </div>
        </div>
      </form>
    </DialogoPago>
  )
}
