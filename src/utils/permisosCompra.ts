/**
 * Permisos de edicion de compras por admin.
 *
 * Regla: solo admin puede editar items de una compra, y solo dentro de los
 * 7 dias desde su creacion (compras.created_at). Una compra cancelada no es
 * editable, ni una con notas de credito (mig 482, STK-3 de #1516: lo acreditado
 * ya bajo el stock y los lotes, y la edicion lo volvia a restar; es la misma
 * regla que anular y cambiar el proveedor, #1095). Esta verificacion es el
 * "gate" del frontend (oculta el boton); el RPC SQL actualizar_compra_items
 * vuelve a validar el rol, la ventana y las notas.
 */

export const DIAS_EDICION_COMPRA = 7

interface CompraLike {
  estado?: string | null
  created_at?: string | null | undefined
}

export function adminPuedeEditarCompra(
  compra: CompraLike,
  isAdmin: boolean,
  now: Date = new Date(),
  /** Si la compra tiene notas de credito (el resumen de NC de la lista). */
  tieneNotasCredito = false,
): boolean {
  if (!isAdmin) return false
  if (compra.estado === 'cancelada') return false
  if (tieneNotasCredito) return false
  if (!compra.created_at) return false

  const created = new Date(compra.created_at)
  if (Number.isNaN(created.getTime())) return false

  const diasDesdeCreacion = (now.getTime() - created.getTime()) / (1000 * 60 * 60 * 24)
  return diasDesdeCreacion <= DIAS_EDICION_COMPRA
}
