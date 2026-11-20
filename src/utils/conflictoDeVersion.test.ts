import { describe, it, expect } from 'vitest'
import {
  ConflictoDeVersionError,
  conflictoDeRespuesta,
  esConflictoDeVersion,
  versionesDelOrden,
} from './conflictoDeVersion'

describe('conflictoDeRespuesta (C4b, 1599-b8)', () => {
  it('un rechazo de «otro lo cambió» del server es un ConflictoDeVersionError con su código y 409', () => {
    const e = conflictoDeRespuesta({
      success: false,
      codigo: 'combo_cambiado',
      error: 'Otro usuario cambió este combo mientras lo editabas: no se guardó nada. Volvé a abrirlo para ver cómo quedó.',
    })
    expect(e).toBeInstanceOf(ConflictoDeVersionError)
    expect(e?.codigo).toBe('combo_cambiado')
    expect(e?.status).toBe(409)
    expect(esConflictoDeVersion(e)).toBe(true)
  })

  it('el mensaje dice que lo cargado sigue en la ventana (no se pierde lo tipeado)', () => {
    const e = conflictoDeRespuesta({ success: false, codigo: 'promocion_cambiada', error: 'Otro usuario cambió esta promoción mientras la editabas: no se guardó nada.' })
    expect(e?.message).toContain('Otro usuario cambió esta promoción')
    expect(e?.message).toContain('Lo que cargaste sigue en esta ventana')
  })

  it('el del orden de los combos dice que el orden ya se actualizó y que se puede volver a guardar', () => {
    const e = conflictoDeRespuesta({ success: false, codigo: 'orden_cambiado', error: 'Otro usuario cambió un combo que compite con éste.' })
    expect(e?.message).toContain('Ya se cargaron los combos de ahora')
  })

  it('otro rechazo (o un éxito) no es un conflicto', () => {
    expect(conflictoDeRespuesta({ success: false, error: 'El combo necesita un nombre.' })).toBeNull()
    expect(conflictoDeRespuesta({ success: false, codigo: 'contenedor_sin_stock', error: 'x' })).toBeNull()
    expect(conflictoDeRespuesta({ success: true })).toBeNull()
    expect(conflictoDeRespuesta(null)).toBeNull()
    expect(esConflictoDeVersion(new Error('x'))).toBe(false)
  })
})

describe('versionesDelOrden (C4b, 1599-b8)', () => {
  const combos = [
    { id: '7', updatedAt: '2026-11-18T10:00:00.123456+00:00' },
    { id: '8', updatedAt: '2026-11-18T11:00:00+00:00' },
    { id: '9', updatedAt: null },
  ]

  it('la versión de cada combo del orden, sin el que se guarda ni el nuevo (0)', () => {
    expect(versionesDelOrden([0, 7, 8, 9], combos, undefined)).toEqual({
      7: '2026-11-18T10:00:00.123456+00:00',
      8: '2026-11-18T11:00:00+00:00',
      9: null,
    })
    expect(versionesDelOrden([8, 7], combos, '7')).toEqual({ 8: '2026-11-18T11:00:00+00:00' })
  })

  it('el texto de la versión viaja tal cual llegó (los microsegundos cuentan)', () => {
    expect(versionesDelOrden([7], combos, undefined)?.['7']).toBe('2026-11-18T10:00:00.123456+00:00')
  })

  it('sin orden no hay versiones', () => {
    expect(versionesDelOrden(undefined, combos, '7')).toBeUndefined()
  })
})
