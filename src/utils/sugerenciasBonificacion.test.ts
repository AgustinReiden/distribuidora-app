/**
 * Fixtures SINTÉTICOS (el repo es público): productos, proveedores e importes
 * inventados. La forma imita el caso que motivó #908 —un importe fijo por
 * bulto sobre un grupo de productos, sin descontar en la factura— y nada más.
 */
import { describe, it, expect } from 'vitest'
import { sugerirBonificaciones, promoVigente } from './sugerenciasBonificacion'
import type { CargoParaSugerencia, LineaParaSugerencia, PromocionProveedor } from './sugerenciasBonificacion'

const promoBulto = (over: Partial<PromocionProveedor> = {}): PromocionProveedor => ({
  id: '7',
  nombre: 'Promo bebidas grandes',
  tipo: 'monto_por_unidad',
  montoPorUnidad: 120,
  porcentaje: null,
  vigenteDesde: '2026-01-01',
  vigenteHasta: '2026-12-31',
  activo: true,
  productoIds: ['10', '11'],
  ...over,
})

// Dos productos en la promo (10, 11) y dos afuera (20: agua, 21: jugo).
const lineas: LineaParaSugerencia[] = [
  { lineaId: 1, productoId: '10', cantidad: 50, costoUnitario: 3000, bonificacion: 0 },
  { lineaId: 2, productoId: '11', cantidad: 30, costoUnitario: 2800, bonificacion: 0 },
  { lineaId: 3, productoId: '20', cantidad: 40, costoUnitario: 1500, bonificacion: 0 },
  { lineaId: 4, productoId: '21', cantidad: 10, costoUnitario: 2000, bonificacion: 0 },
]

const base = { lineas, cargos: [] as CargoParaSugerencia[], promos: [promoBulto()], fechaCompra: '2026-06-15' }

