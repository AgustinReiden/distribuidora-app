import { describe, it, expect } from 'vitest'
import {
  puedeEditarProductos,
  puedeEditarPreciosPedido,
  puedeCancelarPedido,
  puedeAnularPago,
  puedeAccederDashboard,
  puedeAccederReportes,
  puedeAccederComisiones,
  puedeAccederProveedores,
  puedeAccederPromociones,
  puedeAccederCondicionesMayoristas,
  puedeAccederTransferencias,
  puedeControlarStock,
  puedeRegistrarPagoCliente,
  mostrarMontosEnStats,
} from './permisos'
import type { RolUsuario } from '@/types'

const ROLES: RolUsuario[] = ['admin', 'preventista', 'transportista', 'deposito', 'encargado']

describe('permisos por rol', () => {
  describe('acciones solo admin', () => {
    it.each([
      ['puedeEditarProductos', puedeEditarProductos],
      ['puedeEditarPreciosPedido', puedeEditarPreciosPedido],
      ['puedeCancelarPedido', puedeCancelarPedido],
      ['puedeAnularPago', puedeAnularPago],
      ['puedeAccederReportes', puedeAccederReportes],
      ['puedeAccederComisiones', puedeAccederComisiones],
      ['puedeAccederProveedores', puedeAccederProveedores],
      ['puedeAccederPromociones', puedeAccederPromociones],
      ['puedeAccederCondicionesMayoristas', puedeAccederCondicionesMayoristas],
      ['puedeAccederTransferencias', puedeAccederTransferencias],
    ] as const)('%s solo permite admin', (_name, fn) => {
      expect(fn('admin')).toBe(true)
      for (const rol of ROLES.filter((r) => r !== 'admin')) {
        expect(fn(rol)).toBe(false)
      }
      expect(fn(null)).toBe(false)
      expect(fn(undefined)).toBe(false)
    })
  })

  describe('puedeAccederDashboard', () => {
    it('permite admin y preventista', () => {
      expect(puedeAccederDashboard('admin')).toBe(true)
      expect(puedeAccederDashboard('preventista')).toBe(true)
    })

    it('bloquea encargado, transportista, deposito', () => {
      expect(puedeAccederDashboard('encargado')).toBe(false)
      expect(puedeAccederDashboard('transportista')).toBe(false)
      expect(puedeAccederDashboard('deposito')).toBe(false)
      expect(puedeAccederDashboard(null)).toBe(false)
    })
  })

  describe('puedeControlarStock', () => {
    it('permite admin y encargado', () => {
      expect(puedeControlarStock('admin')).toBe(true)
      expect(puedeControlarStock('encargado')).toBe(true)
    })

    it('bloquea preventista, transportista, deposito y sin rol', () => {
      expect(puedeControlarStock('preventista')).toBe(false)
      expect(puedeControlarStock('transportista')).toBe(false)
      expect(puedeControlarStock('deposito')).toBe(false)
      expect(puedeControlarStock(null)).toBe(false)
      expect(puedeControlarStock(undefined)).toBe(false)
    })
  })

  describe('mostrarMontosEnStats', () => {
    it('encargado solo ve monto en impagos', () => {
      expect(mostrarMontosEnStats('encargado', 'impagos')).toBe(true)
      expect(mostrarMontosEnStats('encargado', 'pendientes')).toBe(false)
      expect(mostrarMontosEnStats('encargado', 'enPreparacion')).toBe(false)
      expect(mostrarMontosEnStats('encargado', 'enCamino')).toBe(false)
      expect(mostrarMontosEnStats('encargado', 'entregados')).toBe(false)
      expect(mostrarMontosEnStats('encargado', 'total')).toBe(false)
    })

    it('admin ve monto en todas', () => {
      const keys = ['pendientes', 'enPreparacion', 'enCamino', 'entregados', 'impagos', 'total'] as const
      for (const k of keys) {
        expect(mostrarMontosEnStats('admin', k)).toBe(true)
      }
    })

    it('otros roles ven monto en todas (sin restriccion)', () => {
      expect(mostrarMontosEnStats('preventista', 'pendientes')).toBe(true)
      expect(mostrarMontosEnStats('transportista', 'entregados')).toBe(true)
    })
  })

  // Fija el invariante de la mig 155: el multi-rol (roles extra por sucursal)
  // habilita llevar la ruta, entregar y cobrar LA PARADA, pero NO el pago a
  // cuenta corriente desde la ficha del cliente. Este gate es el espejo en la
  // UI de los RPC registrar_pago_cliente_fifo / ..._combinado_..., que leen
  // perfiles.rol crudo y exigen admin|encargado. Si alguien "arregla" esta
  // funcion para aceptar roles efectivos, la UI mostraria un boton que el
  // servidor rechaza.
  describe('puedeRegistrarPagoCliente (pago a cuenta corriente por ficha)', () => {
    it('permite solo admin y encargado', () => {
      expect(puedeRegistrarPagoCliente('admin')).toBe(true)
      expect(puedeRegistrarPagoCliente('encargado')).toBe(true)
    })

    it('bloquea al preventista que tambien reparte y al transportista', () => {
      expect(puedeRegistrarPagoCliente('preventista')).toBe(false)
      expect(puedeRegistrarPagoCliente('preventista_taco')).toBe(false)
      expect(puedeRegistrarPagoCliente('transportista')).toBe(false)
      expect(puedeRegistrarPagoCliente('deposito')).toBe(false)
      expect(puedeRegistrarPagoCliente(null)).toBe(false)
      expect(puedeRegistrarPagoCliente(undefined)).toBe(false)
    })
  })
})
