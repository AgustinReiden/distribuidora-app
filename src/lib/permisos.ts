/**
 * Permisos centralizados por rol.
 *
 * Reglas de negocio puras: dado un rol devuelve si la accion esta permitida.
 * No usar hooks ni contexto: se consumen desde containers que ya tienen el rol.
 */

import type { RolUsuario } from '@/types'

export function puedeEditarProductos(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin'
}

export function puedeEditarPreciosPedido(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin'
}

export function puedeCancelarPedido(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin'
}

export function puedeAnularPago(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin'
}

export function puedeAccederDashboard(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin' || rol === 'preventista'
}

export function puedeAccederReportes(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin'
}

export function puedeAccederComisiones(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin'
}

export function puedeAccederProveedores(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin'
}

export function puedeAccederPromociones(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin'
}

export function puedeAccederCondicionesMayoristas(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin'
}

export function puedeAccederTransferencias(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin'
}

export function puedeAccederGeolocalizacion(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin'
}

export type PedidoStatKey =
  | 'pendientes'
  | 'enPreparacion'
  | 'enCamino'
  | 'entregados'
  | 'impagos'
  | 'total'

export function mostrarMontosEnStats(
  rol: RolUsuario | null | undefined,
  key: PedidoStatKey,
): boolean {
  if (rol === 'encargado') return key === 'impagos'
  return true
}
