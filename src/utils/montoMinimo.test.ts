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
import {
  cumpleMontoMinimo,
  motivoMontoMinimo,
  motivoRechazoMinimo,
  cargoEnvioPedido,
  faltanteParaEnvioGratis,
  REGLA_MINIMO_POR_DEFECTO,
  type ReglaMinimoPedido,
} from './montoMinimo'

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

describe('cargo de envío bajo el mínimo (mig 389, #1220)', () => {
  const bloquear: ReglaMinimoPedido = { modo: 'bloquear', montoMinimo: 10000, montoEnvioGratis: 0, cargoEnvio: 0 }
  const cargo: ReglaMinimoPedido = { modo: 'cargo', montoMinimo: 10000, montoEnvioGratis: 0, cargoEnvio: 1500 }
  const escalas: ReglaMinimoPedido = { modo: 'escalas', montoMinimo: 10000, montoEnvioGratis: 20000, cargoEnvio: 1500 }

  it('arranca sin política: ni rechaza ni cobra', () => {
    expect(motivoRechazoMinimo(1, REGLA_MINIMO_POR_DEFECTO)).toBeNull()
    expect(cargoEnvioPedido(1, REGLA_MINIMO_POR_DEFECTO)).toBe(0)
  })

  it('bloquear: rechaza bajo el mínimo y nunca cobra envío', () => {
    expect(motivoRechazoMinimo(9999, bloquear)).toContain('10.000')
    expect(motivoRechazoMinimo(10000, bloquear)).toBeNull()
    // Aunque haya un cargo guardado de un modo anterior: bloquear no lo cobra.
    expect(cargoEnvioPedido(9999, { ...bloquear, cargoEnvio: 1500 })).toBe(0)
  })

  it('cargo: no rechaza nunca; cobra bajo el mínimo y desde el mínimo no', () => {
    expect(motivoRechazoMinimo(1, cargo)).toBeNull()
    expect(cargoEnvioPedido(9999.99, cargo)).toBe(1500)
    expect(cargoEnvioPedido(10000, cargo)).toBe(0)
  })

  it('cargo con mínimo 0: sin umbral, no cobra', () => {
    expect(cargoEnvioPedido(1, { ...cargo, montoMinimo: 0 })).toBe(0)
  })

  it('escalas: bajo xx rechaza, entre xx y xxx cobra, desde xxx nada', () => {
    expect(motivoRechazoMinimo(9999, escalas)).not.toBeNull()
    expect(cargoEnvioPedido(9999, escalas)).toBe(0)

    expect(motivoRechazoMinimo(10000, escalas)).toBeNull()
    expect(cargoEnvioPedido(10000, escalas)).toBe(1500)
    expect(cargoEnvioPedido(19999.99, escalas)).toBe(1500)

    expect(motivoRechazoMinimo(20000, escalas)).toBeNull()
    expect(cargoEnvioPedido(20000, escalas)).toBe(0)
  })

  it('cargo 0 no cobra nada en ningún modo', () => {
    expect(cargoEnvioPedido(1, { ...cargo, cargoEnvio: 0 })).toBe(0)
    expect(cargoEnvioPedido(10000, { ...escalas, cargoEnvio: 0 })).toBe(0)
  })

  it('dice cuánto falta para no pagar envío', () => {
    expect(faltanteParaEnvioGratis(9000, cargo)).toBe(1000)
    expect(faltanteParaEnvioGratis(12000, escalas)).toBe(8000)
    expect(faltanteParaEnvioGratis(25000, escalas)).toBeNull()
    expect(faltanteParaEnvioGratis(9000, bloquear)).toBeNull()
  })
})
