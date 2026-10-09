/**
 * Vale blanco (VB): el tercer comprobante de venta (`pedidos.tipo_factura`).
 *
 * Un VB es consumo interno hacia una empresa propia: va a costo (lo precia el
 * SERVIDOR al guardar, el front no ve costos — #974 / mig 310), sin IVA, sin
 * forma de pago, sin promos, regalos ni mínimos, nace entregado y saldado por
 * naturaleza (`estado_pago = 'pagado'`, `monto_pagado = total`, 0 pagos). No es
 * deuda, no es venta y no comisiona.
 *
 * Sólo un cliente con `tipo_factura_default = 'VB'` puede recibirlo (lo habilita
 * un admin). Toda la lógica de decisión del front sobre VB vive acá, pura y con
 * tests; los componentes sólo la pintan. El servidor revalida todo.
 */
import type { TipoComprobanteVenta } from '../types';

export const TIPO_VB = 'VB' as const;

/** Leyenda del alta mientras se carga un VB (no hay preview de montos). */
export const LEYENDA_VB_ALTA = 'Vale blanco a costo — el total se calcula al guardar';

/** Etiqueta del "estado de pago" de un VB: no es pagado ni pendiente. */
export const ETIQUETA_CONSUMO_INTERNO = 'Consumo interno';

/** Badge del comprobante en la tarjeta. */
export const ETIQUETA_BADGE_VB = 'VB · consumo interno';

export const MENSAJE_CLIENTE_NO_HABILITADO_VB =
  'Este cliente no está habilitado para vale blanco (lo habilita un admin desde la ficha del cliente).';

/** ¿Es un vale blanco? Tolera null/undefined y valores desconocidos. */
export function esTipoVB(tipo: string | null | undefined): boolean {
  return tipo === TIPO_VB;
}

/** ¿El cliente puede recibir vales blancos? */
export function clienteHabilitadoVB(
  cliente: { tipo_factura_default?: string | null } | null | undefined,
): boolean {
  return cliente?.tipo_factura_default === TIPO_VB;
}

export interface OpcionTipoFactura {
  value: string;
  label: string;
}

const OPCIONES_BASE: readonly OpcionTipoFactura[] = [
  { value: 'ZZ', label: 'ZZ' },
  { value: 'FC', label: 'FC' },
];

/**
 * Opciones del `<select>` "Factura" del alta. VB sólo si el cliente está
 * habilitado. El select TOLERA un valor que no está en la lista (un VB de un
 * cliente al que le sacaron la habilitación, un valor nuevo de un bundle más
 * nuevo): se agrega como opción para que el select muestre lo que el estado
 * dice, en vez de mostrar "ZZ" con el estado en otra cosa.
 */
export function opcionesTipoFactura(
  valorActual: string | null | undefined,
  clienteHabilitado: boolean,
): OpcionTipoFactura[] {
  const opciones: OpcionTipoFactura[] = [...OPCIONES_BASE];
  if (clienteHabilitado) opciones.push({ value: TIPO_VB, label: 'VB' });
  if (valorActual && !opciones.some(o => o.value === valorActual)) {
    opciones.push({ value: valorActual, label: valorActual });
  }
  return opciones;
}

/**
 * Tipo de comprobante con el que nace el pedido al elegir el cliente: su
 * default (mig 116). Un cliente VB arranca en VB; cualquier otro valor
 * desconocido cae a ZZ.
 */
export function tipoFacturaInicial(
  cliente: { tipo_factura_default?: string | null } | null | undefined,
): TipoComprobanteVenta {
  const d = cliente?.tipo_factura_default;
  return d === 'FC' || d === 'VB' ? d : 'ZZ';
}

// =============================================================================
// CONVERSIÓN DE COMPROBANTE (cambiar_tipo_factura_pedido, N10)
// =============================================================================

/** Lo mínimo del pedido que mira el menú de conversión. */
export interface PedidoParaConversion {
  estado?: string | null;
  tipo_factura?: string | null;
  monto_pagado?: number | string | null;
  pagos?: ReadonlyArray<{ monto?: number | null }> | null;
  salvedades?: ReadonlyArray<{ estado_resolucion?: string | null }> | null;
  items?: ReadonlyArray<{ es_bonificacion?: boolean | null; promocion_id?: string | number | null }> | null;
  cliente?: { tipo_factura_default?: string | null } | null;
}

export interface RolConversion {
  isAdmin?: boolean;
  isEncargado?: boolean;
}

export interface DestinoTipoFactura {
  tipo: TipoComprobanteVenta;
  /**
   * Motivo por el que el destino se muestra pero no se puede elegir. Son los
   * bloqueos que el front ve con los datos de la tarjeta; el servidor revalida
   * todos (y además los que el front no ve: nota de crédito vigente, caja
   * cerrada, recorrido en curso).
   */
  bloqueo?: string;
}

/** Estados "en ruta": convertir a VB exige sacarlo de la ruta primero. */
const ESTADOS_EN_RUTA = new Set(['asignado', 'en_preparacion']);

export const BLOQUEO_VB_EN_RUTA = 'Está en ruta o en preparación: sacalo de la ruta primero';
export const BLOQUEO_VB_CON_PAGOS = 'Tiene pagos registrados: un vale blanco no admite pagos';
export const BLOQUEO_VB_CON_SALVEDADES = 'Tiene salvedades: un vale blanco se recarga sin ellas';
export const BLOQUEO_VB_CON_PROMOS = 'Tiene promociones o regalos: un vale blanco no los lleva';

