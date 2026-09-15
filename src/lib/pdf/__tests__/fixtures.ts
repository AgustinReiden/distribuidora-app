import type { PedidoDB } from '../../../types/hooks'

/**
 * Pedidos de ejemplo para los PDFs operativos.
 *
 * El caso que los motiva: una promo Fracción "6 + 2" sobre 196 fardos deja UNA
 * línea de regalo con cantidad 392, y esas 392 son BOTELLAS (65 fardos y 2
 * sueltas), no 392 unidades de venta. El factor con el que se parte tiene que
 * ser el congelado al crear la línea (mig 212): el vivo cambia cuando un admin
 * edita la promo y reescribiría lo que ya se vendió.
 */

export const POMELO = {
  id: 7,
  nombre: 'Manaos Pomelo 3L',
}

export const GRANADINA = {
  id: 9,
  nombre: 'Granadina 1L',
  unidades_de_venta_por_fardo: 6,
  etiqueta_bulto: 'FARDO',
}

/** Línea de venta común: la cantidad ya está en unidades de venta. */
export const itemVenta = (over: Record<string, unknown> = {}) => ({
  producto_id: GRANADINA.id,
  producto: GRANADINA,
  cantidad: 12,
  precio_unitario: 1000,
  es_bonificacion: false,
  ...over,
})

/**
 * Regalo de promo Fracción: 392 botellas, factor congelado 6 y factor VIVO 12
 * (alguien subió la promo después de cerrar el pedido). Con el congelado son
 * 65 fardos + 2; con el vivo, 32 fardos + 8 — la mitad del camión.
 */
export const itemRegaloFraccion = (over: Record<string, unknown> = {}) => ({
  producto_id: POMELO.id,
  producto: POMELO,
  cantidad: 392,
  precio_unitario: 0,
  es_bonificacion: true,
  descripcion_regalo: '2 Botellas Manaos Pomelo 3L',
  unidades_por_bloque_al_crear: 6,
  promocion: { unidades_por_bloque: 12, regalo_mueve_stock: false },
  ...over,
})

/** Regalo de unidad entera del MISMO producto contenedor que el de fracción. */
export const itemRegaloEnteroPomelo = (over: Record<string, unknown> = {}) => ({
  producto_id: POMELO.id,
  producto: POMELO,
  cantidad: 3,
  precio_unitario: 0,
  es_bonificacion: true,
  descripcion_regalo: null,
  unidades_por_bloque_al_crear: null,
  promocion: { unidades_por_bloque: null, regalo_mueve_stock: true },
  ...over,
})

/** Regalo de unidad entera con aclaración de bulto (12 / 6 = 2 fardos). */
export const itemRegaloEnteroGranadina = (over: Record<string, unknown> = {}) => ({
  producto_id: GRANADINA.id,
  producto: GRANADINA,
  cantidad: 12,
  precio_unitario: 0,
  es_bonificacion: true,
  descripcion_regalo: null,
  unidades_por_bloque_al_crear: null,
  promocion: null,
  ...over,
})

/**
 * Regalo de fracción con una descripción de DOS tokens ("2 Granadina"): 3
 * botellas sueltas con factor 4, o sea ni un bloque completo.
 */
export const itemRegaloDosTokens = (over: Record<string, unknown> = {}) => ({
  producto_id: GRANADINA.id,
  producto: GRANADINA,
  cantidad: 3,
  precio_unitario: 0,
  es_bonificacion: true,
  descripcion_regalo: '2 Granadina',
  unidades_por_bloque_al_crear: 4,
  promocion: { unidades_por_bloque: 4, regalo_mueve_stock: false },
  ...over,
})

export const pedido = (items: unknown[], over: Record<string, unknown> = {}) => ({
  id: 13,
  total: 100000,
  canal: 'venta',
  cliente: { nombre_fantasia: 'Kiosco El Sol', direccion: 'Salta 100' },
  items,
  ...over,
} as unknown as PedidoDB)
