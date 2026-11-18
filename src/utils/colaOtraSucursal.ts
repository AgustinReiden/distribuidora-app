/**
 * 1600-b8 (decisión D58 del dueño, #1600): los pedidos sin sincronizar que el
 * usuario guardó en OTRA sucursal se avisan, con cuántos son, y se ofrece cambiar
 * a esa sucursal. No se mandan cruzados: el replay manda cada pedido con la
 * sucursal en la que se encoló, y sólo los de la sucursal activa
 * (`getPendingOperations`).
 *
 * H5 de la revisión de B12a (decisiones de pantalla a confirmar por el dueño):
 * - los pendientes («cambiá a X para mandarlos») van aparte de los fallidos («hay
 *   que revisarlos: reintentar o eliminar, desde esa sucursal»);
 * - a una sucursal que el usuario ya no tiene, o que está inactiva, no se le
 *   ofrece el cambio: que avise al administrador.
 */
import type { PendientesDeOtraSucursal } from '../lib/offlineDb'

export interface AvisoColaOtraSucursal {
  sucursalId: number
  /** El nombre de la sucursal, si el usuario la tiene asignada. */
  nombre: string | null
  /** Se le puede ofrecer «Cambiar a X»: la tiene asignada y está activa. */
  puedeCambiar: boolean
  /** Una línea por cosa que decir (pendientes, fallidos o «avisale al administrador»). */
  lineas: string[]
}

/** «1 pedido sin mandar guardado» / «3 pedidos sin mandar guardados». */
function pedidos(n: number, frase: string): string {
  return n === 1 ? `1 pedido ${frase}` : `${n} pedidos ${frase}s`
}

/**
 * Un aviso por sucursal. `activas` son los ids de las sucursales activas, o null
 * si no se pudieron leer (sin señal): entonces vale lo que dice la lista del
 * usuario, y si el cambio se rechaza, `rechazadas` lo deja sin botón.
 */
export function avisosColaOtraSucursal(
  pendientes: readonly PendientesDeOtraSucursal[],
  sucursales: ReadonlyArray<{ id: number; nombre: string }>,
  activas: ReadonlySet<number> | null = null,
  rechazadas: ReadonlySet<number> = new Set(),
): AvisoColaOtraSucursal[] {
  return pendientes
    .filter(p => p.pendientes + p.fallidos > 0)
    .map(p => {
      const nombre = sucursales.find(s => s.id === p.sucursalId)?.nombre ?? null
      const puedeCambiar = nombre !== null && (activas === null || activas.has(p.sucursalId)) && !rechazadas.has(p.sucursalId)
      if (!puedeCambiar) {
        const total = p.pendientes + p.fallidos
        const donde = nombre ? `en ${nombre}, una sucursal en la que hoy no podés trabajar` : 'en una sucursal a la que ya no tenés acceso'
        return {
          sucursalId: p.sucursalId,
          nombre,
          puedeCambiar,
          lineas: [`Tenés ${pedidos(total, 'sin sincronizar guardado')} ${donde}. Avisale al administrador.`],
        }
      }
      const lineas: string[] = []
      if (p.pendientes > 0) {
        lineas.push(
          `Tenés ${pedidos(p.pendientes, 'sin mandar guardado')} en ${nombre}. ` +
          `Se ${p.pendientes === 1 ? 'manda' : 'mandan'} sólo desde esa sucursal: ` +
          `cambiá a ${nombre} para ${p.pendientes === 1 ? 'mandarlo' : 'mandarlos'}.`,
        )
      }
      if (p.fallidos > 0) {
        lineas.push(
          `${p.fallidos === 1 ? '1 pedido' : `${p.fallidos} pedidos`} de ${nombre} ` +
          `${p.fallidos === 1 ? 'tiene' : 'tienen'} error: hay que ${p.fallidos === 1 ? 'revisarlo' : 'revisarlos'} ` +
          '(reintentar o eliminar) desde esa sucursal.',
        )
      }
      return { sucursalId: p.sucursalId, nombre, puedeCambiar, lineas }
    })
}

/** La firma de la cuenta: si cambia, un aviso cerrado vuelve a aparecer. */
export function firmaColaOtraSucursal(pendientes: readonly PendientesDeOtraSucursal[]): string {
  return pendientes.map(p => `${p.sucursalId}:${p.pendientes}:${p.fallidos}`).join('|')
}

/** Lo que se dice después de «Cambiar a X»: la app se queda ahí (no vuelve sola). */
export function mensajeQuedasteEnSucursal(nombre: string): string {
  return `Ahora estás trabajando en ${nombre}: los pedidos guardados se mandan desde acá. ` +
    'La app se queda en esta sucursal; para volver a la tuya, elegila arriba.'
}

/** N1: el cambio no salió porque no hubo señal; el botón sigue para reintentar. */
export const MENSAJE_CAMBIO_SIN_SENAL =
  'No se pudo cambiar de sucursal: no hubo señal. Probá de nuevo cuando tengas señal.'
