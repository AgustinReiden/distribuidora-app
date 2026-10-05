import { describe, it, expect } from 'vitest'
import {
  alcanceBonificacionAnterior,
  detectarBonificacionNoDescontada,
  toleranciaCoincidenciaBonif,
  type EntradaBonificacion,
  type LineaBonificable,
} from './detectarBonificacionNoDescontada'
import { calcularCostosCompra, type CargoCompra } from './prorrateoCompra'
import { redondearSQL } from './calculations'
import type { CargoPlantillaCompra } from '../types'

// Datos SINTÉTICOS (el repo es público). La forma copia la de las dos facturas
// de referencia (463263 y 461415): alícuotas mezcladas —8,6957%, 4,1667%, 0% y
// exento— y una bonificación de promoción que toca sólo ALGUNAS líneas del
// 8,6957%, liquidada por el proveedor sin bajar la base del II.

const T_ALTA = 8.6957
const T_BAJA = 4.1667

const L = (over: Partial<LineaBonificable> & Pick<LineaBonificable, 'id' | 'productoId'>): LineaBonificable => ({
  cantidad: 1, costoUnitario: 0, bonificacion: 0, impuestosInternos: 0,
  porcentajeIva: 21, condicionIva: 'gravado', ...over,
})

/** Factura tipo 461415: seis renglones en cuatro "baldes". */
const LINEAS: LineaBonificable[] = [
  L({ id: 1, productoId: 'cola-3l',    cantidad: 100, costoUnitario: 5000, impuestosInternos: T_ALTA }), // promo
  L({ id: 2, productoId: 'naranja-3l', cantidad: 50,  costoUnitario: 4000, impuestosInternos: T_ALTA }), // promo
  L({ id: 3, productoId: 'cola-600',   cantidad: 80,  costoUnitario: 4500, impuestosInternos: T_ALTA }), // sin promo
  L({ id: 4, productoId: 'lima-600',   cantidad: 60,  costoUnitario: 4000, impuestosInternos: T_BAJA }),
  L({ id: 5, productoId: 'soda-2l',    cantidad: 40,  costoUnitario: 1500, impuestosInternos: 0 }),
  L({ id: 6, productoId: 'pindapoy-1l', cantidad: 30, costoUnitario: 3000, impuestosInternos: 0, condicionIva: 'exento', porcentajeIva: 0 }),
]

const neto = (l: LineaBonificable) => l.cantidad * l.costoUnitario * (1 - l.bonificacion / 100)
const netoDe = (ids: number[]) => LINEAS.filter(l => ids.includes(l.id)).reduce((a, l) => a + neto(l), 0)

/** La bonificación de la promo: 35.000 sobre los 3L. */
const BONIF = 35_000
/** Lo que el proveedor declara: II sobre el neto ANTES de la bonificación. */
const II_DECLARADO: Record<number, number> = {
  [T_ALTA]: redondearSQL((netoDe([1, 2, 3]) + BONIF) * T_ALTA / 100, 2),
  [T_BAJA]: redondearSQL(netoDe([4]) * T_BAJA / 100, 2),
}

const GRAVADO_LINEAS = netoDe([1, 2, 3, 4, 5]) // 1.360.000: Pindapoy es exento

/** La bonificación tal como la cargaría quien la conoce. */
const cargoBonif = (monto: number, ids: number[], over: Partial<CargoCompra> = {}): CargoCompra => ({
  id: 1, concepto: 'Bonificación', monto, condicionIva: 'gravado', enFactura: true,
  prorrateaAlCosto: true, afectaBaseII: false,
  pesos: Object.fromEntries(LINEAS.map(l => [l.id, ids.includes(l.id) ? neto(l) : 0])),
  ...over,
})

const entrada = (over: Partial<EntradaBonificacion> = {}): EntradaBonificacion => ({
  lineas: LINEAS, cargos: [], iiDeclarado: II_DECLARADO, ...over,
})

