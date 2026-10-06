import { describe, it, expect } from 'vitest'
import { estadoSubrubro, MOTIVO_RUBRO_SIN_FILA } from './subrubroFicha'

const base = { rubro: 'GASEOSAS', rubroNuevo: null, cantidadSubrubros: 0, puedeCrear: true }

describe('estadoSubrubro', () => {
  it('sin rubro elegido no se ve', () => {
    expect(estadoSubrubro({ ...base, rubro: '' })).toEqual({ visible: false })
  })

  it('rubro sin subrubros: se ve y deja crear (el caso de prod: 0 subrubros)', () => {
    expect(estadoSubrubro(base)).toEqual({ visible: true, deshabilitado: false, puedeElegir: false, puedeCrear: true })
  })

  it('rubro con subrubros: se puede elegir y crear', () => {
    expect(estadoSubrubro({ ...base, cantidadSubrubros: 2 }))
      .toEqual({ visible: true, deshabilitado: false, puedeElegir: true, puedeCrear: true })
  })

  it('sin permiso: elige si hay, y no ofrece crear', () => {
    expect(estadoSubrubro({ ...base, cantidadSubrubros: 2, puedeCrear: false }))
      .toEqual({ visible: true, deshabilitado: false, puedeElegir: true, puedeCrear: false })
    expect(estadoSubrubro({ ...base, puedeCrear: false })).toEqual({ visible: false })
  })

  it('rubro que no es fila de categorias (#763): deshabilitado con motivo', () => {
    expect(estadoSubrubro({ ...base, rubrosConFila: ['AGUAS'] }))
      .toEqual({ visible: true, deshabilitado: true, motivo: MOTIVO_RUBRO_SIN_FILA })
  })

  it('rubro que sí es fila: habilitado', () => {
    expect(estadoSubrubro({ ...base, rubrosConFila: ['GASEOSAS'] }))
      .toMatchObject({ visible: true, deshabilitado: false })
  })

  it('rubro nuevo tipeado: sólo subrubro nuevo; vacío o sin permiso no se ve', () => {
    expect(estadoSubrubro({ ...base, rubroNuevo: 'BEBIDAS' }))
      .toEqual({ visible: true, deshabilitado: false, puedeElegir: false, puedeCrear: true })
    expect(estadoSubrubro({ ...base, rubroNuevo: '  ' })).toEqual({ visible: false })
    expect(estadoSubrubro({ ...base, rubroNuevo: 'BEBIDAS', puedeCrear: false })).toEqual({ visible: false })
  })
})
