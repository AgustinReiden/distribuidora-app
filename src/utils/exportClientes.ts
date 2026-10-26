/**
 * Armado de filas para la exportación a Excel del panel de Clientes.
 *
 * Lógica pura: el panel pasa la lista YA filtrada (búsqueda, rubro, zona, saldo
 * e "inactivos") y esto sólo la traduce a columnas. Los tres estados de
 * asignación (mig 214) son excluyentes: reservado_admin, asignado a X, o sin
 * asignar (= visible para todos los preventistas).
 */
import type { ClienteDB } from '../types'

export interface ZonaRef { id: string | number; nombre: string }
export interface PerfilRef { id: string; nombre: string }

export interface OpcionesExportClientes {
  zonas: ZonaRef[]
  perfiles: PerfilRef[]
  sucursalNombre: string | null
  /** El saldo es plata: sólo admin/encargado (ver `puedeVerSaldoExportClientes`). */
  incluirSaldo: boolean
}

export const RESERVADO_ADMIN = 'Reservado admin'
export const SIN_ASIGNAR = 'Sin asignar'

export function textoAsignacion(c: ClienteDB, perfiles: PerfilRef[]): string {
  if (c.reservado_admin) return RESERVADO_ADMIN
  const ids = c.preventista_ids?.length ? c.preventista_ids : []
  if (ids.length === 0) return SIN_ASIGNAR
  return ids.map(id => perfiles.find(p => p.id === id)?.nombre ?? 'Desconocido').join(', ')
}

function fechaAlta(iso: string | undefined): string {
  if (!iso) return ''
  // Día argentino, no UTC (created_at corta el día en UTC).
  return new Intl.DateTimeFormat('sv-SE', { timeZone: 'America/Argentina/Buenos_Aires' }).format(new Date(iso))
}

export function armarFilasClientes(
  clientes: ClienteDB[],
  { zonas, perfiles, sucursalNombre, incluirSaldo }: OpcionesExportClientes
): Record<string, unknown>[] {
  return clientes.map(c => {
    const zonaNombre = c.zona_id != null
      ? zonas.find(z => String(z.id) === String(c.zona_id))?.nombre ?? c.zona ?? ''
      : c.zona ?? ''
    const fila: Record<string, unknown> = {
      'Código': c.codigo ?? '',
      'Nombre fantasía': c.nombre_fantasia,
      'Razón social': c.razon_social ?? '',
      'CUIT': c.cuit ?? '',
      'Dirección': c.direccion ?? '',
      'Aclaración dirección': c.aclaracion_direccion ?? '',
      'Teléfono': c.telefono ?? '',
      'Email': c.email ?? '',
      'Contacto': c.contacto ?? '',
      'Rubro': c.rubro ?? '',
      'Zona': zonaNombre,
      'Preventista': textoAsignacion(c, perfiles),
      'Sucursal': sucursalNombre ?? '',
      'Activo': c.activo === false ? 'No' : 'Sí',
      'Fecha de alta': fechaAlta(c.created_at),
    }
    if (incluirSaldo) fila['Saldo cuenta corriente'] = c.saldo_cuenta ?? 0
    return fila
  })
}
