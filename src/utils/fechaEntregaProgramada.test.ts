import { describe, it, expect } from 'vitest'
import { DIAS_ADELANTE_ENTREGA_PROGRAMADA, techoFechaEntregaProgramada } from './fechaEntregaProgramada'

describe('techoFechaEntregaProgramada (1559-b6, D21)', () => {
  it('son 60 días, como _fecha_entrega_programada_fuera_de_rango', () => {
    expect(DIAS_ADELANTE_ENTREGA_PROGRAMADA).toBe(60)
  })

  it('cuenta días calendario desde hoy', () => {
    expect(techoFechaEntregaProgramada('2026-11-16')).toBe('2027-01-15')
  })

  it('cruza fin de mes y año bisiesto sin depender de la zona', () => {
    expect(techoFechaEntregaProgramada('2028-01-31')).toBe('2028-03-31')
  })
})
