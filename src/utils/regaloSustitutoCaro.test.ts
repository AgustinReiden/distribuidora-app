import { describe, it, expect } from 'vitest'
import { regaloSustitutoCaro, type RegaloSustitutoCaroArgs } from './regaloSustitutoCaro'

// Promo 2 V → 1 R, R a $ 100. Un admin cambió R×10 por X×1 (X a $ 1.000, otro rubro) o por
// W×1 (W a $ 1.000, el mismo rubro). Los casos del ensayo de la migración (P3).
const R = { id: 1, precio: 100, categoria: 'Gaseosas' }
const X = { id: 2, precio: 1000, categoria: 'Snacks' }
const W = { id: 3, precio: 1000, categoria: 'Gaseosas' }
const base: RegaloSustitutoCaroArgs = {
  esAdmin: false, regalo: R, sustituto: X, corteNuevo: 1, corteGuardado: 10, cantidadSustituto: 1, porLinea: true,
}

describe('regaloSustitutoCaro (H1 de la revisión de C2, decisión del dueño del 19/11)', () => {
  it.each([
    ['baja a R×5 (S2c)', { corteNuevo: 5 }, true],
    ['baja a R×1 (S2d)', { corteNuevo: 1 }, true],
    ['manda X×2, que se lee R×2 (S1n)', { corteNuevo: 2 }, true],
    ['no baja lo que da la promo (R×10)', { corteNuevo: 10 }, false],
    ['sube la venta (R×15, X×2)', { corteNuevo: 15, cantidadSustituto: 2 }, false],
    ['el mismo rubro (W×1 por R×1)', { sustituto: W }, false],
    ['el admin', { esAdmin: true }, false],
    ['una promo de fracción (lo decide el server)', { porLinea: false }, false],
    ['sin el corte guardado', { corteGuardado: null }, false],
    ['sin línea guardada: el regalo se cayó y vuelve (cuenta como que bajó)', { corteGuardado: Number.POSITIVE_INFINITY }, true],
    ['con el corte guardado en 5 y la promo da 7 (no bajó)', { corteGuardado: 5, corteNuevo: 7 }, false],
    ['un sustituto que alcanza por valor (X a $ 100)', { sustituto: { ...X, precio: 100 } }, false],
    ['sin el precio del sustituto (avisa el server)', { sustituto: { ...X, precio: null } }, false],
  ] as const)('%s', (_caso, cambio, esperado) => {
    expect(regaloSustitutoCaro({ ...base, ...cambio })).toBe(esperado)
  })
})
