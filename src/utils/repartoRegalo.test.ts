import { describe, it, expect } from 'vitest'
import {
  conservarRepartos,
  mapaSustitucionesVigentes,
  validarRepartoRegalo,
} from './repartoRegalo'

describe('validarRepartoRegalo', () => {
  it('un reparto válido suma exactamente la cantidad original', () => {
    const v = validarRepartoRegalo(
      [{ productoId: '1', cantidad: 5 }, { productoId: '2', cantidad: 10 }],
      15,
      '1',
    )
    expect(v).toMatchObject({ ok: true, asignado: 15, faltante: 0, esReparto: true })
  })

  it('en un reparto se puede quedar parte del sabor original', () => {
    expect(validarRepartoRegalo(
      [{ productoId: '9', cantidad: 6 }, { productoId: '2', cantidad: 8 }],
      14,
      '9',
    ).ok).toBe(true)
  })

  it('avisa cuánto falta asignar', () => {
    const v = validarRepartoRegalo(
      [{ productoId: '1', cantidad: 5 }, { productoId: '2', cantidad: 7 }],
      15,
      '1',
    )
    expect(v.ok).toBe(false)
    expect(v.faltante).toBe(3)
    expect(v.errores).toContain('Faltan asignar 3 de 15')
  })

  it('avisa cuando se pasa', () => {
    const v = validarRepartoRegalo(
      [{ productoId: '1', cantidad: 10 }, { productoId: '2', cantidad: 7 }],
      15,
      '1',
    )
    expect(v.faltante).toBe(-2)
    expect(v.errores[0]).toMatch(/Te pasaste por 2/)
  })

  it('rechaza productos repetidos, filas sin producto y cantidades en 0', () => {
    expect(validarRepartoRegalo(
      [{ productoId: '1', cantidad: 5 }, { productoId: '1', cantidad: 10 }], 15, '1',
    ).errores).toContain('Hay un producto repetido')
    expect(validarRepartoRegalo(
      [{ productoId: '', cantidad: 5 }, { productoId: '2', cantidad: 10 }], 15, '1',
    ).errores).toContain('Elegí un producto en cada fila')
    expect(validarRepartoRegalo(
      [{ productoId: '3', cantidad: 0 }, { productoId: '2', cantidad: 15 }], 15, '1',
    ).errores).toContain('Cada fila necesita una cantidad mayor a 0')
  })

  it('las partes de un reparto son enteras (la columna es integer)', () => {
    expect(validarRepartoRegalo(
      [{ productoId: '1', cantidad: 7.5 }, { productoId: '2', cantidad: 7.5 }], 15, '1',
    ).errores).toContain('Las cantidades del reparto tienen que ser enteras')
  })

  it('una sola fila es la sustitución de siempre: cantidad libre, producto distinto', () => {
    expect(validarRepartoRegalo([{ productoId: '2', cantidad: 12 }], 15, '1'))
      .toMatchObject({ ok: true, esReparto: false })
    expect(validarRepartoRegalo([{ productoId: '1', cantidad: 15 }], 15, '1').errores)
      .toContain('Elegí un producto distinto del actual')
  })
})

