import { describe, it, expect } from 'vitest'
import { argQuienCobro, cobradorDeLaEntrega, puedeCorregirCobro, pendienteDelFaltante, faltantesParaMostrar } from './quienCobro'

describe('cobradorDeLaEntrega (T4, #1710)', () => {
  it('sin elegir, el cobro de la entrega es del chofer de la boleta', () => {
    expect(cobradorDeLaEntrega(undefined, undefined, 'chofer-a')).toBe('chofer-a')
  })
  it('sin elegir, el chofer elegido en «Quién repartió» gana al de la boleta', () => {
    expect(cobradorDeLaEntrega(undefined, { tipo: 'chofer', transportistaId: 'chofer-b' }, null)).toBe('chofer-b')
  })
  it('un retiro en depósito es de quien lo carga', () => {
    expect(cobradorDeLaEntrega(undefined, { tipo: 'retiro' }, null)).toBeNull()
  })
  it('lo que eligió el admin manda, también «yo» (null)', () => {
    expect(cobradorDeLaEntrega('encargada', undefined, 'chofer-a')).toBe('encargada')
    expect(cobradorDeLaEntrega(null, undefined, 'chofer-a')).toBeNull()
  })
})

describe('puedeCorregirCobro', () => {
  it('el admin corrige en una abierta o en disconformidad, no en una cerrada', () => {
    expect(puedeCorregirCobro({ esAdmin: true, esEncargado: false, estado: 'pendiente', esDeEncargado: false })).toBe(true)
    expect(puedeCorregirCobro({ esAdmin: true, esEncargado: false, estado: 'disconformidad', esDeEncargado: true })).toBe(true)
    expect(puedeCorregirCobro({ esAdmin: true, esEncargado: false, estado: 'confirmada', esDeEncargado: false })).toBe(false)
    expect(puedeCorregirCobro({ esAdmin: true, esEncargado: false, estado: 'resuelta', esDeEncargado: false })).toBe(false)
  })
  it('el encargado sólo en una abierta de un chofer', () => {
    expect(puedeCorregirCobro({ esAdmin: false, esEncargado: true, estado: 'pendiente', esDeEncargado: false })).toBe(true)
    expect(puedeCorregirCobro({ esAdmin: false, esEncargado: true, estado: 'pendiente', esDeEncargado: true })).toBe(false)
    expect(puedeCorregirCobro({ esAdmin: false, esEncargado: true, estado: 'disconformidad', esDeEncargado: false })).toBe(false)
  })
  it('el chofer no corrige', () => {
    expect(puedeCorregirCobro({ esAdmin: false, esEncargado: false, estado: 'pendiente', esDeEncargado: false })).toBe(false)
  })
})

describe('pendienteDelFaltante', () => {
  it('faltante de $ 5.000 con $ 2.000 pagados por el cliente: quedan $ 3.000', () => {
    expect(pendienteDelFaltante({ causal: 'empleado', monto: 5000, recuperado: 2000 })).toBe(3000)
  })
  it('sin nada pagado, todo; pagado entero, 0', () => {
    expect(pendienteDelFaltante({ causal: 'empleado', monto: 5000 })).toBe(5000)
    expect(pendienteDelFaltante({ causal: 'empleado', monto: 5000, recuperado: 5000 })).toBe(0)
  })
  it('un robo o un gasto no se cobra contra el cliente', () => {
    expect(pendienteDelFaltante({ causal: 'robo_perdida', monto: 5000 })).toBe(0)
  })
})

describe('faltantesParaMostrar', () => {
  it('positivo: faltantes cargados; negativo: lo cobrado contra faltantes de otros', () => {
    expect(faltantesParaMostrar(5000)).toEqual({ cargados: 5000, cobradosContraFaltantes: 0 })
    expect(faltantesParaMostrar(-5000)).toEqual({ cargados: 0, cobradosContraFaltantes: 5000 })
  })
})

describe('argQuienCobro', () => {
  it('sólo manda p_cobrado_por si se eligió', () => {
    expect(argQuienCobro(undefined)).toEqual({})
    expect(argQuienCobro(null)).toEqual({})
    expect(argQuienCobro('u-1')).toEqual({ p_cobrado_por: 'u-1' })
  })
})
