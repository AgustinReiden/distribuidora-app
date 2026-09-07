/**
 * Valorización del historial de mermas: cuánto costó y cuánto se dejó de vender.
 *
 * EL COSTO ES EL CONGELADO, NO EL DE HOY
 * --------------------------------------
 * `mermas_stock.costo_unitario` (mig 119) lo sella un trigger BEFORE INSERT con
 * el costo promedio ponderado del momento, así que cubre todos los caminos de
 * inserción. Es el mismo criterio del reporte gerencial. Con el costo vivo, el
 * total de un mes ya cerrado cambiaría solo cada vez que llega una compra.
 *
 * Las mermas anteriores a que existiera el snapshot —479 filas, de abril a
 * julio de 2026— caen a la cascada canónica, o sea al costo de HOY. Se marcan
 * con `costoEstimado`: mezclarlas en silencio con las que sí tienen el costo
 * del momento sería presentar una estimación como un dato.
 *
 * EL PRECIO DE VENTA NO TIENE HISTÓRICO
 * -------------------------------------
 * `mermas_stock` no tiene ninguna columna de precio: sólo se puede valuar
 * contra `productos.precio` de hoy. Es una referencia de "cuánto se dejó de
 * facturar a precio actual", no el precio que regía el día de la merma, y la
 * pantalla y el Excel lo dicen.
 *
 * LOS AJUSTES DE PROMOCIÓN NO SON PÉRDIDA
 * ---------------------------------------
 * `reporte_gerencial` excluye 'promociones' y 'promociones_reversion' del KPI
 * de mermas (mig 130), porque son la contrapartida de un regalo que YA está
 * contabilizado en el pedido: contarlos sería contar la misma plata dos veces.
 * En los datos de prod pesan $2.637.977 y -$755.516 contra ~$597.600 de merma
 * real, así que un total que los incluya no cuadra con el gerencial por un
 * factor de cuatro. Se muestran igual, en el detalle y en el resumen por
 * motivo, pero etiquetados y fuera del total en plata.
 */
import { costoCanonicoUnitario, type ProductoCosto } from './costoCanonico'

/** Motivos que NO son pérdida. Es exactamente lo que excluye la mig 130. */
export const MOTIVOS_AJUSTE_PROMOCION = ['promociones', 'promociones_reversion'] as const

export function esAjustePromocion(motivo: string): boolean {
  return (MOTIVOS_AJUSTE_PROMOCION as readonly string[]).includes(motivo)
}

/** Lo que se necesita de una fila de `mermas_stock`. */
export interface MermaParaValorizar {
  id: string
  producto_id: string
  /** Negativa en las reversiones: el CHECK es `cantidad <> 0` (mig 011). */
  cantidad: number
  motivo: string
  /** Costo congelado por el trigger (mig 119). NULL en las filas viejas. */
  costo_unitario?: number | null
  observaciones?: string | null
  usuario_id?: string | null
  stock_anterior?: number
  stock_nuevo?: number
  created_at?: string
}

/** Lo que se necesita de `productos`: las columnas de costo, más el precio. */
export interface ProductoParaValorizar extends ProductoCosto {
  id: string
  nombre?: string | null
  codigo?: string | null
  precio?: number | null
}

export interface MermaValorizada extends MermaParaValorizar {
  productoNombre: string
  productoCodigo: string
  costoUnitario: number
  costoTotal: number
  precioUnitario: number
  precioTotal: number
  /** No es pérdida: contrapartida de un regalo ya contabilizado en el pedido. */
  esAjustePromocion: boolean
  /** No había snapshot: el costo sale del valor de hoy. */
  costoEstimado: boolean
  /** No hay NINGÚN costo cargado: el 0 significa "no sabemos", no "no vale nada". */
  sinCosto: boolean
  /** El producto no tiene precio cargado. */
  sinPrecio: boolean
}

/**
 * Espejo del `presente()` de costoCanonico.ts, que no se exporta a propósito.
 * Sirve para distinguir un costo de 0 cargado a mano —que es una decisión— de
 * la ausencia total de costo, que es lo que hay que marcar. El último test de
 * `sinCosto` fija que las dos funciones sigan de acuerdo.
 */