describe('mapaSustitucionesVigentes', () => {
  it('la sustitución más nueva de cada (promo, original) gana', () => {
    const m = mapaSustitucionesVigentes([
      { promocion_id: 13, producto_original_id: 314, producto_sustituto_id: 80, cantidad_sustituta: 14 },
      { promocion_id: 13, producto_original_id: 314, producto_sustituto_id: 79, cantidad_sustituta: 14 },
    ])
    expect(m.get('13|314')).toEqual({ productoSustitutoId: '80', cantidadSustituta: 14 })
  })

  it('un reparto invalida las sustituciones anteriores de la promo y no entra al mapa', () => {
    const m = mapaSustitucionesVigentes([
      // más nueva primero
      { promocion_id: 13, producto_original_id: 314, producto_sustituto_id: 314, cantidad_sustituta: 6, reparto_id: 'r1' },
      { promocion_id: 13, producto_original_id: 314, producto_sustituto_id: 80, cantidad_sustituta: 8, reparto_id: 'r1' },
      { promocion_id: 13, producto_original_id: 80, producto_sustituto_id: 79, cantidad_sustituta: 14 },
    ])
    // Con el LIMIT 1 de antes, 314 se reescribía a 80 y 80 a 79: el reparto colapsaba.
    expect(m.size).toBe(0)
  })

  it('una sustitución POSTERIOR al reparto sigue valiendo', () => {
    const m = mapaSustitucionesVigentes([
      { promocion_id: 13, producto_original_id: 80, producto_sustituto_id: 79, cantidad_sustituta: 8 },
      { promocion_id: 13, producto_original_id: 314, producto_sustituto_id: 80, cantidad_sustituta: 8, reparto_id: 'r1' },
    ])
    expect(m.get('13|80')).toEqual({ productoSustitutoId: '79', cantidadSustituta: 8 })
  })

  it('el reparto de una promo no toca las sustituciones de otra', () => {
    const m = mapaSustitucionesVigentes([
      { promocion_id: 13, producto_original_id: 314, producto_sustituto_id: 80, cantidad_sustituta: 8, reparto_id: 'r1' },
      { promocion_id: 15, producto_original_id: 94, producto_sustituto_id: 92, cantidad_sustituta: 2 },
    ])
    expect(m.get('15|94')).toEqual({ productoSustitutoId: '92', cantidadSustituta: 2 })
  })
})

describe('conservarRepartos', () => {
  const aLinea = (p: { producto_id: string | number; cantidad: number; promocion_id?: string | number | null }, plantilla: { productoId: string; cantidad: number; promocionId?: string | number | null; nombre?: string }) => ({
    ...plantilla,
    productoId: String(p.producto_id),
    cantidad: p.cantidad,
  })

  it('con el total igual manda las líneas que ya tenía el pedido', () => {
    const { bonificaciones, repartosPerdidos } = conservarRepartos(
      [
        { productoId: '79', cantidad: 14, promocionId: 13 },
        { productoId: '94', cantidad: 2, promocionId: 15 },
      ],
      [
        { producto_id: 314, cantidad: 6, promocion_id: 13 },
        { producto_id: 80, cantidad: 4, promocion_id: 13 },
        { producto_id: 79, cantidad: 4, promocion_id: 13 },
        { producto_id: 94, cantidad: 2, promocion_id: 15 },
      ],
      aLinea,
    )
    expect(bonificaciones.map(b => [b.productoId, b.cantidad])).toEqual([
      ['314', 6], ['80', 4], ['79', 4], ['94', 2],
    ])
    expect(repartosPerdidos).toEqual([])
  })

  it('si la cantidad de la promo cambió va lo recalculado y se avisa', () => {
    const { bonificaciones, repartosPerdidos } = conservarRepartos(
      [{ productoId: '79', cantidad: 12, promocionId: 13 }],
      [
        { producto_id: 314, cantidad: 6, promocion_id: 13 },
        { producto_id: 80, cantidad: 8, promocion_id: 13 },
      ],
      aLinea,
    )
    expect(bonificaciones).toEqual([{ productoId: '79', cantidad: 12, promocionId: 13 }])
    expect(repartosPerdidos).toEqual(['13'])
  })

  it('una promo con una sola línea no se toca', () => {
    const calculadas = [{ productoId: '94', cantidad: 3, promocionId: 15 }]
    const r = conservarRepartos(calculadas, [{ producto_id: 94, cantidad: 2, promocion_id: 15 }], aLinea)
    expect(r.bonificaciones).toEqual(calculadas)
    expect(r.repartosPerdidos).toEqual([])
  })

  it('si se quitó la promo, no resucita sus líneas', () => {
    const r = conservarRepartos(
      [],
      [
        { producto_id: 314, cantidad: 6, promocion_id: 13 },
        { producto_id: 80, cantidad: 8, promocion_id: 13 },
      ],
      aLinea,
    )
    expect(r.bonificaciones).toEqual([])
  })
})
