import { describe, it, expect } from 'vitest'
import {
  presetAnio,
  presetMes,
  presetsVentas,
  labelMes,
  ultimoDiaDelMes,
} from './periodosReporte'

// 20/08/2026, que es el día en que se pidió el informe.
const HOY = new Date(2026, 7, 20)

describe('presetMes', () => {
  it('el mes en curso corta HOY, no a fin de mes', () => {
    expect(presetMes(0, HOY)).toEqual({
      id: 'mes-2026-08',
      label: 'Agosto 2026 (en curso)',
      desde: '2026-08-01',
      hasta: '2026-08-20',
    })
  })

  it('los meses cerrados van del 1 al último día', () => {
    expect(presetMes(1, HOY)).toEqual({
      id: 'mes-2026-07',
      label: 'Julio 2026',
      desde: '2026-07-01',
      hasta: '2026-07-31',
    })
    expect(presetMes(2, HOY)).toEqual({
      id: 'mes-2026-06',
      label: 'Junio 2026',
      desde: '2026-06-01',
      hasta: '2026-06-30',
    })
  })

  it('cruza el año hacia atrás sin romperse', () => {
    const enero = new Date(2026, 0, 15)
    expect(presetMes(1, enero)).toMatchObject({
      label: 'Diciembre 2025',
      desde: '2025-12-01',
      hasta: '2025-12-31',
    })
    expect(presetMes(2, enero)).toMatchObject({
      label: 'Noviembre 2025',
      desde: '2025-11-01',
      hasta: '2025-11-30',
    })
  })

  it('febrero bisiesto termina el 29', () => {
    expect(presetMes(1, new Date(2028, 2, 10)).hasta).toBe('2028-02-29')
    expect(presetMes(1, new Date(2027, 2, 10)).hasta).toBe('2027-02-28')
  })

  it('a primera hora del día la fecha no se corre para atrás', () => {
    // El bug clásico de toISOString() en UTC-3: 00:30 local del 20/08 es
    // 03:30 UTC del 20/08 en Argentina, pero en zonas al este daría el 19.
    // Con componentes locales siempre es el día que marca el reloj.
    const madrugada = new Date(2026, 7, 20, 0, 30)
    expect(presetMes(0, madrugada).hasta).toBe('2026-08-20')
  })
})

describe('presetAnio', () => {
  it('va del 1 de enero a hoy', () => {
    expect(presetAnio(HOY)).toEqual({
      id: 'anio-2026',
      label: 'Año 2026',
      desde: '2026-01-01',
      hasta: '2026-08-20',
    })
  })
})

describe('presetsVentas', () => {
  it('ofrece el año y los tres últimos meses, del más nuevo al más viejo', () => {
    expect(presetsVentas(HOY).map((p) => p.label)).toEqual([
      'Año 2026',
      'Agosto 2026 (en curso)',
      'Julio 2026',
      'Junio 2026',
    ])
  })

  it('los ids son únicos (se usan como key de React)', () => {
    const ids = presetsVentas(HOY).map((p) => p.id)
    expect(new Set(ids).size).toBe(ids.length)
  })
})

describe('ultimoDiaDelMes', () => {
  it('resuelve diciembre sin desbordar el año', () => {
    expect(ultimoDiaDelMes(2026, 11)).toBe(31)
  })
})

describe('labelMes', () => {
  it('abrevia la clave YYYY-MM que devuelve el RPC', () => {
    expect(labelMes('2026-06')).toBe('Jun 26')
    expect(labelMes('2026-12')).toBe('Dic 26')
  })

  it('devuelve la clave tal cual si no la entiende', () => {
    expect(labelMes('cualquier-cosa')).toBe('cualquier-cosa')
  })
})
