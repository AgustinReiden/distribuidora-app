import { describe, it, expect } from 'vitest'
import { stockDisponibleParaEnvio, costoDestinoAlAceptar } from './movimientos'

describe('stockDisponibleParaEnvio', () => {
  it('al crear (sin reserva previa) el tope es el stock actual', () => {
    expect(stockDisponibleParaEnvio(50)).toBe(50)
    expect(stockDisponibleParaEnvio(50, 0)).toBe(50)
  })

  it('al editar suma lo que este envío ya se llevó', () => {
    // El envío tiene 10 u. reservadas y en góndola quedan 40 -> se puede llegar a 50.
    expect(stockDisponibleParaEnvio(40, 10)).toBe(50)
  })

  it('permite bajar la cantidad aunque el producto haya quedado en 0', () => {
    // Caso real: el envío se llevó todo. Sin sumar la reserva el tope sería 0
    // y no se podría ni corregir el envío hacia abajo.
    expect(stockDisponibleParaEnvio(0, 100)).toBe(100)
  })

  it('nunca devuelve negativo', () => {
    expect(stockDisponibleParaEnvio(-5)).toBe(0)
    expect(stockDisponibleParaEnvio(-10, 3)).toBe(0)
  })

  it('tolera valores no numéricos', () => {
    expect(stockDisponibleParaEnvio(NaN)).toBe(0)
    expect(stockDisponibleParaEnvio(10, NaN)).toBe(10)
  })
})

describe('costoDestinoAlAceptar', () => {
  const item = { cantidad: 22, origen_costo_con_iva: 121, origen_costo_sin_iva: 100, origen_costo_promedio: 100 }

  it('match: reposición = el mayor y promedio ponderado con el stock previo del destino', () => {
    // Mismo caso que el ensayo de la migración: 20 u. a 200 + 22 u. a 100.
    const r = costoDestinoAlAceptar(item, { stock: 20, costo_con_iva: 100, costo_sin_iva: 80, costo_promedio: 200 })
    expect(r.reposicionConIva).toBe(121)
    expect(r.reposicionSinIva).toBe(100)
    expect(r.promedio).toBe(147.619)
    expect(r.ponderado).toBe(true)
  })

  it('destino sin stock o sin promedio: queda el promedio del origen', () => {
    expect(costoDestinoAlAceptar(item, { stock: 0, costo_promedio: 200 }).promedio).toBe(100)
    expect(costoDestinoAlAceptar(item, { stock: 10, costo_promedio: null }).promedio).toBe(100)
    expect(costoDestinoAlAceptar(item, { stock: -3, costo_promedio: 200 }).ponderado).toBe(false)
  })

  it('origen sin promedio (0): no toca el del destino', () => {
    const r = costoDestinoAlAceptar({ ...item, origen_costo_promedio: 0 }, { stock: 10, costo_promedio: 200 })
    expect(r.promedio).toBe(200)
  })

  it('envío viejo sin snapshot: no adivina el promedio', () => {
    const r = costoDestinoAlAceptar({ ...item, origen_costo_promedio: null }, { stock: 10, costo_con_iva: 150, costo_promedio: 200 })
    expect(r.promedio).toBeNull()
    expect(r.reposicionConIva).toBe(150)
  })

  it('crear nuevo: copia el origen', () => {
    const r = costoDestinoAlAceptar(item, null)
    expect(r).toEqual({ reposicionConIva: 121, reposicionSinIva: 100, promedio: 100, ponderado: false })
  })
})
