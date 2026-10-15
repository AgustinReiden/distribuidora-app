import { describe, it, expect } from 'vitest'
import fixture from './combos.espejo.json'
import { cantidadDeCombos, prorratearTotal, totalDelCombo } from './combos'

/**
 * PARIDAD DE LOS COMBOS (#1191), lado TypeScript.
 *
 * El server no arma combos: valida los que manda el front recalculando el total
 * (`_combo_total`), el reparto (`_combo_prorrateo`) y la cantidad de combos
 * (`_combo_cantidad`). Si el TS y el SQL difieren en un centavo, el server
 * rechaza pedidos honestos. Este archivo corre las tres puras del front sobre
 * `combos.espejo.json`; `scripts/espejo-combos.mjs` corre las del SQL sobre los
 * mismos casos, en el gate de integridad. Si cambia uno, cambia el otro y se
 * suma el caso.
 */

interface LineaEspejo {
  producto_id: number
  cantidad: number
  ref?: number
  sin_escala?: number
}

interface CasoProrrateo { caso: string; total: number; lineas: LineaEspejo[]; esperado: Record<string, number> }
interface CasoTotal { caso: string; precio: number; k: number; lineas: LineaEspejo[]; esperado: number }
interface CasoCantidad {
  caso: string
  componentes: { componente: number; cantidad: number; productos: number[] }[]
  lineas: LineaEspejo[]
  esperado: number | null
}

const casos = fixture as unknown as { prorrateo: CasoProrrateo[]; total: CasoTotal[]; cantidad: CasoCantidad[] }

describe('espejo de combos: prorrateo', () => {
  it.each(casos.prorrateo.map(c => [c.caso, c] as const))('%s', (_n, c) => {
    const r = prorratearTotal(c.total, c.lineas.map(l => ({
      productoId: String(l.producto_id), cantidad: l.cantidad, ref: l.ref as number,
    })))
    expect(Object.fromEntries(r)).toEqual(c.esperado)
  })
})

describe('espejo de combos: total', () => {
  it.each(casos.total.map(c => [c.caso, c] as const))('%s', (_n, c) => {
    expect(totalDelCombo(c.precio, c.k, c.lineas.map(l => ({
      productoId: String(l.producto_id), cantidad: l.cantidad, ref: l.ref as number, sinEscala: l.sin_escala ?? null,
    })))).toBe(c.esperado)
  })
})

describe('espejo de combos: cantidad de combos', () => {
  it.each(casos.cantidad.map(c => [c.caso, c] as const))('%s', (_n, c) => {
    const lineas = new Map(c.lineas.map(l => [String(l.producto_id), l.cantidad]))
    const componentes = c.componentes.map(x => ({ ...x, productos: x.productos.map(String) }))
    expect(cantidadDeCombos(componentes, lineas)).toBe(c.esperado)
  })
})

describe('espejo de combos: el fixture', () => {
  it('no repite nombres de caso', () => {
    const nombres = [...casos.prorrateo, ...casos.total, ...casos.cantidad].map(c => c.caso)
    expect(new Set(nombres).size).toBe(nombres.length)
  })
})