/** Salvedades que cuentan (una anulada ya no existe para el negocio). */
function tieneSalvedadesVigentes(pedido: PedidoParaConversion): boolean {
  return (pedido.salvedades ?? []).some(s => {
    const e = String(s.estado_resolucion ?? '').toLowerCase();
    return e !== 'anulada' && e !== 'anulado';
  });
}

function tienePagos(pedido: PedidoParaConversion): boolean {
  if (Number(pedido.monto_pagado ?? 0) > 0) return true;
  return (pedido.pagos ?? []).some(p => Number(p.monto ?? 0) !== 0);
}

function tienePromos(pedido: PedidoParaConversion): boolean {
  return (pedido.items ?? []).some(i => !!i.es_bonificacion || (i.promocion_id != null && i.promocion_id !== ''));
}

/**
 * A qué comprobantes se puede pasar este pedido, para este rol (N10). Vacío =
 * el badge es de sólo lectura.
 *
 *  - Cancelado/anulado: nada.
 *  - ZZ ↔ FC: admin siempre; encargado antes de la entrega (como era el flip).
 *  - ZZ/FC → VB: sólo si el cliente está habilitado. No entregado → admin o
 *    encargado; entregado → sólo admin. Con pagos, salvedades, promos/regalos o
 *    en ruta se ofrece deshabilitado y con el motivo.
 *  - VB → ZZ/FC: sólo admin (re-precia a lista y queda pendiente de cobro).
 */
export function destinosTipoFactura(
  pedido: PedidoParaConversion,
  { isAdmin, isEncargado }: RolConversion,
): DestinoTipoFactura[] {
  const estado = pedido.estado ?? '';
  if (estado === 'cancelado' || estado === 'anulado') return [];
  const entregado = estado === 'entregado';
  const actual = (pedido.tipo_factura ?? 'ZZ') as string;

  if (actual === TIPO_VB) {
    return isAdmin ? [{ tipo: 'ZZ' }, { tipo: 'FC' }] : [];
  }

  const destinos: DestinoTipoFactura[] = [];
  const puedeFlip = !!isAdmin || (!!isEncargado && !entregado);
  if (puedeFlip) destinos.push({ tipo: actual === 'FC' ? 'ZZ' : 'FC' });

  const puedeVB = clienteHabilitadoVB(pedido.cliente)
    && (entregado ? !!isAdmin : (!!isAdmin || !!isEncargado));
  if (puedeVB) {
    const bloqueo = ESTADOS_EN_RUTA.has(estado) ? BLOQUEO_VB_EN_RUTA
      : tienePagos(pedido) ? BLOQUEO_VB_CON_PAGOS
      : tieneSalvedadesVigentes(pedido) ? BLOQUEO_VB_CON_SALVEDADES
      : tienePromos(pedido) ? BLOQUEO_VB_CON_PROMOS
      : undefined;
    destinos.push(bloqueo ? { tipo: TIPO_VB, bloqueo } : { tipo: TIPO_VB });
  }
  return destinos;
}

/** Mensaje de éxito de una conversión que involucra un VB (null = sin aviso). */
export function mensajeConversionTipoFactura(
  desde: string | null | undefined,
  hacia: TipoComprobanteVenta,
): string | null {
  if (hacia === TIPO_VB) {
    return 'Pasado a vale blanco: quedó entregado y saldado a costo (consumo interno).';
  }
  if (desde === TIPO_VB) {
    return `Pasado a ${hacia}: quedó entregado a precio de lista y pendiente de cobro. ` +
      'No tiene transportista, así que no entra a ninguna rendición: cobralo desde "Registrar Pago".';
  }
  return null;
}

// =============================================================================
// ALTA
// =============================================================================

/** Línea de un VB tal como la manda el front: sin precio (lo pone el servidor). */
export interface ItemVBParaCrear {
  productoId: string;
  cantidad: number;
  precioUnitario: 0;
}

/**
 * Las líneas de un vale blanco para la RPC de alta: SÓLO lo que el usuario
 * cargó (producto y cantidad), sin promos ni regalos ni bonificaciones, y con
 * precio 0. `crear_pedido_completo` precia cada línea a `costo_valuacion(...)`
 * e ignora precio, total, neto, IVA, forma y estado de pago del caller: el
 * front no ve costos y no hay preview. Cantidades no positivas se descartan.
 */
export function itemsVBParaCrear(
  items: ReadonlyArray<{ productoId: string | number; cantidad: number }>,
): ItemVBParaCrear[] {
  return items
    .filter(i => Number(i.cantidad) > 0)
    .map(i => ({ productoId: String(i.productoId), cantidad: Number(i.cantidad), precioUnitario: 0 as const }));
}

/** Aviso de éxito del alta de un VB, con el total que calculó el servidor. */
export function mensajeAltaVB(total: number | null | undefined, formatear: (n: number) => string): string {
  return total != null && Number.isFinite(total)
    ? `Vale blanco creado: ${formatear(total)} a costo (consumo interno).`
    : 'Vale blanco creado (consumo interno). El total a costo lo calculó el servidor: miralo en la tarjeta.';
}

/** Un VB no se edita ni cambia de cliente: se cancela y se recarga (N9). */
export const MENSAJE_VB_NO_SE_EDITA = 'Un vale blanco no se edita ni cambia de cliente: cancelalo y cargalo de nuevo.';
