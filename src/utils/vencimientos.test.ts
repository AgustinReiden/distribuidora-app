import { describe, expect, it } from 'vitest'
import {
  aplanarVencimientos,
  bolsaSinVencimiento,
  diasHasta,
  estadoVencimiento,
  formatearFechaVencimiento,
  textoVencimiento,
} from './vencimientos'

const HOY = '2026-09-09'

describe('diasHasta', () => {
  it('cuenta días de calendario hacia adelante', () => {
    expect(diasHasta('2026-09-10', HOY)).toBe(1)
    expect(diasHasta('2026-10-09', HOY)).toBe(30)
  })

  it('devuelve 0 el mismo día', () => {
    expect(diasHasta(HOY, HOY)).toBe(0)
  })

  it('devuelve negativo si ya pasó', () => {
    expect(diasHasta('2026-09-01', HOY)).toBe(-8)
  })

  it('cruza el cambio de año y los bisiestos sin corrimiento', () => {
    expect(diasHasta('2027-01-01', '2026-12-31')).toBe(1)
    // 2028 es bisiesto: febrero tiene 29.
    expect(diasHasta('2028-03-01', '2028-02-01')).toBe(29)
  })

  it('NO se corre un día por la zona horaria', () => {
    // El bug clásico: new Date('2026-10-01') es medianoche UTC, o sea el 30/09
    // a las 21:00 en Argentina. Si esto diera 0, el lote se marcaría vencido un
    // día antes de tiempo.
    expect(diasHasta('2026-10-01', '2026-10-01')).toBe(0)
    expect(diasHasta('2026-01-01', '2025-12-31')).toBe(1)
  })

  it('devuelve NaN con una fecha ilegible, no 0', () => {
    expect(diasHasta('', HOY)).toBeNaN()
    expect(diasHasta('mañana', HOY)).toBeNaN()
  })

  it('tolera un timestamp completo, no solo la fecha suelta', () => {
    expect(diasHasta('2026-09-10T00:00:00Z', HOY)).toBe(1)
  })
})

describe('estadoVencimiento', () => {
  const ALERTA = 60
  const CRITICO = 15

  it('marca vencido lo que ya pasó', () => {
    expect(estadoVencimiento('2026-09-08', ALERTA, CRITICO, HOY)).toBe('vencido')
  })

  it('el día del vencimiento todavía no está vencido', () => {
    expect(estadoVencimiento(HOY, ALERTA, CRITICO, HOY)).toBe('critico')
  })

  it('los umbrales son inclusivos', () => {
    // Justo en el umbral rojo.
    expect(estadoVencimiento('2026-09-24', ALERTA, CRITICO, HOY)).toBe('critico')
    // Un día más allá del rojo, todavía dentro del amarillo.
    expect(estadoVencimiento('2026-09-25', ALERTA, CRITICO, HOY)).toBe('alerta')
    // Justo en el umbral amarillo.
    expect(estadoVencimiento('2026-11-08', ALERTA, CRITICO, HOY)).toBe('alerta')
    // Un día más allá del amarillo.
    expect(estadoVencimiento('2026-11-09', ALERTA, CRITICO, HOY)).toBe('ok')
  })

  it('con los dos umbrales en 0 solo marca lo ya vencido', () => {
    expect(estadoVencimiento('2026-09-08', 0, 0, HOY)).toBe('vencido')
    expect(estadoVencimiento(HOY, 0, 0, HOY)).toBe('critico')
    expect(estadoVencimiento('2026-09-10', 0, 0, HOY)).toBe('ok')
  })

  it('con los dos umbrales iguales no queda ningún amarillo', () => {
    expect(estadoVencimiento('2026-09-20', 15, 15, HOY)).toBe('critico')
    expect(estadoVencimiento('2026-09-25', 15, 15, HOY)).toBe('ok')
  })

  it('una fecha ilegible no inventa una alarma', () => {
    expect(estadoVencimiento('', ALERTA, CRITICO, HOY)).toBe('ok')
  })
})

describe('textoVencimiento', () => {
  it('singulariza el día', () => {
    expect(textoVencimiento('2026-09-10', HOY)).toBe('vence en 1 día')
    expect(textoVencimiento('2026-09-08', HOY)).toBe('vencido hace 1 día')
  })

  it('pluraliza a partir de dos', () => {
    expect(textoVencimiento('2026-09-11', HOY)).toBe('vence en 2 días')
    expect(textoVencimiento('2026-09-07', HOY)).toBe('vencido hace 2 días')
  })

  it('el mismo día no dice "en 0 días"', () => {
    expect(textoVencimiento(HOY, HOY)).toBe('vence hoy')
  })
})

