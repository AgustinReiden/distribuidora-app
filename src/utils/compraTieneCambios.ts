/**
 * ¿Cerrar ahora el modal de compra tira trabajo a la basura?
 *
 * Decide si Escape cierra o no (WP-26a le dio a `ModalBase` el
 * `onEscapeKeyDown` para eso). La X y "Cancelar" cierran siempre: son un click
 * deliberado. Escape se aprieta sin querer, y el modal hecho a mano no cerraba
 * con él: habilitarlo sin condición le haría perder a quien carga la factura
 * todo lo que ya tipeó.
 *
 * Se compara campo por campo contra `initialState`, que es exactamente con lo
 * que arranca el `useReducer` del modal. La tabla de abajo tiene UNA entrada
 * por cada campo de `CompraState` —el tipo la obliga a estar completa—, así que
 * un campo nuevo en el reducer no compila hasta que alguien decide si cuenta.
 *
 * Cuenta todo lo que viaja en la compra o que costó trabajo conseguir:
 * proveedor (elegido o nuevo a medio cargar), comprobante, número y fecha de
 * factura, forma de pago, notas, líneas, cargos, percepciones, no gravado,
 * impuesto interno declarado, control contra el papel y todo lo del escaneo
 * (uno en vuelo, uno por aplicar, ítems esperando revisión). El alta rápida de
 * producto abierta también: lo que se tipea ahí vive en el estado local del
 * buscador, no en el reducer, y desde acá no hay cómo saber si está vacío.
 *
 * No cuentan los estados de la pantalla: el término del buscador y si su
 * lista está abierta (de esa se ocupa el modal aparte: Escape la cierra a
 * ella), el guardado en vuelo (sin líneas no se puede guardar, y las líneas ya
 * cuentan) y los mensajes de error.
 */
import { initialState } from '../components/modals/ModalCompra.reducer'
import type { CompraState } from '../components/modals/ModalCompra.reducer'

/** `null`: el campo no cuenta como cambio. */
type Criterio = ((state: CompraState) => boolean) | null

/** Texto libre: sólo espacios no es un dato. */
const hayTexto = (valor: string): boolean => valor.trim() !== ''

const CRITERIOS: Record<keyof CompraState, Criterio> = {
  // Proveedor. `usarProveedorNuevo` lo prende el escaneo cuando la factura
  // trae un proveedor que no está dado de alta.
  proveedorId: s => s.proveedorId !== initialState.proveedorId,
  proveedorNombre: s => hayTexto(s.proveedorNombre),
  usarProveedorNuevo: s => s.usarProveedorNuevo !== initialState.usarProveedorNuevo,

  // Cabecera del comprobante.
  tipoFactura: s => s.tipoFactura !== initialState.tipoFactura,
  numeroFactura: s => hayTexto(s.numeroFactura),
  fechaCompra: s => s.fechaCompra !== initialState.fechaCompra,
  formaPago: s => s.formaPago !== initialState.formaPago,
  notas: s => hayTexto(s.notas),

  // Detalle, cargos y desglose fiscal.
  items: s => s.items.length > 0,
  cargos: s => s.cargos.length > 0,
  percepcionIva: s => s.percepcionIva !== initialState.percepcionIva,
  percepcionIibb: s => s.percepcionIibb !== initialState.percepcionIibb,
  noGravado: s => s.noGravado !== initialState.noGravado,
  // Un 0 tipeado sobre el pre-llenado es "la factura no trae no gravado": un
  // dato, aunque el importe coincida con el default.
  noGravadoManual: s => s.noGravadoManual !== initialState.noGravadoManual,
  iiDeclarado: s => Object.keys(s.iiDeclarado).length > 0,
  controlFactura: s =>
    (Object.keys(initialState.controlFactura) as (keyof CompraState['controlFactura'])[])
      .some(campo => s.controlFactura[campo] !== initialState.controlFactura[campo]),

  // Escaneo de factura: subir la foto y esperar el OCR es trabajo.
  escaneando: s => s.escaneando,
  resultadoEscaneo: s => s.resultadoEscaneo !== null,
  itemsPendientesScan: s => s.itemsPendientesScan.length > 0,

  // Alta rápida de producto abierta (ver arriba).
  modoItemRapido: s => s.modoItemRapido,

  // Estados de la pantalla: no son datos de la compra.
  busquedaProducto: null,
  mostrarBuscador: null,
  guardando: null,
  error: null,
  errorEscaneo: null,
}

export function compraTieneCambios(state: CompraState): boolean {
  return Object.values(CRITERIOS).some(criterio => criterio !== null && criterio(state))
}
