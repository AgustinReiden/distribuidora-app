import { describe, it, expect } from 'vitest'
import { resumenAvisosPedidos, etiquetaTotalAvisos } from './resumenAvisosPedidos'

describe('resumenAvisosPedidos', () => {
  // Sin avisos no hay línea: una cabecera que dice "0 avisos" es ruido arriba
  // de la lista, que es justo lo que el pliegue vino a sacar.
  it('devuelve null si no hay nada que avisar', () => {
    expect(resumenAvisosPedidos({ trabados: 0, noEntregados: 0 })).toBeNull()
  })

  it('singular: un pedido trabado', () => {
    expect(resumenAvisosPedidos({ trabados: 1, noEntregados: 0 })).toEqual({
      total: 1,
      partes: ['1 pedido trabado en asignado'],
    })
  })

  it('plural: varios pedidos trabados', () => {
    expect(resumenAvisosPedidos({ trabados: 2, noEntregados: 0 })).toEqual({
      total: 1,
      partes: ['2 pedidos trabados en asignado'],
    })
  })

  it('singular: un no entregado', () => {
    expect(resumenAvisosPedidos({ trabados: 0, noEntregados: 1 })).toEqual({
      total: 1,
      partes: ['1 no entregado'],
    })
  })

  it('plural: varios no entregados', () => {
    expect(resumenAvisosPedidos({ trabados: 0, noEntregados: 3 })).toEqual({
      total: 1,
      partes: ['3 no entregados'],
    })
  })

  // El ejemplo del issue #714: el total cuenta avisos (paneles), no pedidos.
  it('con los dos, total es la cantidad de avisos y los trabados van primero', () => {
    expect(resumenAvisosPedidos({ trabados: 1, noEntregados: 3 })).toEqual({
      total: 2,
      partes: ['1 pedido trabado en asignado', '3 no entregados'],
    })
  })

  it('un conteo negativo no genera aviso', () => {
    expect(resumenAvisosPedidos({ trabados: -1, noEntregados: 0 })).toBeNull()
  })
})

describe('etiquetaTotalAvisos', () => {
  it('singular y plural', () => {
    expect(etiquetaTotalAvisos(1)).toBe('1 aviso')
    expect(etiquetaTotalAvisos(2)).toBe('2 avisos')
  })
})
