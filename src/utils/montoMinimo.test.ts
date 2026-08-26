/**
 * Tests de la compra mínima por pedido.
 *
 * POR QUE ESTOS CASOS
 * -------------------
 * La regla vive en la base (`pedido_incumple_minimo`, mig 205) y acá se espeja
 * para poder bloquear ANTES de confirmar. Si las dos se desalinean, el síntoma
 * es el peor posible: el pedido se acepta en el teléfono sin señal y falla al
 * sincronizar, horas después, lejos del cliente.
 *
 * El caso del 0 es el que más importa: es el estado con el que la política
 * arranca en todas las sucursales (mig 204). Si 0 frenara pedidos, aplicar la
 * migración cortaría la operación entera de una.
 */
import { describe, it, expect } from 'vitest'
import { cumpleMontoMinimo, motivoMontoMinimo } from './montoMinimo'

describe('cumpleMontoMinimo', () => {
  it('mínimo 0 = sin política: no frena nada', () => {
    // Es el estado inicial de todas las sucursales tras la mig 204.
    expect(cumpleMontoMinimo(0, 0)).toBe(true)
    expect(cumpleMontoMinimo(1, 0)).toBe(true)
    expect(cumpleMontoMinimo(999999, 0)).toBe(true)
  })

  it('deja pasar el pedido que da exactamente el mínimo', () => {
    expect(cumpleMontoMinimo(10000, 10000)).toBe(true)
  })

  it('frena por debajo y deja pasar por encima', () => {
    expect(cumpleMontoMinimo(9999.99, 10000)).toBe(false)
    expect(cumpleMontoMinimo(10000.01, 10000)).toBe(true)
  })

  it('trata un total no numérico como 0, no como "pasa"', () => {
    expect(cumpleMontoMinimo(NaN, 10000)).toBe(false)
  })

  it('un mínimo inválido no frena: ante la duda, no cortar la operación', () => {
    expect(cumpleMontoMinimo(500, NaN)).toBe(true)
    expect(cumpleMontoMinimo(500, -1)).toBe(true)
  })
})

describe('motivoMontoMinimo', () => {
  it('devuelve null cuando el pedido cumple', () => {
    expect(motivoMontoMinimo(10000, 10000)).toBeNull()
    expect(motivoMontoMinimo(500, 0)).toBeNull()
  })

  it('dice el mínimo y cuánto falta', () => {
    const motivo = motivoMontoMinimo(7500, 10000)
    expect(motivo).toContain('10.000')
    expect(motivo).toContain('2.500')
  })
})
