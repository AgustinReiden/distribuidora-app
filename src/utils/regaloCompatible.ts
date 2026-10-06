/**
 * Regla única de qué productos se pueden elegir como regalo de una promo en
 * lugar del regalo original (#950, solución provisoria).
 *
 * Por qué: el contenedor de la promo descuenta con el factor del empaque del
 * regalo original (fardo x6 de Manaos 3L). Cambiarlo por otra presentación
 * (500cc x12, papas) descuenta mal el stock. Hasta resolverlo de fondo, un
 * regalo sólo se cambia por productos de la MISMA categoría (rubro) y, si el
 * original tiene subcategoría (subrubro), de la MISMA subcategoría.
 *
 * - Categoría: se compara `categoria_id` si los dos lo tienen; si no, el texto
 *   `categoria` normalizado (#763: hay productos con texto y sin id).
 * - Original SIN categoría: no hay con qué comparar, así que sólo es compatible
 *   consigo mismo (lo conservador: no se adivina un empaque equivalente).
 * - El original siempre es compatible consigo mismo.
 */
import { filtrarProductosOperativos } from './productosOperativos'

export interface ProductoRegalo {
  id: string | number
  activo?: boolean | null
  categoria?: string | null
  categoria_id?: string | number | null
  subcategoria_id?: string | number | null
}

export const TEXTO_REGALO_MISMA_CATEGORIA =
  'Sólo productos de la misma categoría (y subcategoría) que el regalo original.'

const normalizar = (s: string | null | undefined): string =>
  (s ?? '').normalize('NFD').replace(/[\u0300-\u036f]/g, '').trim().toLowerCase()

const idPresente = (v: string | number | null | undefined): string | null =>
  v === null || v === undefined || String(v).trim() === '' ? null : String(v)

export function esRegaloCompatible(original: ProductoRegalo, candidato: ProductoRegalo): boolean {
  if (String(original.id) === String(candidato.id)) return true

  const catIdOrig = idPresente(original.categoria_id)
  const catIdCand = idPresente(candidato.categoria_id)
  let mismaCategoria: boolean
  if (catIdOrig && catIdCand) {
    mismaCategoria = catIdOrig === catIdCand
  } else {
    const textoOrig = normalizar(original.categoria)
    mismaCategoria = textoOrig !== '' && textoOrig === normalizar(candidato.categoria)
  }
  if (!mismaCategoria) return false

  const subOrig = idPresente(original.subcategoria_id)
  if (subOrig && subOrig !== idPresente(candidato.subcategoria_id)) return false
  return true
}

/** Operativos (no desactivados) y compatibles con el original. */
export function filtrarRegalosCompatibles<T extends ProductoRegalo>(
  original: ProductoRegalo,
  productos: readonly T[],
): T[] {
  return filtrarProductosOperativos(productos).filter(p => esRegaloCompatible(original, p))
}
