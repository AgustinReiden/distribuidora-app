import { describe, it, expect } from 'vitest'
import { alertasCombosParaReporte, costoValuacion, evaluarCombo, type ComboParaAlertas, type ProductoParaAlertas } from './comboAlertas'

// El ejemplo de #1190: Fernet $10.000 (costo 8.000) + Coca $2.500 (costo 1.500).
// Precios sin IVA iguales al final para que las cuentas se lean a ojo.
const FERNET: ProductoParaAlertas = { id: 10, nombre: 'Fernet', precio: 10000, precio_sin_iva: 10000, costo_promedio: 8000 }
const COCA: ProductoParaAlertas = { id: 11, nombre: 'Coca', precio: 2500, precio_sin_iva: 2500, costo_promedio: 1500 }
const SPRITE: ProductoParaAlertas = { id: 12, nombre: 'Sprite', precio: 2300, precio_sin_iva: 2300, costo_promedio: 1800 }

const mapa = (...ps: ProductoParaAlertas[]) => new Map(ps.map(p => [String(p.id), p]))
const UMBRALES = { margenMinimoPct: 10, descuentoMaximoPct: 30 }

const combo = (precio: number, extra: Partial<ComboParaAlertas> = {}): ComboParaAlertas => ({
  id: '500',
  nombre: 'Fernet + Coca',
  precio,
  componentes: [{ cantidad: 1, productos: ['10'] }, { cantidad: 1, productos: ['11'] }],
  ...extra,
})

describe('evaluarCombo', () => {
  it('el ejemplo de #1190 a $11.000: 12% de descuento y margen 1.500 sobre 11.000, sin alertas', () => {
    const ev = evaluarCombo(combo(11000), mapa(FERNET, COCA), UMBRALES, true)
    expect(ev.sinCombo).toBe(12500)
    expect(ev.descuentoPct).toBeCloseTo(12, 6)
    expect(ev.costo).toBe(9500)
    expect(ev.margenPct).toBeCloseTo((1500 / 11000) * 100, 6)
    expect(ev.alertas).toEqual([])
  })

  it('a $9.800 el margen queda debajo del tope', () => {
    const ev = evaluarCombo(combo(9800), mapa(FERNET, COCA), UMBRALES, true)
    expect(ev.margenPct).toBeCloseTo((300 / 9800) * 100, 6)
    expect(ev.alertas.map(a => a.tipo)).toEqual(['margen_bajo'])
  })

  it('bajo costo es margen negativo y crítico', () => {
    const ev = evaluarCombo(combo(9000), mapa(FERNET, COCA), UMBRALES, true)
    expect(ev.margenPct).toBeLessThan(0)
    expect(ev.alertas).toEqual([expect.objectContaining({ tipo: 'margen_negativo', severidad: 'critical' })])
  })

  it('descuento por encima del tope', () => {
    const ev = evaluarCombo(combo(8000), mapa(
      { ...FERNET, costo_promedio: 4000 }, { ...COCA, costo_promedio: 1000 }), UMBRALES, true)
    expect(ev.descuentoPct).toBeCloseTo(36, 6)
    expect(ev.alertas.map(a => a.tipo)).toEqual(['descuento_alto'])
  })

  it('"no conviene": el precio fijo no le gana a comprar por separado', () => {
    const ev = evaluarCombo(combo(12500), mapa(FERNET, COCA), UMBRALES, true)
    expect(ev.noConviene).toBe(true)
    expect(ev.descuentoPct).toBeNull()
    expect(ev.alertas.map(a => a.tipo)).toContain('no_conviene')
  })

  it('un componente sin costo da "sin costo", no un margen calculado (#511)', () => {
    const ev = evaluarCombo(combo(11000), mapa(FERNET, { ...COCA, costo_promedio: null }), UMBRALES, true)
    expect(ev.costo).toBeNull()
    expect(ev.margenPct).toBeNull()
    expect(ev.sinCosto).toEqual(['Coca'])
    expect(ev.alertas.map(a => a.tipo)).toEqual(['sin_costo'])
  })

  it('un costo 0 cargado es un valor y corta la cascada, como en SQL', () => {
    const ev = evaluarCombo(combo(11000), mapa(FERNET, { ...COCA, costo_promedio: 0 }), UMBRALES, true)
    expect(ev.costo).toBe(8000)
    expect(ev.sinCosto).toEqual([])
  })

  it('sin permiso para ver costos: ni margen ni "sin costo", pero sí el descuento', () => {
    const ev = evaluarCombo(combo(8000), mapa(
      { id: 10, precio: 10000, precio_sin_iva: 10000 }, { id: 11, precio: 2500, precio_sin_iva: 2500 }), UMBRALES, false)
    expect(ev.margenPct).toBeNull()
    expect(ev.costo).toBeNull()
    expect(ev.alertas.map(a => a.tipo)).toEqual(['descuento_alto'])
  })

  it('margen sobre la venta sin IVA: lleva el precio del combo a neto con la proporción de las listas', () => {
    const conIva = mapa({ ...FERNET, precio: 12100 }, { ...COCA, precio: 3025 })
    // Listas al 21%: el combo a $13.310 final son $11.000 netos.
    const ev = evaluarCombo(combo(13310), conIva, UMBRALES, true)
    expect(ev.margenPct).toBeCloseTo((1500 / 11000) * 100, 6)
  })

  it('con alternativas: precio de la más cara y costo de la que menos deja', () => {
    const conAlternativa = combo(11000, {
      componentes: [{ cantidad: 1, productos: ['10'] }, { cantidad: 1, productos: ['11', '12'] }],
    })
    const ev = evaluarCombo(conAlternativa, mapa(FERNET, COCA, SPRITE), UMBRALES, true)
    expect(ev.sinCombo).toBe(12500)
    expect(ev.costo).toBe(9800)
  })

  it('cuenta la cantidad de cada lugar', () => {
    const dosCocas = combo(14000, { componentes: [{ cantidad: 1, productos: ['10'] }, { cantidad: 2, productos: ['11'] }] })
    const ev = evaluarCombo(dosCocas, mapa(FERNET, COCA), UMBRALES, true)
    expect(ev.sinCombo).toBe(15000)
    expect(ev.costo).toBe(11000)
  })
})

describe('costoValuacion', () => {
  it('cae por la cascada y devuelve null sin ningún término', () => {
    expect(costoValuacion({ costo_promedio: null, costo_real: 5 })).toBe(5)
    expect(costoValuacion({ costo_sin_iva: 100, impuestos_internos: 10 })).toBe(110)
    expect(costoValuacion({})).toBeNull()
    expect(costoValuacion(undefined)).toBeNull()
  })
})

describe('alertasCombosParaReporte', () => {
  it('una alerta por combo y tipo, con código único y las críticas primero', () => {
    const r = alertasCombosParaReporte(
      [combo(9800), combo(9000, { id: '501', nombre: 'Barato' })],
      mapa(FERNET, COCA), UMBRALES, true)
    expect(r.map(a => a.codigo)).toEqual(['combo_margen_negativo_501', 'combo_margen_bajo_500'])
    expect(r[0]).toMatchObject({ severidad: 'critical', titulo: 'Combo Barato', seccion: 'combos' })
  })
})
