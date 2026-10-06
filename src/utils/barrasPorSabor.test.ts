import { describe, expect, it } from 'vitest'
import { barrasPorSabor } from './barrasPorSabor'
import type { PromoAcumuladorDB } from '../types'

const fila = (producto: string, usos: number | string, contenedor: string | null = producto): PromoAcumuladorDB => ({
  id: `acc-${producto}`,
  promocion_id: '13',
  producto_regalo_id: producto,
  ajuste_producto_id: contenedor,
  // PostgREST devuelve NUMERIC como string: "4.00".
  usos_pendientes: usos as number,
  sucursal_id: 1,
  created_at: '',
  updated_at: '',
})

const promo13 = { id: 13, producto_regalo_id: 82, ajuste_producto_id: 82, usos_pendientes: 0 }

describe('barrasPorSabor', () => {
  it('la del sabor default sale de la promo y va primero, aunque esté en 0', () => {
    const barras = barrasPorSabor(promo13, [fila('78', 4)])
    expect(barras[0]).toMatchObject({
      producto_regalo_id: '82', ajuste_producto_id: '82', usos_pendientes: 0, esDefault: true,
    })
  })

  it('cada otro sabor tiene SU barra, con su contenedor (no la suma en la default)', () => {
    const barras = barrasPorSabor({ ...promo13, usos_pendientes: 3 }, [
      fila('78', '4.00'), fila('80', 2), fila('314', '2.00'),
    ])
    expect(barras.map(b => [b.producto_regalo_id, b.usos_pendientes, b.ajuste_producto_id, b.esDefault])).toEqual([
      ['82', 3, '82', true],
      ['78', 4, '78', false],
      ['80', 2, '80', false],
      ['314', 2, '314', false],
    ])
  })

  it('un sabor sin fardo abierto no se muestra', () => {
    const barras = barrasPorSabor(promo13, [fila('79', '0.00'), fila('80', 2)])
    expect(barras.map(b => b.producto_regalo_id)).toEqual(['82', '80'])
  })

  it('una fila del sabor default (no debería existir, mig 221) no duplica la barra', () => {
    const barras = barrasPorSabor({ ...promo13, usos_pendientes: 1 }, [fila('82', 5)])
    expect(barras).toHaveLength(1)
    expect(barras[0].usos_pendientes).toBe(1)
  })

  it('sin regalo default ni filas no hay barras', () => {
    expect(barrasPorSabor({ id: 1, producto_regalo_id: null }, undefined)).toEqual([])
  })
})
