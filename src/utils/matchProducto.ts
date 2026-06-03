/**
 * Matching de productos entre sucursales (al aceptar un movimiento).
 *
 * Mismo criterio estricto que el escaneo de facturas (ModalCompra): match solo
 * por código exacto o nombre exacto (normalizado). Cualquier coincidencia
 * parcial queda fuera para que el usuario decida.
 */
import type { ProductoDB } from '../types'

export function normalizarTexto(s: string | null | undefined): string {
  return (s ?? '').trim().toLowerCase().replace(/\s+/g, ' ')
}

export function sugerirMatchProducto(
  ref: { codigo?: string | null; nombre?: string | null },
  productos: ProductoDB[],
): ProductoDB | null {
  const cod = normalizarTexto(ref.codigo)
  if (cod) {
    const porCodigo = productos.find(p => normalizarTexto(p.codigo) === cod)
    if (porCodigo) return porCodigo
  }
  const nom = normalizarTexto(ref.nombre)
  if (nom) {
    const porNombre = productos.find(p => normalizarTexto(p.nombre) === nom)
    if (porNombre) return porNombre
  }
  return null
}
