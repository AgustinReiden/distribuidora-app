import { describe, expect, it } from 'vitest'
import { adminPuedeEditarCompra, DIAS_EDICION_COMPRA } from './permisosCompra'

// Helper: now y created_at en milisegundos para crear escenarios de ventana.
function compra(diasAtras: number, estado: string = 'recibida') {
  const created = new Date(Date.now() - diasAtras * 24 * 60 * 60 * 1000)
  return { estado, created_at: created.toISOString() }
}

describe('adminPuedeEditarCompra', () => {
  describe('cuando NO debe permitir edicion', () => {
    it('niega si no es admin (encargado / preventista / otro)', () => {
      expect(adminPuedeEditarCompra(compra(1), false)).toBe(false)
    })

    it('niega si la compra esta cancelada', () => {
      expect(adminPuedeEditarCompra(compra(1, 'cancelada'), true)).toBe(false)
    })

    it('niega si created_at es null/undefined', () => {
      expect(adminPuedeEditarCompra({ estado: 'recibida', created_at: null }, true)).toBe(false)
      expect(adminPuedeEditarCompra({ estado: 'recibida' }, true)).toBe(false)
    })

    it('niega si created_at es invalido', () => {
      expect(adminPuedeEditarCompra({ estado: 'recibida', created_at: 'no-es-fecha' }, true)).toBe(false)
    })

    it('niega si pasaron mas de 7 dias', () => {
      expect(adminPuedeEditarCompra(compra(8), true)).toBe(false)
    })

    it('niega justo al pasar 7 dias + 1 segundo', () => {
      const now = new Date('2026-05-12T12:00:00Z')
      const created = new Date(now.getTime() - DIAS_EDICION_COMPRA * 86400_000 - 1000)
      expect(adminPuedeEditarCompra({ estado: 'recibida', created_at: created.toISOString() }, true, now)).toBe(false)
    })
  })

  describe('cuando SI debe permitir edicion', () => {
    it('permite si es admin y la compra es de hoy', () => {
      expect(adminPuedeEditarCompra(compra(0), true)).toBe(true)
    })

    it('permite a los 3 dias', () => {
      expect(adminPuedeEditarCompra(compra(3), true)).toBe(true)
    })

    it('permite justo a los 7 dias (borde inclusivo)', () => {
      const now = new Date('2026-05-12T12:00:00Z')
      const created = new Date(now.getTime() - DIAS_EDICION_COMPRA * 86400_000)
      expect(adminPuedeEditarCompra({ estado: 'recibida', created_at: created.toISOString() }, true, now)).toBe(true)
    })

    it('permite si el estado es recibida, parcial o pendiente (cualquier no cancelada)', () => {
      expect(adminPuedeEditarCompra(compra(1, 'recibida'), true)).toBe(true)
      expect(adminPuedeEditarCompra(compra(1, 'parcial'), true)).toBe(true)
      expect(adminPuedeEditarCompra(compra(1, 'pendiente'), true)).toBe(true)
    })
  })
})
