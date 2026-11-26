/**
 * #1697: la etiqueta «Refechado» y la regla del motivo, del lado del front. El server
 * (marcar_no_entregado) es el que refecha; esto decide qué se muestra.
 */
import { describe, it, expect } from 'vitest'
import { etiquetaRefechado, seRefechaConMotivo, MOTIVO_SIN_REFECHA } from './refechado'
import { MOTIVOS_NO_ENTREGA } from '../constants/motivosNoEntrega'

describe('seRefechaConMotivo', () => {
  it('todos los motivos refechan salvo «Lo rechazó»', () => {
    const refechan = MOTIVOS_NO_ENTREGA.filter(m => seRefechaConMotivo(m.valor)).map(m => m.valor)
    expect(refechan).toEqual(['cerrado', 'sin_dinero', 'ausente', 'direccion_incorrecta', 'clima', 'otro'])
    expect(seRefechaConMotivo(MOTIVO_SIN_REFECHA)).toBe(false)
    expect(MOTIVOS_NO_ENTREGA.some(m => m.valor === MOTIVO_SIN_REFECHA)).toBe(true)
  })

  it('sin motivo no hay refechado', () => {
    expect(seRefechaConMotivo(null)).toBe(false)
    expect(seRefechaConMotivo('')).toBe(false)
  })
})

describe('etiquetaRefechado', () => {
  it('un pendiente refechado del 25/11 al 26/11 dice «Refechado» con la fecha original', () => {
    const e = etiquetaRefechado({ estado: 'pendiente', fecha_entrega_programada: '2026-11-26', entrega_refechada_desde: '2026-11-25' })
    expect(e).toEqual({ texto: 'Refechado', detalle: 'Entrega original: 25/11', original: '25/11' })
  })

  it('asignado o en preparación también la muestran', () => {
    for (const estado of ['asignado', 'en_preparacion']) {
      expect(etiquetaRefechado({ estado, entrega_refechada_desde: '2026-11-25' })?.texto).toBe('Refechado')
    }
  })

  it('sin marca, entregado o cancelado: no se muestra', () => {
    expect(etiquetaRefechado({ estado: 'pendiente', entrega_refechada_desde: null })).toBeNull()
    expect(etiquetaRefechado({ estado: 'pendiente' })).toBeNull()
    expect(etiquetaRefechado({ estado: 'entregado', entrega_refechada_desde: '2026-11-25' })).toBeNull()
    expect(etiquetaRefechado({ estado: 'cancelado', entrega_refechada_desde: '2026-11-25' })).toBeNull()
    expect(etiquetaRefechado(null)).toBeNull()
  })
})
