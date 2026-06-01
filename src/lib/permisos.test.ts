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
})
