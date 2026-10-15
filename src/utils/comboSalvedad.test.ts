import { describe, it, expect } from 'vitest'
import {
  cambioDelTotal,
  combosRotos,
  esLineaDeCombo,
  motivoRompeCombo,
  normalizarImpactoCombos,
  productosQueSalen,
  productosQueVuelven,
  recargoTotal,
  type ComboImpactoSalvedad,
} from './comboSalvedad'

// El ejemplo de #1192: Fernet 10.000 + Coca 2.500, combo a 9.800 (Fernet 7.840,
// Coca 1.960). El cliente rechaza la Coca: el Fernet vuelve a 10.000.
const FERNET_COCA: ComboImpactoSalvedad = {
  combo_id: 7,
  nombre: 'Fernet + Coca',
  combos_antes: 1,
  combos_despues: 0,
  recargo: 2160,
  productos: [
    { producto_id: 1, nombre: 'Fernet', fuera_antes: 0, fuera_despues: 1, precio_combo: 7840, precio_sin_combo: 10000 },
    { producto_id: 2, nombre: 'Coca', fuera_antes: 0, fuera_despues: 0, precio_combo: 1960, precio_sin_combo: 2500 },
  ],
}

describe('comboSalvedad (#1192)', () => {
  it('una línea es de combo si va en uno o si salió de uno roto', () => {
    expect(esLineaDeCombo({ combo_id: '7' })).toBe(true)
    expect(esLineaDeCombo({ combo_roto_id: '7' })).toBe(true)
    expect(esLineaDeCombo({ combo_id: null, combo_roto_id: null })).toBe(false)
    expect(esLineaDeCombo({})).toBe(false)
  })

  it('sólo cliente_rechaza rompe el combo: los motivos nuestros y los dudosos mantienen el precio', () => {
    expect(motivoRompeCombo('cliente_rechaza')).toBe(true)
    for (const m of ['faltante_stock', 'producto_danado', 'producto_vencido', 'error_pedido',
      'entregado_otro_cliente', 'diferencia_precio', 'otro', '', null, undefined]) {
      expect(motivoRompeCombo(m)).toBe(false)
    }
  })

  it('el ejemplo del issue: rechazar la Coca descuenta 1.960 y el recargo es 2.160, el total sube 200', () => {
    expect(recargoTotal([FERNET_COCA])).toBe(2160)
    expect(cambioDelTotal(1960, 2160)).toBe(200)
    expect(combosRotos([FERNET_COCA])).toHaveLength(1)
    expect(productosQueSalen(FERNET_COCA)).toEqual([
      expect.objectContaining({ nombre: 'Fernet', unidades: 1, precio_sin_combo: 10000 }),
    ])
  })

  it('el recargo suma varios combos en centavos exactos, y puede ser negativo', () => {
    const otro = { ...FERNET_COCA, combo_id: 8, recargo: 0.1 }
    const vuelve = { ...FERNET_COCA, combo_id: 9, recargo: -540.2 }
    expect(recargoTotal([FERNET_COCA, otro, vuelve])).toBe(1619.9)
    expect(recargoTotal([])).toBe(0)
  })

  it('un combo que no pierde combos no está roto, aunque algo vuelva a él', () => {
    const rearmado: ComboImpactoSalvedad = {
      ...FERNET_COCA,
      combos_antes: 1,
      combos_despues: 1,
      recargo: -540,
      productos: [
        { producto_id: 2, nombre: 'Coca', fuera_antes: 1, fuera_despues: 0, precio_combo: 1960, precio_sin_combo: 2500 },
      ],
    }
    expect(combosRotos([rearmado])).toHaveLength(0)
    expect(productosQueVuelven(rearmado)).toEqual([expect.objectContaining({ nombre: 'Coca', unidades: 1 })])
    expect(productosQueSalen(rearmado)).toHaveLength(0)
  })

  it('normaliza lo que devuelve la RPC (números como string, nulls, basura)', () => {
    expect(normalizarImpactoCombos(null)).toEqual([])
    expect(normalizarImpactoCombos({})).toEqual([])
    expect(normalizarImpactoCombos([{
      combo_id: '7', nombre: 'Fernet + Coca', combos_antes: '2', combos_despues: 1, recargo: '2160.00',
      productos: [{ producto_id: '1', nombre: null, fuera_antes: 0, fuera_despues: '1', precio_combo: '7840', precio_sin_combo: null }],
    }])).toEqual([{
      combo_id: 7, nombre: 'Fernet + Coca', combos_antes: 2, combos_despues: 1, recargo: 2160,
      productos: [{ producto_id: 1, nombre: null, fuera_antes: 0, fuera_despues: 1, precio_combo: 7840, precio_sin_combo: null }],
    }])
  })
})
