/**
 * 1600-b8 (decisión D58 del dueño, #1600): los pedidos sin sincronizar que el
 * usuario guardó en OTRA sucursal se avisan, con cuántos son, y se ofrece cambiar
 * a esa sucursal. No se mandan cruzados: el replay manda cada pedido con la
 * sucursal en la que se encoló, y sólo los de la sucursal activa
 * (`getPendingOperations`).
 */
import type { PendientesDeOtraSucursal } from '../lib/offlineDb'

export interface AvisoColaOtraSucursal {
  sucursalId: number
  cantidad: number
  /** El nombre de la sucursal, si el usuario todavía la tiene asignada. */
  nombre: string | null
  texto: string
}

function pedidos(n: number): string {
  return n === 1 ? '1 pedido sin sincronizar guardado' : `${n} pedidos sin sincronizar guardados`
}

/**
 * Un aviso por sucursal. Si el usuario ya no tiene esa sucursal no se le puede
 * ofrecer el cambio (`nombre` null): que lo resuelva el administrador.
 */
export function avisosColaOtraSucursal(
  pendientes: readonly PendientesDeOtraSucursal[],
  sucursales: ReadonlyArray<{ id: number; nombre: string }>,
): AvisoColaOtraSucursal[] {
  return pendientes
    .filter(p => p.cantidad > 0)
    .map(p => {
      const nombre = sucursales.find(s => s.id === p.sucursalId)?.nombre ?? null
      const texto = nombre
        ? `Tenés ${pedidos(p.cantidad)} en ${nombre}. Se ${p.cantidad === 1 ? 'manda' : 'mandan'} sólo desde esa ` +
          `sucursal: cambiá a ${nombre} para ${p.cantidad === 1 ? 'mandarlo' : 'mandarlos'}.`
        : `Tenés ${pedidos(p.cantidad)} en una sucursal a la que ya no tenés acceso. Avisale al administrador.`
      return { sucursalId: p.sucursalId, cantidad: p.cantidad, nombre, texto }
    })
}