describe('detectarBonificacionNoDescontada · la detección', () => {
  it('con el gravado impreso, detecta el monto EXACTO y en la alícuota correcta', () => {
    const r = detectarBonificacionNoDescontada(entrada({
      control: { gravadoImpreso: GRAVADO_LINEAS - BONIF, gravadoCalculado: GRAVADO_LINEAS, totalImpreso: 0, totalCalculado: 0 },
    }))
    expect(r).toHaveLength(1)
    expect(r[0].tasa).toBe(T_ALTA)
    expect(r[0].monto).toBe(BONIF)
    expect(r[0].origenMonto).toBe('gravado')
    // La base que el II implica de más es la misma, salvo el redondeo del II.
    expect(Math.abs(r[0].baseImplicita - BONIF)).toBeLessThan(0.2)
    // Sin compra anterior: todas las líneas del 8,6957%, ninguna otra.
    expect(r[0].lineaIds).toEqual([1, 2, 3])
    expect(r[0].alcance).toBe('alicuota')
  })

  it('con sólo el II, el monto es la base implícita (al redondeo del II dividido por la tasa)', () => {
    const r = detectarBonificacionNoDescontada(entrada())
    expect(r).toHaveLength(1)
    expect(r[0].origenMonto).toBe('impuesto_interno')
    // Medio centavo de II al 8,6957% son ~6 centavos de base.
    expect(Math.abs(r[0].monto - BONIF)).toBeLessThan(0.1)
  })

  it('con sólo el total impreso, saca el IVA de la brecha y llega al mismo monto', () => {
    const r = detectarBonificacionNoDescontada(entrada({
      control: { gravadoImpreso: 0, gravadoCalculado: GRAVADO_LINEAS, totalImpreso: 1_000_000, totalCalculado: 1_000_000 + BONIF * 1.21 },
    }))
    expect(r).toHaveLength(1)
    expect(r[0].origenMonto).toBe('total')
    expect(r[0].monto).toBeCloseTo(BONIF, 2)
  })

  it('una vez agregada la bonificación, no sugiere nada', () => {
    const r = detectarBonificacionNoDescontada(entrada({
      cargos: [cargoBonif(-BONIF, [1, 2])],
      control: { gravadoImpreso: GRAVADO_LINEAS - BONIF, gravadoCalculado: GRAVADO_LINEAS - BONIF, totalImpreso: 0, totalCalculado: 0 },
    }))
    expect(r).toEqual([])
  })

  it('una bonificación ya cargada que explica sólo una parte deja sugerir el resto', () => {
    const r = detectarBonificacionNoDescontada(entrada({ cargos: [cargoBonif(-20_000, [1, 2])] }))
    expect(r).toHaveLength(1)
    expect(Math.abs(r[0].monto - 15_000)).toBeLessThan(0.1)
  })

  it('si el II declarado cuadra, no sugiere nada', () => {
    const r = detectarBonificacionNoDescontada(entrada({
      iiDeclarado: { [T_ALTA]: redondearSQL(netoDe([1, 2, 3]) * T_ALTA / 100, 2), [T_BAJA]: II_DECLARADO[T_BAJA] },
    }))
    expect(r).toEqual([])
  })

  it('una diferencia NEGATIVA (declarado < calculado) no es este caso', () => {
    const r = detectarBonificacionNoDescontada(entrada({
      iiDeclarado: { [T_ALTA]: redondearSQL((netoDe([1, 2, 3]) - BONIF) * T_ALTA / 100, 2) },
    }))
    expect(r).toEqual([])
  })

  it('sin II declarado no hay nada que deducir', () => {
    expect(detectarBonificacionNoDescontada(entrada({ iiDeclarado: {} }))).toEqual([])
  })

  it('una factura sólo de soda y Pindapoy (0% y exento) no sugiere nada', () => {
    const r = detectarBonificacionNoDescontada({
      lineas: LINEAS.filter(l => l.id >= 5),
      cargos: [],
      // Aunque alguien tipee un declarado: ninguna línea tiene esa alícuota.
      iiDeclarado: { [T_ALTA]: 5_000 },
      control: { gravadoImpreso: 25_000, gravadoCalculado: 60_000, totalImpreso: 0, totalCalculado: 0 },
    })
    expect(r).toEqual([])
  })

  it('si el papel contradice al II (las líneas ya traen la bonificación), no sugiere nada', () => {
    // El gravado impreso es el de las líneas: agregar la bonificación la
    // descontaría dos veces.
    const r = detectarBonificacionNoDescontada(entrada({
      control: { gravadoImpreso: GRAVADO_LINEAS, gravadoCalculado: GRAVADO_LINEAS, totalImpreso: 0, totalCalculado: 0 },
    }))
    expect(r).toEqual([])
  })

  it('en ZZ (tasas de II en 0 por lineaParaMotor) no hay alícuotas: nada', () => {
    const r = detectarBonificacionNoDescontada(entrada({ lineas: LINEAS.map(l => ({ ...l, impuestosInternos: 0 })) }))
    expect(r).toEqual([])
  })

  it('un peso corrupto no revienta: devuelve vacío y el error lo muestra la vista previa', () => {
    const r = detectarBonificacionNoDescontada(entrada({ cargos: [cargoBonif(-1, [1], { pesos: { 1: -5 } })] }))
    expect(r).toEqual([])
  })
})

describe('detectarBonificacionNoDescontada · el alcance', () => {
  it('prefiere el alcance de la compra anterior, cortado con las líneas de la alícuota', () => {
    // La compra anterior la repartía entre los 3L y la soda: la soda (0%) se cae.
    const r = detectarBonificacionNoDescontada(entrada({ alcanceAnterior: ['cola-3l', 'naranja-3l', 'soda-2l'] }))
    expect(r[0].lineaIds).toEqual([1, 2])
    expect(r[0].alcance).toBe('compra_anterior')
  })

  it('si la compra anterior no toca ninguna línea de la alícuota, usa la alícuota entera', () => {
    const r = detectarBonificacionNoDescontada(entrada({ alcanceAnterior: ['soda-2l', 'otro'] }))
    expect(r[0].lineaIds).toEqual([1, 2, 3])
    expect(r[0].alcance).toBe('alicuota')
  })

  it('NUNCA incluye líneas de otras alícuotas, del 0% ni exentas', () => {
    const r = detectarBonificacionNoDescontada(entrada({
      alcanceAnterior: LINEAS.map(l => l.productoId),
    }))
    for (const s of r) {
      for (const id of s.lineaIds) {
        const l = LINEAS.find(x => x.id === id)!
        expect(l.impuestosInternos).toBe(s.tasa)
        expect(l.condicionIva).toBe('gravado')
      }
    }
  })
})