function hayValor(v: unknown): boolean {
  if (v === null || v === undefined || v === '') return false
  return Number.isFinite(Number(v))
}

export function valorizarMerma(
  merma: MermaParaValorizar,
  producto: ProductoParaValorizar | null | undefined,
): MermaValorizada {
  const costoUnitario = costoCanonicoUnitario(merma.costo_unitario, producto)
  const conSnapshot = hayValor(merma.costo_unitario)
  const sinCosto =
    !conSnapshot &&
    !hayValor(producto?.costo_promedio) &&
    !hayValor(producto?.costo_real) &&
    !hayValor(producto?.costo_sin_iva)

  const sinPrecio = !hayValor(producto?.precio)
  const precioUnitario = sinPrecio ? 0 : Number(producto?.precio)

  return {
    ...merma,
    productoNombre: producto?.nombre || 'Producto desconocido',
    productoCodigo: producto?.codigo || '',
    costoUnitario,
    costoTotal: costoUnitario * merma.cantidad,
    precioUnitario,
    precioTotal: precioUnitario * merma.cantidad,
    esAjustePromocion: esAjustePromocion(merma.motivo),
    // Una fila sin ningún costo no es una estimación: es un dato ausente, y se
    // marca con `sinCosto`. Marcarla además como estimada diría que hay un
    // número aproximado cuando no hay ninguno.
    costoEstimado: !conSnapshot && !sinCosto,
    sinCosto,
    sinPrecio,
  }
}

export interface TotalesMermas {
  /** Todos los registros del período, sean pérdida o ajuste. */
  registros: number
  /** Unidades perdidas: NO incluye los ajustes de promoción. */
  unidades: number
  /** Costo de la pérdida real. Es el número que cuadra con el gerencial. */
  costoTotal: number
  /** Lo mismo valuado a precio de venta de HOY. */
  precioTotal: number
  registrosAjustePromocion: number
  unidadesAjustePromocion: number
  costoAjustePromocion: number
  /** Cuántas filas se valuaron con el costo de hoy por no tener snapshot. */
  filasCostoEstimado: number
  /** Cuántas filas no tienen ningún costo con el cual valuarse. */
  filasSinCosto: number
}

export function totalizarMermas(filas: readonly MermaValorizada[]): TotalesMermas {
  const t: TotalesMermas = {
    registros: filas.length,
    unidades: 0,
    costoTotal: 0,
    precioTotal: 0,
    registrosAjustePromocion: 0,
    unidadesAjustePromocion: 0,
    costoAjustePromocion: 0,
    filasCostoEstimado: 0,
    filasSinCosto: 0,
  }

  for (const f of filas) {
    if (f.costoEstimado) t.filasCostoEstimado++
    if (f.sinCosto) t.filasSinCosto++

    if (f.esAjustePromocion) {
      t.registrosAjustePromocion++
      t.unidadesAjustePromocion += f.cantidad
      t.costoAjustePromocion += f.costoTotal
    } else {
      t.unidades += f.cantidad
      t.costoTotal += f.costoTotal
      t.precioTotal += f.precioTotal
    }
  }

  return t
}

export interface ResumenMotivo {
  motivo: string
  esAjustePromocion: boolean
  registros: number
  unidades: number
  costo: number
  precio: number
}

/** El mismo corte que arma el gerencial en su bloque `mermas_motivo`. */
export function resumenPorMotivo(filas: readonly MermaValorizada[]): ResumenMotivo[] {
  const porMotivo = new Map<string, ResumenMotivo>()

  for (const f of filas) {
    const acc = porMotivo.get(f.motivo) ?? {
      motivo: f.motivo,
      esAjustePromocion: f.esAjustePromocion,
      registros: 0,
      unidades: 0,
      costo: 0,
      precio: 0,
    }
    acc.registros++
    acc.unidades += f.cantidad
    acc.costo += f.costoTotal
    acc.precio += f.precioTotal
    porMotivo.set(f.motivo, acc)
  }

  return [...porMotivo.values()].sort((a, b) => b.costo - a.costo)
}
