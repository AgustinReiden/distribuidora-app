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

/**
 * Si el rol puede controlar el stock: ver el panel de productos con stock bajo
 * y descargar la planilla de control de stock (Excel). Operacion de solo
 * lectura, no implica editar productos. Admin y encargado.
 */
export function puedeControlarStock(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin' || rol === 'encargado'
}

/**
 * Si el rol puede CARGAR la planilla de control de stock (aplicar ajustes que
 * modifican el stock). Solo admin: si el encargado pudiera cargarla, sería una
 * vía para editar stock sin permisos. Descargar y ver histórico sí los puede
 * (ver puedeControlarStock). El RPC aplicar_control_stock revalida es_admin().
 */
export function puedeCargarControlStock(rol: RolUsuario | null | undefined): boolean {
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
  return rol === 'admin' || rol === 'preventista' || rol === 'preventista_taco'
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

export function puedeCrearCliente(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin' || rol === 'preventista' || rol === 'preventista_taco' || rol === 'encargado'
}

export function puedeCrearPedido(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin' || rol === 'preventista' || rol === 'preventista_taco' || rol === 'encargado'
}

/**
 * Si el rol puede ver montos comerciales (ventas, totales, ticket promedio, saldos
 * de cuenta corriente, historicos de compra). Falso para preventista_taco.
 */
export function puedeVerMontosYVentas(rol: RolUsuario | null | undefined): boolean {
  return rol !== 'preventista_taco'
}

/** Si el rol puede ver el saldo de cuenta corriente en la ficha de cliente. */
export function puedeVerSaldoCliente(rol: RolUsuario | null | undefined): boolean {
  return rol !== 'preventista_taco'
}

/** Si el rol puede ver el historial de ventas/compras de un cliente. */
export function puedeVerHistorialVentasCliente(rol: RolUsuario | null | undefined): boolean {
  return rol !== 'preventista_taco'
}

/** Si el rol puede ver la facturacion total en el dashboard. Solo admin. */
export function puedeVerFacturacionTotal(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin'
}

/** Si el rol puede ver agregados comerciales (top productos por venta, ticket promedio). Solo admin. */
export function puedeVerAgregadosDashboard(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin'
}

/** Si el rol puede registrar pagos desde la ficha de cliente (admin o encargado). */
export function puedeRegistrarPagoCliente(rol: RolUsuario | null | undefined): boolean {
  return rol === 'admin' || rol === 'encargado'
}

/** Si el rol puede editar el descuento porcentual precargado del cliente. */
export function puedeEditarDescuentoCliente(rol: RolUsuario | null | undefined): boolean {
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
  if (rol === 'preventista_taco') return false
  if (rol === 'encargado') return key === 'impagos'
  return true
}