describe('bolsaSinVencimiento', () => {
  it('es el stock menos lo asignado a lotes', () => {
    expect(bolsaSinVencimiento(100, 30)).toBe(70)
  })

  it('es 0 cuando los lotes cubren todo el stock', () => {
    expect(bolsaSinVencimiento(50, 50)).toBe(0)
  })

  it('nunca es negativa aunque el dato llegue inconsistente', () => {
    // La base lo garantiza con LOTE-A, pero un caché viejo podría mentir.
    expect(bolsaSinVencimiento(10, 25)).toBe(0)
  })

  it('trata los valores ausentes como 0', () => {
    expect(bolsaSinVencimiento(undefined as unknown as number, 5)).toBe(0)
    expect(bolsaSinVencimiento(10, undefined as unknown as number)).toBe(10)
  })
})

describe('aplanarVencimientos', () => {
  it('convierte las líneas al payload de la RPC', () => {
    expect(
      aplanarVencimientos([
        { productoId: '7', vencimientos: [{ fecha: '2026-10-01', cantidad: 12 }] },
      ]),
    ).toEqual([{ producto_id: 7, fecha_vencimiento: '2026-10-01', cantidad: 12 }])
  })

  it('deja las dos fechas de una misma línea como dos lotes', () => {
    expect(
      aplanarVencimientos([
        {
          productoId: '7',
          vencimientos: [
            { fecha: '2026-10-01', cantidad: 12 },
            { fecha: '2026-12-01', cantidad: 8 },
          ],
        },
      ]),
    ).toEqual([
      { producto_id: 7, fecha_vencimiento: '2026-10-01', cantidad: 12 },
      { producto_id: 7, fecha_vencimiento: '2026-12-01', cantidad: 8 },
    ])
  })

  it('suma dos líneas del mismo producto con la misma fecha', () => {
    // Dos filas con esa clave violarían el UNIQUE de producto_lotes.
    expect(
      aplanarVencimientos([
        { productoId: '7', vencimientos: [{ fecha: '2026-10-01', cantidad: 12 }] },
        { productoId: '7', vencimientos: [{ fecha: '2026-10-01', cantidad: 5 }] },
      ]),
    ).toEqual([{ producto_id: 7, fecha_vencimiento: '2026-10-01', cantidad: 17 }])
  })

  it('no mezcla productos distintos con la misma fecha', () => {
    const r = aplanarVencimientos([
      { productoId: '7', vencimientos: [{ fecha: '2026-10-01', cantidad: 12 }] },
      { productoId: '9', vencimientos: [{ fecha: '2026-10-01', cantidad: 3 }] },
    ])
    expect(r).toHaveLength(2)
    expect(r.map(x => x.producto_id).sort()).toEqual([7, 9])
  })

  it('descarta las filas a medio tipear en vez de hacer fallar la carga entera', () => {
    expect(
      aplanarVencimientos([
        {
          productoId: '7',
          vencimientos: [
            { fecha: '', cantidad: 5 },
            { fecha: '2026-10-01', cantidad: 0 },
            { fecha: '2026-11-01', cantidad: -3 },
            { fecha: '2026-12-01', cantidad: 4 },
          ],
        },
      ]),
    ).toEqual([{ producto_id: 7, fecha_vencimiento: '2026-12-01', cantidad: 4 }])
  })

  it('ignora las líneas sin vencimientos, que es el caso normal', () => {
    expect(
      aplanarVencimientos([
        { productoId: '7' },
        { productoId: '9', vencimientos: [] },
      ]),
    ).toEqual([])
  })

  it('descarta un productoId que no es un número', () => {
    expect(
      aplanarVencimientos([
        { productoId: 'nuevo', vencimientos: [{ fecha: '2026-10-01', cantidad: 5 }] },
      ]),
    ).toEqual([])
  })
})

describe('formatearFechaVencimiento', () => {
  it('imprime dd/mm/aaaa sin correrse de zona', () => {
    expect(formatearFechaVencimiento('2026-10-01')).toBe('01/10/2026')
    expect(formatearFechaVencimiento('2026-01-31')).toBe('31/01/2026')
  })

  it('tolera un timestamp completo', () => {
    expect(formatearFechaVencimiento('2026-10-01T00:00:00Z')).toBe('01/10/2026')
  })

  it('devuelve una raya con una fecha ilegible', () => {
    expect(formatearFechaVencimiento('')).toBe('—')
  })
})
