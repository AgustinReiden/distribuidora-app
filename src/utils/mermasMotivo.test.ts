import { describe, it, expect } from 'vitest'
import {
  LABELS_MOTIVO,
  LABELS_CLASIFICACION,
  labelMotivo,
  labelClasificacion,
  esAjustePromocion,
} from './mermasMotivo'

/** Los 10 valores del CHECK vivo de `mermas_stock` (verificado en prod, mig 226). */
const MOTIVOS_DEL_CHECK = [
  'rotura',
  'vencimiento',
  'robo',
  'decomiso',
  'devolucion',
  'error_inventario',
  'muestra',
  'otro',
  'promociones',
  'promociones_reversion',
]

describe('labelMotivo', () => {
  it('los 10 motivos del CHECK vivo tienen etiqueta propia', () => {
    for (const motivo of MOTIVOS_DEL_CHECK) {
      expect(LABELS_MOTIVO[motivo], `falta etiqueta para "${motivo}"`).toBeTruthy()
    }
    expect(Object.keys(LABELS_MOTIVO)).toHaveLength(MOTIVOS_DEL_CHECK.length)
  })

  it('ningún motivo se renderiza crudo: nunca sale un guion bajo', () => {
    // Era el bug del modal: `promociones_reversion` caía al fallback y se
    // mostraba tal cual viene de la base.
    for (const motivo of MOTIVOS_DEL_CHECK) {
      expect(labelMotivo(motivo)).not.toContain('_')
    }
    expect(labelMotivo('promociones_reversion')).toBe('Reversión de promoción')
  })

  it('un motivo desconocido cae al fallback en vez de romper', () => {
    expect(labelMotivo('motivo_que_no_existe')).toBe('motivo_que_no_existe')
  })

  it("'(sin motivo)' pasa tal cual: ya viene legible del RPC", () => {
    expect(labelMotivo('(sin motivo)')).toBe('(sin motivo)')
  })
})

describe('labelClasificacion', () => {
  it('las cuatro clasificaciones del RPC tienen etiqueta', () => {
    expect(Object.keys(LABELS_CLASIFICACION).sort()).toEqual([
      'ajuste',
      'muestra',
      'perdida',
      'promocion',
    ])
  })

  it("'promocion' se lee como ajuste, no como pérdida", () => {
    // Que el nombre en pantalla diga que no es una pérdida es la mitad de la
    // explicación de por qué no suma al total.
    expect(labelClasificacion('promocion')).toBe('Ajuste de promoción')
  })

  it('una clasificación desconocida cae al fallback', () => {
    expect(labelClasificacion('otra_cosa')).toBe('otra_cosa')
  })
})

describe('esAjustePromocion', () => {
  it('sólo la clasificación promocion queda fuera del total', () => {
    expect(esAjustePromocion('promocion')).toBe(true)
    expect(esAjustePromocion('perdida')).toBe(false)
    expect(esAjustePromocion('ajuste')).toBe(false)
    expect(esAjustePromocion('muestra')).toBe(false)
  })
})
