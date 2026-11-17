import { describe, it, expect } from 'vitest'
import { pasosCascada } from './cascadaGerencial'

const base = { venta: 100000, cmv: 60000, bonif: 5000, mermas: 1000, comision: 2000 }

const rotulos = (e: Parameters<typeof pasosCascada>[0]) => pasosCascada(e).pasos.map(p => p.l)

describe('pasosCascada — sin venta sin costo (el gráfico de hoy)', () => {
  it('sin el dato, los pasos son los de siempre y no hay «− Sin costo»', () => {
    expect(rotulos(base)).toEqual(['Venta', '− CMV', 'Mg comerc.', '− Bonif.', '− Mermas', '− Comis.', 'Contrib.'])
  })

  it('con 0 o con basura tampoco hay paso', () => {
    expect(rotulos({ ...base, sinCosto: 0 })).not.toContain('− Sin costo')
    expect(rotulos({ ...base, sinCosto: Number.NaN })).not.toContain('− Sin costo')
  })

  it('el margen comercial es venta − CMV (+ descuentos), como la card', () => {
    const { pasos } = pasosCascada({ ...base, descuentos: 1500 })
    expect(pasos.find(p => p.l === 'Mg comerc.')?.v).toBe(41500)
  })
})

describe('pasosCascada — con venta sin costo fuera del margen (server nuevo, 1562-b6)', () => {
  it('suma «− Sin costo» entre el CMV y el margen, y el margen cierra con la card', () => {
    const { pasos } = pasosCascada({ ...base, sinCosto: 8000, descuentos: 1500 })
    expect(pasos.map(p => p.l)).toEqual(
      ['Venta', '− CMV', '− Sin costo', '+ Desc. prov.', 'Mg comerc.', '− Bonif.', '− Mermas', '− Comis.', 'Contrib.'],
    )
    // La card del server: margen_comercial = venta − ingreso_sin_costo − cmv + descuentos.
    expect(pasos.find(p => p.l === 'Mg comerc.')?.v).toBe(100000 - 8000 - 60000 + 1500)
    expect(pasos.find(p => p.l === '− Sin costo')?.v).toBe(-8000)
  })

  it('las barras flotantes encadenan: cada paso arranca donde terminó el anterior', () => {
    const { pasos } = pasosCascada({ ...base, sinCosto: 8000 })
    const cmv = pasos.find(p => p.l === '− CMV')!
    const sin = pasos.find(p => p.l === '− Sin costo')!
    const mg = pasos.find(p => p.l === 'Mg comerc.')!
    expect(cmv.r).toEqual([40000, 100000])
    expect(sin.r).toEqual([32000, 40000])
    expect(mg.r).toEqual([0, 32000])
  })

  it('la contribución parte del margen que ya excluye lo sin costo', () => {
    const sin = pasosCascada({ ...base, sinCosto: 8000 })
    const con = pasosCascada(base)
    expect(con.contrib - sin.contrib).toBe(8000)
  })
})

describe('pasosCascada — un sin costo NEGATIVO (una nota de crédito sobre un producto sin costo)', () => {
  it('sigue cerrando con el margen que resta el server: venta − sin costo − CMV', () => {
    // El server resta el sin costo tal cual, también negativo: margen = 100.000 − (−3.000) − 60.000.
    const { pasos } = pasosCascada({ ...base, sinCosto: -3000 })
    expect(pasos.find(p => p.l === 'Mg comerc.')?.v).toBe(43000)
    expect(pasos.map(p => p.l)).toContain('+ Sin costo')
  })

  it('la barra sube y queda con los extremos en orden [bajo, alto]', () => {
    const { pasos } = pasosCascada({ ...base, sinCosto: -3000 })
    const paso = pasos.find(p => p.l === '+ Sin costo')!
    expect(paso.v).toBe(3000)
    expect(paso.r).toEqual([40000, 43000])
    expect(paso.tono).toBe('emerald')
  })

  it('con 0, NaN o sin el dato no hay paso', () => {
    for (const sinCosto of [0, Number.NaN, undefined]) {
      expect(rotulos({ ...base, sinCosto }).some(l => /Sin costo/.test(l))).toBe(false)
    }
  })
})
