import { describe, it, expect } from 'vitest'
import { mismoTotalDelAlta, avisoAltaQueYaHabiaEntrado } from './totalDelAlta'

describe('mismoTotalDelAlta (hallazgo 5 de la revisión de B4, 1559-b1)', () => {
  it('un centavo de diferencia es el mismo total, sin depender de la coma flotante', () => {
    expect(Math.abs(99.99 - 100) < 0.01).toBe(false)
    expect(mismoTotalDelAlta(99.99, 100)).toBe(true)
    expect(mismoTotalDelAlta(100.01, 100)).toBe(true)
  })

  it('el mismo total es el mismo', () => {
    expect(mismoTotalDelAlta(1234.56, 1234.56)).toBe(true)
  })

  it('dos centavos ya no', () => {
    expect(mismoTotalDelAlta(99.98, 100)).toBe(false)
    expect(mismoTotalDelAlta(100.02, 100)).toBe(false)
  })
})

describe('avisoAltaQueYaHabiaEntrado (I2 de la revisión de B12a)', () => {
  const enviado = { clienteId: '9', total: 12000, tipoFactura: 'ZZ' }
  const propio = { id: 41, idempotente: true, clienteId: 9, total: 8500, cargoEnvio: 500 }

  it('pedido propio con otro total: avisa con el número del pedido', () => {
    const aviso = avisoAltaQueYaHabiaEntrado(propio, enviado)
    expect(aviso).toContain('#41')
    expect(aviso).toMatch(/ya estaba cargado/)
    expect(aviso).toMatch(/no se cargó otro/)
  })

  it('mismo total (el envío no cuenta) o a un centavo: no hay nada que avisar', () => {
    expect(avisoAltaQueYaHabiaEntrado({ ...propio, total: 12500 }, enviado)).toBeNull()
    expect(avisoAltaQueYaHabiaEntrado({ ...propio, total: 12500.01 }, enviado)).toBeNull()
  })

  it('un pedido cancelado (total 0) es un pedido que cambió', () => {
    expect(avisoAltaQueYaHabiaEntrado({ ...propio, total: 0, cargoEnvio: 0 }, enviado)).not.toBeNull()
  })

  it('no aplica: alta nueva, pedido que no se pudo leer, otro cliente o vale blanco', () => {
    expect(avisoAltaQueYaHabiaEntrado({ ...propio, idempotente: undefined }, enviado)).toBeNull()
    expect(avisoAltaQueYaHabiaEntrado({ ...propio, clienteId: null }, enviado)).toBeNull()
    expect(avisoAltaQueYaHabiaEntrado({ ...propio, total: null }, enviado)).toBeNull()
    expect(avisoAltaQueYaHabiaEntrado({ ...propio, clienteId: 10 }, enviado)).toBeNull()
    expect(avisoAltaQueYaHabiaEntrado(propio, { ...enviado, tipoFactura: 'VB' })).toBeNull()
    expect(avisoAltaQueYaHabiaEntrado(null, enviado)).toBeNull()
  })
})