describe('sugerirBonificaciones', () => {
  it('detecta la bonificación no deducida con su monto exacto y su alcance', () => {
    const [s, ...resto] = sugerirBonificaciones(base)
    expect(resto).toHaveLength(0)
    // (50 + 30) × 120 = 9600
    expect(s.monto).toBe(-9600)
    expect(s.esperado).toBe(9600)
    expect(s.base).toBe('cantidad')
    expect(s.lineasAlcance).toEqual([1, 2])
    expect(s.productoIds).toEqual(['10', '11'])
    // Fuera de la promo, peso 0: no se reparte sobre el agua ni el jugo.
    expect(s.pesos).toEqual({ 1: 50, 2: 30, 3: 0, 4: 0 })
    expect(s.promoId).toBe('7')
  })

  it('si la factura ya la descontó con un cargo negativo sobre esas líneas, no sugiere', () => {
    const cargos: CargoParaSugerencia[] = [{ monto: -9600, pesos: { 1: 50, 2: 30, 3: 0, 4: 0 } }]
    expect(sugerirBonificaciones({ ...base, cargos })).toEqual([])
  })

  it('un cargo que cae sólo en parte en el alcance cubre sólo esa parte', () => {
    // Mitad del peso adentro (1: 40) y mitad afuera (3: 40): cubre 2000 de 4000.
    const cargos: CargoParaSugerencia[] = [{ monto: -4000, pesos: { 1: 40, 3: 40 } }]
    const [s] = sugerirBonificaciones({ ...base, cargos })
    expect(s.yaDescontado).toBe(2000)
    expect(s.monto).toBe(-7600)
  })

  it('los cargos positivos (flete) no cuentan como descuento', () => {
    const cargos: CargoParaSugerencia[] = [{ monto: 5000, pesos: { 1: 1, 2: 1 } }]
    expect(sugerirBonificaciones({ ...base, cargos })[0].monto).toBe(-9600)
  })

  it('una diferencia dentro de la tolerancia no se sugiere', () => {
    // Faltan 40 de 9600: menos del 0,5 % (48).
    const cargos: CargoParaSugerencia[] = [{ monto: -9560, pesos: { 1: 50, 2: 30 } }]
    expect(sugerirBonificaciones({ ...base, cargos })).toEqual([])
    // Faltan 60: más que la tolerancia.
    const cargos2: CargoParaSugerencia[] = [{ monto: -9540, pesos: { 1: 50, 2: 30 } }]
    expect(sugerirBonificaciones({ ...base, cargos: cargos2 })[0].monto).toBe(-60)
  })

  it('el piso de la tolerancia es $1 aunque lo esperado sea chico', () => {
    const promos = [promoBulto({ montoPorUnidad: 0.01 })]
    // 80 × 0,01 = 0,80 < 1
    expect(sugerirBonificaciones({ ...base, promos })).toEqual([])
  })

  it('una factura sin productos de la promo no sugiere nada', () => {
    const soloAfuera = lineas.filter(l => ['20', '21'].includes(l.productoId))
    expect(sugerirBonificaciones({ ...base, lineas: soloAfuera })).toEqual([])
  })

  it('la línea cuyo % de bonificación ya cubre la promo sale del alcance', () => {
    // Línea 1: 50 × 3000 × 10 % = 15000 ≥ 50 × 120 = 6000 → cubierta.
    const conBonif = lineas.map(l => (l.lineaId === 1 ? { ...l, bonificacion: 10 } : l))
    const [s] = sugerirBonificaciones({ ...base, lineas: conBonif })
    expect(s.lineasAlcance).toEqual([2])
    expect(s.monto).toBe(-3600)
    expect(s.pesos[1]).toBe(0)
    expect(s.productoIds).toEqual(['11'])
  })

  it('un % de línea menor que la promo se toma como descuento habitual: la promo se espera entera', () => {
    // 50 × 3000 × 1 % = 1500 < 6000 → no la cubre.
    const conBonif = lineas.map(l => (l.lineaId === 1 ? { ...l, bonificacion: 1 } : l))
    expect(sugerirBonificaciones({ ...base, lineas: conBonif })[0].monto).toBe(-9600)
  })

  it('todas las líneas cubiertas por su %: no sugiere', () => {
    const conBonif = lineas.map(l => ({ ...l, bonificacion: 20 }))
    expect(sugerirBonificaciones({ ...base, lineas: conBonif })).toEqual([])
  })

  it('porcentaje: sobre el neto ya bonificado, con base monto', () => {
    const promos = [promoBulto({ tipo: 'porcentaje', montoPorUnidad: null, porcentaje: 0.5 })]
    const conBonif = lineas.map(l => (l.lineaId === 2 ? { ...l, bonificacion: 0.1 } : l))
    const [s] = sugerirBonificaciones({ ...base, lineas: conBonif, promos })
    // Línea 1: 150000 × 0,5 % = 750. Línea 2: 84000 × 0,999 = 83916 × 0,5 % = 419,58.
    expect(s.monto).toBe(-1169.58)
    expect(s.base).toBe('monto')
    expect(s.pesos).toEqual({ 1: 150000, 2: 83916, 3: 0, 4: 0 })
  })

  it('vigencia: fuera de rango, inactiva o sin productos no sugiere', () => {
    expect(sugerirBonificaciones({ ...base, fechaCompra: '2025-12-31' })).toEqual([])
    expect(sugerirBonificaciones({ ...base, fechaCompra: '2027-01-01' })).toEqual([])
    expect(sugerirBonificaciones({ ...base, promos: [promoBulto({ activo: false })] })).toEqual([])
    expect(sugerirBonificaciones({ ...base, promos: [promoBulto({ productoIds: [] })] })).toEqual([])
    // Extremos inclusive.
    expect(sugerirBonificaciones({ ...base, fechaCompra: '2026-01-01' })).toHaveLength(1)
    expect(sugerirBonificaciones({ ...base, fechaCompra: '2026-12-31' })).toHaveLength(1)
  })

  it('promoVigente acepta extremos abiertos', () => {
    expect(promoVigente(promoBulto({ vigenteDesde: null, vigenteHasta: null }), '2030-01-01')).toBe(true)
    expect(promoVigente(promoBulto({ vigenteDesde: '2026-07-01', vigenteHasta: null }), '2026-06-30')).toBe(false)
  })

  it('no re-sugiere una promo aplicada (cargo con su marca) ni una descartada', () => {
    const aplicada: CargoParaSugerencia[] = [{ monto: -1, pesos: {}, sugerencia: { promoId: '7' } }]
    expect(sugerirBonificaciones({ ...base, cargos: aplicada })).toEqual([])
    expect(sugerirBonificaciones({ ...base, descartadas: ['7'] })).toEqual([])
  })

  it('evalúa cada promo por separado', () => {
    const promos = [promoBulto(), promoBulto({ id: '8', nombre: 'Promo jugos', productoIds: ['21'], montoPorUnidad: 50 })]
    const s = sugerirBonificaciones({ ...base, promos })
    expect(s.map(x => [x.promoId, x.monto])).toEqual([['7', -9600], ['8', -500]])
  })

  it('una promo mal cargada (sin monto) no sugiere ni rompe', () => {
    const promos = [promoBulto({ montoPorUnidad: null })]
    expect(sugerirBonificaciones({ ...base, promos })).toEqual([])
  })
})
