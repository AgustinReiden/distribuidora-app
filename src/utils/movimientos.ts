/**
 * Helpers de movimientos entre sucursales.
 */

/**
 * Stock que la sucursal origen puede poner en un envío para un producto.
 *
 * Al CREAR es simplemente el stock actual. Al EDITAR hay una trampa: desde la
 * mig 139 el envío YA descontó su cantidad del stock, así que `producto.stock`
 * viene deflactado por este mismo envío. El tope real es lo que queda en
 * góndola MÁS lo que este envío ya se llevó — si no, editar un envío de 100 u.
 * sobre un producto que quedó en 0 mostraría tope 0 y no se podría ni bajar la
 * cantidad.
 *
 * @param stockActual        `productos.stock` tal como viene de la base
 * @param cantidadEnEsteEnvio unidades que este envío ya tiene reservadas del
 *                            producto (0 al crear, o para una línea nueva)
 */
export function stockDisponibleParaEnvio(stockActual: number, cantidadEnEsteEnvio = 0): number {
  const stock = Number.isFinite(stockActual) ? stockActual : 0
  const reservado = Number.isFinite(cantidadEnEsteEnvio) ? cantidadEnEsteEnvio : 0
  return Math.max(0, stock + reservado)
}

/** Lo que el modal de aceptar necesita del item del envío. */
export interface ItemCostoOrigen {
  cantidad: number
  origen_costo_con_iva: number | null
  origen_costo_sin_iva: number | null
  /** Snapshot del promedio del origen (mig XXX). NULL en envíos anteriores. */
  origen_costo_promedio?: number | null
}

/** Lo que el modal tiene del producto elegido en el destino. */
export interface ProductoCostoDestino {
  stock: number
  costo_con_iva?: number | null
  costo_sin_iva?: number | null
  costo_promedio?: number | null
}

export interface CostoDestinoPrevisto {
  /** Costo de reposición resultante: el mayor entre destino y origen. */
  reposicionConIva: number
  reposicionSinIva: number
  /** Costo promedio resultante. null = no se puede anticipar (envío viejo sin snapshot). */
  promedio: number | null
  /** true si el promedio sale de mezclar stock previo del destino con lo que llega. */
  ponderado: boolean
}

const numOrNull = (v: number | null | undefined): number | null =>
  v == null || !Number.isFinite(Number(v)) ? null : Number(v)

/**
 * Vista previa del costo que queda en el destino al aceptar un item.
 *
 * Espejo de `aceptar_movimiento_sucursal` (mig XXX) solo para mostrar: lo que
 * se guarda lo calcula la base. Reposición (con/sin IVA) = el mayor; promedio =
 * ponderado (stock previo destino × promedio destino + cantidad × promedio
 * origen) / (stock previo + cantidad), redondeado a 4; si el destino no tiene
 * stock o promedio, queda el del origen; si el origen no tiene promedio, queda
 * el del destino. `destino = null` es "crear nuevo": copia el origen.
 */
export function costoDestinoAlAceptar(
  item: ItemCostoOrigen,
  destino: ProductoCostoDestino | null,
): CostoDestinoPrevisto {
  const oCon = numOrNull(item.origen_costo_con_iva) ?? 0
  const oSin = numOrNull(item.origen_costo_sin_iva) ?? 0
  const po = numOrNull(item.origen_costo_promedio)

  if (!destino) {
    return { reposicionConIva: oCon, reposicionSinIva: oSin, promedio: po, ponderado: false }
  }

  const reposicionConIva = Math.max(numOrNull(destino.costo_con_iva) ?? 0, oCon)
  const reposicionSinIva = Math.max(numOrNull(destino.costo_sin_iva) ?? 0, oSin)
  const pd = numOrNull(destino.costo_promedio)
  const stock = Number.isFinite(destino.stock) ? destino.stock : 0
  const n = Number.isFinite(item.cantidad) ? item.cantidad : 0

  if (po == null) {
    // Envío anterior al snapshot: la base usa el promedio vivo del origen,
    // que el modal no tiene. No se adivina.
    return { reposicionConIva, reposicionSinIva, promedio: null, ponderado: false }
  }
  if (po <= 0) {
    return { reposicionConIva, reposicionSinIva, promedio: pd, ponderado: false }
  }
  if (stock <= 0 || pd == null || pd <= 0 || stock + n <= 0) {
    return { reposicionConIva, reposicionSinIva, promedio: po, ponderado: false }
  }
  const promedio = Math.round(((stock * pd + n * po) / (stock + n)) * 10000) / 10000
  return { reposicionConIva, reposicionSinIva, promedio, ponderado: true }
}
