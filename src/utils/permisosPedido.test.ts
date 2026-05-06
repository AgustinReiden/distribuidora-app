import { describe, expect, it } from 'vitest'
import { preventistaPuedeEditar, HORA_CORTE_PREVENTISTA } from './permisosPedido'

const USER_ID = 'user-1'
const OTRO_USER = 'user-2'

// Helper: construye un Date "real" en hora ARG.
// Argentina = UTC-3 (sin DST). Para simular "hoy 14:00 ARG" => 17:00 UTC.
function argDate(yyyymmdd: string, hh: number, mm = 0): Date {
  const [y, m, d] = yyyymmdd.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d, hh + 3, mm))
}

describe('preventistaPuedeEditar', () => {
  describe('cuando NO debe permitir edicion', () => {
    it('niega si no hay currentUserId', () => {
      const pedido = { usuario_id: USER_ID, created_at: argDate('2026-05-06', 10).toISOString(), estado: 'pendiente' as const }
      const now = argDate('2026-05-06', 14)
      expect(preventistaPuedeEditar(pedido, undefined, now)).toBe(false)
    })

    it('niega si el pedido pertenece a otro preventista', () => {
      const pedido = { usuario_id: OTRO_USER, created_at: argDate('2026-05-06', 10).toISOString(), estado: 'pendiente' as const }
      const now = argDate('2026-05-06', 14)
      expect(preventistaPuedeEditar(pedido, USER_ID, now)).toBe(false)
    })

    it('niega si el pedido esta entregado', () => {
      const pedido = { usuario_id: USER_ID, created_at: argDate('2026-05-06', 10).toISOString(), estado: 'entregado' as const }
      const now = argDate('2026-05-06', 14)
      expect(preventistaPuedeEditar(pedido, USER_ID, now)).toBe(false)
    })

    it('niega si el pedido esta cancelado', () => {
      const pedido = { usuario_id: USER_ID, created_at: argDate('2026-05-06', 10).toISOString(), estado: 'cancelado' as const }
      const now = argDate('2026-05-06', 14)
      expect(preventistaPuedeEditar(pedido, USER_ID, now)).toBe(false)
    })

    it('niega si created_at es null/undefined', () => {
      const pedido = { usuario_id: USER_ID, created_at: undefined, estado: 'pendiente' as const }
      const now = argDate('2026-05-06', 14)
      expect(preventistaPuedeEditar(pedido, USER_ID, now)).toBe(false)
    })

    it('niega si el pedido fue creado ayer (ARG)', () => {
      const pedido = { usuario_id: USER_ID, created_at: argDate('2026-05-05', 10).toISOString(), estado: 'pendiente' as const }
      const now = argDate('2026-05-06', 10)
      expect(preventistaPuedeEditar(pedido, USER_ID, now)).toBe(false)
    })

    it('niega justo a las 17:00:00 ARG', () => {
      const pedido = { usuario_id: USER_ID, created_at: argDate('2026-05-06', 10).toISOString(), estado: 'pendiente' as const }
      const now = argDate('2026-05-06', HORA_CORTE_PREVENTISTA)
      expect(preventistaPuedeEditar(pedido, USER_ID, now)).toBe(false)
    })

    it('niega despues de las 17:00 ARG', () => {
      const pedido = { usuario_id: USER_ID, created_at: argDate('2026-05-06', 10).toISOString(), estado: 'pendiente' as const }
      const now = argDate('2026-05-06', 18, 30)
      expect(preventistaPuedeEditar(pedido, USER_ID, now)).toBe(false)
    })
  })

  describe('cuando SI debe permitir edicion', () => {
    it('permite si es el creador, mismo dia ARG, antes de 17:00, estado pendiente', () => {
      const pedido = { usuario_id: USER_ID, created_at: argDate('2026-05-06', 10).toISOString(), estado: 'pendiente' as const }
      const now = argDate('2026-05-06', 14)
      expect(preventistaPuedeEditar(pedido, USER_ID, now)).toBe(true)
    })

    it('permite a las 16:59 ARG (justo antes del corte)', () => {
      const pedido = { usuario_id: USER_ID, created_at: argDate('2026-05-06', 8).toISOString(), estado: 'pendiente' as const }
      const now = argDate('2026-05-06', 16, 59)
      expect(preventistaPuedeEditar(pedido, USER_ID, now)).toBe(true)
    })

    it('permite incluso si el estado es en_preparacion o asignado (no entregado/cancelado)', () => {
      const pedidoBase = { usuario_id: USER_ID, created_at: argDate('2026-05-06', 10).toISOString() }
      const now = argDate('2026-05-06', 14)
      expect(preventistaPuedeEditar({ ...pedidoBase, estado: 'en_preparacion' }, USER_ID, now)).toBe(true)
      expect(preventistaPuedeEditar({ ...pedidoBase, estado: 'asignado' }, USER_ID, now)).toBe(true)
    })

    it('cruce de medianoche UTC: pedido creado a las 02:00 ARG (= 05:00 UTC) sigue siendo del mismo dia ARG a las 14:00 ARG', () => {
      // 2026-05-06 02:00 ARG === 2026-05-06 05:00 UTC
      const pedido = { usuario_id: USER_ID, created_at: argDate('2026-05-06', 2).toISOString(), estado: 'pendiente' as const }
      const now = argDate('2026-05-06', 14)
      expect(preventistaPuedeEditar(pedido, USER_ID, now)).toBe(true)
    })

    it('borde TZ: pedido creado a las 23:30 ARG del 5/5 NO permite edicion el 6/5 (es del dia anterior ARG)', () => {
      // 2026-05-05 23:30 ARG = 2026-05-06 02:30 UTC. En ARG sigue siendo 5/5.
      const pedido = { usuario_id: USER_ID, created_at: argDate('2026-05-05', 23, 30).toISOString(), estado: 'pendiente' as const }
      const now = argDate('2026-05-06', 10)
      expect(preventistaPuedeEditar(pedido, USER_ID, now)).toBe(false)
    })
  })
})
