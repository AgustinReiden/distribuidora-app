import { describe, expect, it } from 'vitest'
import { avisosDeCupo, cupoLleno, promosConRegalo, type CupoPromo } from './cupoPromo'

const cupo = (promocionId: string, limite: number, usos: number, quedan = limite - usos): CupoPromo =>
  ({ promocionId, limite, usos, quedan })

describe('cupoLleno', () => {
  it('se llena al llegar al límite', () => {
    expect(cupoLleno(cupo('1', 5, 4))).toBe(false)
    expect(cupoLleno(cupo('1', 5, 5))).toBe(true)
  })
})

describe('avisosDeCupo', () => {
  // La promo 2 está llena, y al pedido que se edita le quedan las 5 que ya usa.
  const cupos = new Map([['1', cupo('1', 10, 8)], ['2', cupo('2', 5, 5, 5)]])

  it('sin cupos, sin avisos', () => {
    expect(avisosDeCupo(undefined, [{ promocionId: '1', cantidad: 1 }])).toEqual([])
    expect(avisosDeCupo(new Map(), [{ promocionId: '1', cantidad: 1 }])).toEqual([])
  })

  it('una promo sin límite, o un regalo sin promo, no avisan', () => {
    expect(avisosDeCupo(cupos, [{ promocionId: '9', cantidad: 1 }, { promocionId: null, cantidad: 1 }])).toEqual([])
  })

  it('avisa cuánto queda aunque alcance', () => {
    expect(avisosDeCupo(cupos, [{ promocionId: '1', promoNombre: 'Verano', cantidad: 2 }])).toEqual([
      { promocionId: '1', promoNombre: 'Verano', limite: 10, quedan: 2, lleva: 2, alcanza: true },
    ])
  })

  it('dice que no alcanza con los mismos números que el rechazo', () => {
    expect(avisosDeCupo(cupos, [{ promocionId: '1', promoNombre: 'Verano', cantidad: 3 }])[0]).toMatchObject({
      quedan: 2, lleva: 3, alcanza: false,
    })
  })

  it('las partes de un reparto se suman', () => {
    const [aviso] = avisosDeCupo(cupos, [
      { promocionId: '1', promoNombre: 'Verano', cantidad: 1 },
      { promocionId: '1', promoNombre: 'Verano', cantidad: 2 },
    ])
    expect(aviso).toMatchObject({ lleva: 3, alcanza: false })
  })

  it('el pedido que completó el cupo conserva su regalo: la promo está llena y le alcanza', () => {
    expect(avisosDeCupo(cupos, [{ promocionId: '2', promoNombre: 'Otoño', cantidad: 5 }])[0]).toMatchObject({
      quedan: 5, lleva: 5, alcanza: true,
    })
  })

  it('sin nombre, dice el número de la promo', () => {
    expect(avisosDeCupo(cupos, [{ promocionId: '1', cantidad: 1 }])[0].promoNombre).toBe('#1')
  })
})

describe('promosConRegalo', () => {
  it('son las promos de las líneas de regalo, sin repetir y en orden fijo', () => {
    expect(promosConRegalo([
      { es_bonificacion: true, promocion_id: 13 },
      { es_bonificacion: true, promocion_id: '4' },
      { es_bonificacion: true, promocion_id: 13 },
    ])).toEqual(['13', '4'])
  })

  it('una línea de venta o un regalo sin promo no cuentan', () => {
    expect(promosConRegalo([
      { es_bonificacion: false, promocion_id: 13 },
      { es_bonificacion: true, promocion_id: null },
    ])).toEqual([])
    expect(promosConRegalo(undefined)).toEqual([])
  })
})
