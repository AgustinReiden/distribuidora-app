import { haversineMeters, type Coord } from './geo'
import { centroideZona, type ClienteUbicado } from './zonaCentroide'

/**
 * Zona ↔ preventista (mig 359): cada zona tiene a lo sumo un preventista
 * dueño, y sus clientes son de él. La regla vive en la base
 * (`asignar_preventista_zona`, `trg_clientes_zona_asigna_duenio`,
 * `trg_clientes_alta_en_zona_propia`); esto es lo que el formulario del
 * cliente propone antes de guardar.
 */

/**
 * La zona que se le propone al preventista que da de alta un cliente.
 *   - sin zonas propias → null (elige como siempre);
 *   - una sola → ésa;
 *   - varias → la de centroide más cercano a la coordenada del cliente. Sin
 *     coordenada, o sin centroide en ninguna (pocos clientes ubicados), null:
 *     que elija él antes que adivinar.
 */
export function zonaSugeridaParaAlta(
  zonasPropias: string[],
  coord: Coord | null,
  clientes: ClienteUbicado[],
): string | null {
  if (zonasPropias.length === 0) return null
  if (zonasPropias.length === 1) return zonasPropias[0]
  if (!coord || !Number.isFinite(coord.lat) || !Number.isFinite(coord.lng)) return null
  if (coord.lat === 0 && coord.lng === 0) return null

  let mejor: string | null = null
  let mejorDist = Infinity
  for (const zonaId of zonasPropias) {
    const c = centroideZona(clientes, zonaId)
    if (!c) continue
    const d = haversineMeters(coord, c.centro)
    if (d < mejorDist) {
      mejorDist = d
      mejor = zonaId
    }
  }
  return mejor
}

/**
 * Los preventistas que quedan tildados cuando el admin le cambia la zona a un
 * cliente: el dueño de la zona nueva, solo, igual que hace la base al guardar.
 * Si la zona no tiene dueño, o el cliente está reservado a administración, no
 * se toca lo que había.
 */
export function preventistasAlCambiarZona(
  zonaId: string,
  duenios: ReadonlyMap<string, string>,
  actuales: string[],
  reservadoAdmin: boolean,
): string[] {
  if (reservadoAdmin || !zonaId) return actuales
  const duenio = duenios.get(String(zonaId))
  return duenio ? [duenio] : actuales
}

/**
 * ¿La asignación que manda la ficha reemplaza lo que hay en la base, o se
 * guarda sólo la diferencia contra lo que la ficha cargó? (#1316)
 *
 * Por defecto, la diferencia: una ficha abierta no deshace el link de zona que
 * hizo otro mientras tanto. Pero cambiar la zona o liberar un reservado
 * disparan el trigger de la zona en el mismo UPDATE, que reasigna antes de que
 * la app escriba la asignación. Ahí lo que eligió el usuario tiene que
 * reemplazar lo del trigger:
 *   - cambió la zona → reemplaza (el formulario ya trae al dueño de la nueva,
 *     o lo que el admin eligió en su lugar, aun vacío);
 *   - liberó un reservado eligiendo preventistas → reemplaza;
 *   - liberó un reservado sin elegir a nadie → diferencia (no escribe nada) y
 *     queda el dueño de la zona, que es la regla de la 359.
 */
export function asignacionContraLaBase(
  cargado: { zona_id?: string | number | null; reservado_admin?: boolean | null },
  zonaIdNueva: string | number | null | undefined,
  reservadoNuevo: boolean,
  preventistaIds: string[],
): boolean {
  if (String(cargado.zona_id ?? '') !== String(zonaIdNueva ?? '')) return true
  return !!cargado.reservado_admin && !reservadoNuevo && preventistaIds.length > 0
}

/** Lo que `asignar_preventista_zona` simula antes de confirmar (mig 359). */
export interface SimulacionLinkZona {
  clientes_zona: number
  cambian: number
  reservados: number
  quitados: Array<{ nombre: string; clientes: number }>
}

/**
 * El texto que confirma un cambio de preventista de una zona, armado con la
 * simulación de la base. Va antes de escribir porque linkear le saca clientes
 * a otros preventistas.
 */
export function textoConfirmacionLinkZona(
  zona: string,
  preventista: string | null,
  sim: SimulacionLinkZona,
): string[] {
  if (preventista === null) {
    const conservan = sim.clientes_zona === 1
      ? 'Su cliente conserva el preventista que tiene hoy.'
      : `Sus ${sim.clientes_zona} clientes conservan el preventista que tienen hoy.`
    return [
      `Quitar el preventista de "${zona}".`,
      `${conservan} Deja de aplicarse a las altas y a los cambios de zona que vengan.`,
    ]
  }

  const lineas: string[] = []
  if (sim.cambian === 0) {
    lineas.push(`Linkear "${zona}" con ${preventista}. Los clientes de la zona ya son todos de ${preventista}.`)
  } else {
    lineas.push(
      `Linkear "${zona}" con ${preventista}: ${sim.cambian} de los ${sim.clientes_zona} clientes de la zona ` +
        `${sim.cambian === 1 ? 'pasa' : 'pasan'} a ser sólo de ${preventista}.`,
    )
  }
  if (sim.quitados.length > 0) {
    lineas.push(
      'Se le sacan a ' + sim.quitados.map(q => `${q.nombre} (${q.clientes})`).join(', ') +
        '. Siguen viendo sus pedidos viejos, pero ya no les cargan pedidos nuevos.',
    )
  }
  if (sim.reservados > 0) {
    lineas.push(sim.reservados === 1
      ? 'El cliente reservado a administración no se toca.'
      : `Los ${sim.reservados} clientes reservados a administración no se tocan.`)
  }
  return lineas
}