describe('detectarBonificacionNoDescontada · varias alícuotas (tipo 463263)', () => {
  const BONIF_BAJA = 12_000
  const declarado = {
    [T_ALTA]: II_DECLARADO[T_ALTA],
    [T_BAJA]: redondearSQL((netoDe([4]) + BONIF_BAJA) * T_BAJA / 100, 2),
  }

  it('una sugerencia por alícuota', () => {
    const r = detectarBonificacionNoDescontada(entrada({ iiDeclarado: declarado }))
    expect(r.map(s => s.tasa)).toEqual([T_BAJA, T_ALTA])
    expect(Math.abs(r[0].monto - BONIF_BAJA)).toBeLessThan(0.2)
    expect(r[0].lineaIds).toEqual([4])
    expect(Math.abs(r[1].monto - BONIF)).toBeLessThan(0.1)
  })

  it('con el gravado impreso, la brecha se reparte y las dos suman el papel al centavo', () => {
    const brecha = BONIF + BONIF_BAJA
    const r = detectarBonificacionNoDescontada(entrada({
      iiDeclarado: declarado,
      control: { gravadoImpreso: GRAVADO_LINEAS - brecha, gravadoCalculado: GRAVADO_LINEAS, totalImpreso: 0, totalCalculado: 0 },
    }))
    expect(r).toHaveLength(2)
    expect(r[0].monto + r[1].monto).toBeCloseTo(brecha, 1)
    expect(Math.abs(r[0].monto - BONIF_BAJA)).toBeLessThan(1)
    expect(Math.abs(r[1].monto - BONIF)).toBeLessThan(1)
  })

  it('si sólo falta la de una alícuota, la otra no aparece', () => {
    const r = detectarBonificacionNoDescontada(entrada({
      iiDeclarado: declarado,
      cargos: [cargoBonif(-BONIF, [1, 2])],
    }))
    expect(r.map(s => s.tasa)).toEqual([T_BAJA])
  })
})

describe('la tolerancia de coincidencia', () => {
  it('piso de $2 de II más un centavo por línea', () => {
    expect(toleranciaCoincidenciaBonif(100_000, 3)).toBeCloseTo(2.03, 6)
  })

  it('en una factura grande manda la parte relativa', () => {
    expect(toleranciaCoincidenciaBonif(10_000_000, 10)).toBeCloseTo(10.1, 6)
  })

  it('el fixture cierra holgado: el II del proveedor y el papel coinciden', () => {
    // Medida de control sobre el propio fixture: la diferencia entre la base
    // implícita y la bonificación real queda muy por debajo de la tolerancia.
    const sin = calcularCostosCompra(LINEAS, [], {})
    const ii = LINEAS.reduce((a, l, i) => a + (l.impuestosInternos === T_ALTA ? sin.lineas[i].iiUnitario * l.cantidad : 0), 0)
    const implicita = (II_DECLARADO[T_ALTA] - ii) / (T_ALTA / 100)
    expect(Math.abs(implicita - BONIF) * T_ALTA / 100).toBeLessThan(toleranciaCoincidenciaBonif(netoDe([1, 2, 3]), 3))
  })
})

describe('alcanceBonificacionAnterior', () => {
  const plantilla = (over: Partial<CargoPlantillaCompra>): CargoPlantillaCompra => ({
    concepto: 'Flete', condicionIva: 'no_gravado', enFactura: false, prorrateaAlCosto: true,
    afectaBaseII: false, baseProrrateo: 'monto', pesosPorProducto: {}, ...over,
  })

  it('toma los productos con peso de la bonificación comercial', () => {
    expect(alcanceBonificacionAnterior([
      plantilla({ concepto: 'Flete', pesosPorProducto: { a: 1, b: 1 } }),
      plantilla({ concepto: 'Bonif. promo 3L', condicionIva: 'gravado', pesosPorProducto: { a: 10, c: 0 } }),
    ])).toEqual(['a'])
  })

  it('prefiere la que no baja la base del II a un descuento de precio', () => {
    expect(alcanceBonificacionAnterior([
      plantilla({ concepto: 'Bonificación precio', condicionIva: 'gravado', afectaBaseII: true, pesosPorProducto: { x: 1 } }),
      plantilla({ concepto: 'Bonificación', condicionIva: 'gravado', afectaBaseII: false, pesosPorProducto: { y: 1 } }),
    ])).toEqual(['y'])
  })

  it('sin bonificación en la compra anterior: null', () => {
    expect(alcanceBonificacionAnterior([plantilla({ pesosPorProducto: { a: 1 } })])).toBeNull()
    expect(alcanceBonificacionAnterior(null)).toBeNull()
  })
})
