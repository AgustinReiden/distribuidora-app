import { describe, it, expect } from 'vitest'
import { entregaMarcada } from './entregaMarcada'
import { formatDateTime } from './formatters'

const entregado = (over: Record<string, unknown> = {}) => ({
  estado: 'entregado',
  entregado_at: '2026-11-12T12:14:00Z', // 09:14 en Argentina (UTC-3)
  entregado_por_perfil: { nombre: 'Juan' },
  ...over,
})

describe('entregaMarcada', () => {
  it('un pedido que no está entregado no tiene entrega marcada', () => {
    expect(entregaMarcada(entregado({ estado: 'pendiente' }))).toBeNull()
    expect(entregaMarcada(entregado({ estado: 'cancelado' }))).toBeNull()
  })

  it('entregado sin entregado_at (anterior al registro) da null', () => {
    expect(entregaMarcada(entregado({ entregado_at: null }))).toBeNull()
    expect(entregaMarcada(entregado({ entregado_at: undefined }))).toBeNull()
  })

  it('con perfil: el nombre, el instante completo y el texto corto', () => {
    const r = entregaMarcada(entregado())
    expect(r?.quien).toBe('Juan')
    expect(r?.texto).toBe('marcó Juan, 12/11 09:14')
    // `cuando` es formatDateTime tal cual (el ICU decide si la hora va en 12 o 24).
    expect(r?.cuando).toBe(formatDateTime('2026-11-12T12:14:00Z'))
    expect(r?.cuando).toContain('12/11/2026')
  })

  it('sin perfil no inventa un nombre', () => {
    const r = entregaMarcada(entregado({ entregado_por_perfil: null }))
    expect(r?.quien).toBeNull()
    expect(r?.texto).toBe('marcado el 12/11 09:14')
    expect(entregaMarcada(entregado({ entregado_por_perfil: undefined }))?.quien).toBeNull()
  })

  it('un perfil sin nombre se trata como sin perfil', () => {
    expect(entregaMarcada(entregado({ entregado_por_perfil: { nombre: '  ' } }))?.quien).toBeNull()
  })

  it('usa la hora de Argentina: 02:30 UTC es el día anterior a las 23:30', () => {
    const r = entregaMarcada(entregado({ entregado_at: '2026-11-13T02:30:00Z' }))
    expect(r?.texto).toBe('marcó Juan, 12/11 23:30')
    expect(r?.cuando).toContain('12/11/2026')
  })
})
