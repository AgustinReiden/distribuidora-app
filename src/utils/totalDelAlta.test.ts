import { describe, it, expect } from 'vitest'
import { mismoTotalDelAlta, avisoAltaQueYaHabiaEntrado, montoCobroDelAlta } from './totalDelAlta'
import { montoCobroAlta } from './saldoAFavor'

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
    expect(aviso).toMatch(/No se cargó otro pedido/)
  })

  it('mismo total (el envío no cuenta) o a un centavo: no hay nada que avisar', () => {
    expect(avisoAltaQueYaHabiaEntrado({ ...propio, total: 12500 }, enviado)).toBeNull()
    expect(avisoAltaQueYaHabiaEntrado({ ...propio, total: 12500.01 }, enviado)).toBeNull()
  })

  it('un pedido cancelado (total 0) es un pedido que cambió', () => {
    expect(avisoAltaQueYaHabiaEntrado({ ...propio, total: 0, cargoEnvio: 0 }, enviado)).not.toBeNull()
  })

  // H4(a): con la fila sin leer llega sin cliente y con el total de la RPC. La clave es por intención y la RPC
  // sólo le contesta al que cargó el pedido: es el propio, y el total decide si cambió.
  it('sin cliente (la fila no se pudo leer), decide el total de la RPC', () => {
    expect(avisoAltaQueYaHabiaEntrado({ ...propio, clienteId: null }, enviado)).toContain('#41')
    expect(avisoAltaQueYaHabiaEntrado({ ...propio, clienteId: null, total: 12500 }, enviado)).toBeNull()
  })

  it('no aplica: alta nueva, sin total, otro cliente o vale blanco', () => {
    expect(avisoAltaQueYaHabiaEntrado({ ...propio, idempotente: undefined }, enviado)).toBeNull()
    expect(avisoAltaQueYaHabiaEntrado({ ...propio, total: null }, enviado)).toBeNull()
    expect(avisoAltaQueYaHabiaEntrado({ ...propio, clienteId: 10 }, enviado)).toBeNull()
    expect(avisoAltaQueYaHabiaEntrado(propio, { ...enviado, tipoFactura: 'VB' })).toBeNull()
    expect(avisoAltaQueYaHabiaEntrado(null, enviado)).toBeNull()
  })
})

// Decisión 5 del dueño: si el server devuelve el pedido propio ya cargado con OTRO total (más chico, más grande
// o cancelado), NO se registra ningún cobro. Los doce casos de la revisión de C7, de punta a punta: la
// respuesta del server decide (con la tolerancia del centavo y el envío aparte) si volvió distinto, y eso
// decide el cobro.
describe('el cobro del alta cuando el pedido ya estaba cargado (decisión 5)', () => {
  // El carrito: 12.000 de productos y 500 de envío mostrado. Con «Pagado», lo declarado es 12.500.
  const carrito = { clienteId: '9', total: 12000, tipoFactura: 'ZZ' }
  const cobroDe = (
    respuesta: Parameters<typeof avisoAltaQueYaHabiaEntrado>[0],
    over: { estadoPago?: string; saldoAplicado?: number; totalConEnvio?: number } = {},
  ) => {
    const aviso = avisoAltaQueYaHabiaEntrado(respuesta, carrito)
    const estadoPago = over.estadoPago ?? 'pagado'
    const monto = montoCobroDelAlta({
      estadoPago,
      montoDeclarado: estadoPago === 'parcial' ? 20000 : 0,
      totalConEnvio: over.totalConEnvio ?? 12500,
      totalGuardado: respuesta?.total ?? 0,
      saldoAplicado: over.saldoAplicado ?? 0,
      saldoMostrado: 0,
      volvioDistinto: aviso !== null,
    })
    return { aviso, monto }
  }
  const dup = (total: number, cargoEnvio: number, clienteId: string | null = '9') =>
    ({ id: '9', idempotente: true, clienteId, total, cargoEnvio })

  it('C0 alta nueva: se cobra lo de siempre', () => {
    expect(cobroDe({ id: '9', total: 12500, cargoEnvio: 500 })).toEqual({ aviso: null, monto: 12500 })
  })

  it.each([
    ['C1 editado a 8.000 + 500', dup(8500, 500), {}],
    ['C2 cancelado (total 0, sin envío)', dup(0, 0), {}],
    ['C2b cancelado que conserva el cargo de envío', dup(0, 500), {}],
    ['C3 le sumaron un renglón (15.000 + 500)', dup(15500, 500), {}],
    ['C4 editado, con 400 de saldo a favor absorbido', dup(8500, 500), { saldoAplicado: 400 }],
    ['C5 editado, y el server rechazaría el cobro: ni se intenta', dup(8500, 500), {}],
    ['C6 editado, parcial de 20.000', dup(8500, 500), { estadoPago: 'parcial' }],
    ['C8 dos centavos de diferencia: ya es otro total', dup(12500.02, 500), {}],
    ['C10 la fila no se pudo leer y el total de la RPC no es el del carrito', dup(8500, 500, null), {}],
  ])('%s: NO se registra ningún cobro y se avisa', (_caso, respuesta, over) => {
    const { aviso, monto } = cobroDe(respuesta, over)
    expect(monto).toBe(0)
    expect(aviso).toMatch(/NO se registró/)
    expect(aviso).toMatch(/Cobralo desde el pedido/)
  })

  it('el aviso dice el total que quedó, el del pedido y no el del carrito', () => {
    expect(cobroDe(dup(8500, 500)).aviso).toMatch(/ahora su total es \$\s8\.500,00/)
    expect(cobroDe(dup(0, 0)).aviso).toMatch(/ahora su total es \$\s0,00/)
  })

  it.each([
    ['C7 sin cambios', dup(12500, 500), 12500],
    ['C7b a un centavo: es el mismo total', dup(12500.01, 500), 12500],
    ['C7c a un centavo para abajo (se cobra lo que el server guardó)', dup(12499.99, 500), 12499.99],
    ['C10b la fila no se pudo leer y el total de la RPC es el del carrito', dup(12500, 500, null), 12500],
  ])('%s: es el mismo pedido, el cobro se registra como siempre', (_caso, respuesta, esperado) => {
    const { aviso, monto } = cobroDe(respuesta)
    expect(aviso).toBeNull()
    expect(monto).toBeCloseTo(esperado, 2)
  })

  it('C9 sólo cambió el envío (12.000 + 800): el envío no cuenta para «cambió» y el cobro sigue al total del server', () => {
    // El alta cobra lo que el server guardó (productos + envío): 12.800.
    const { aviso, monto } = cobroDe(dup(12800, 800), { totalConEnvio: 12800 })
    expect(aviso).toBeNull()
    expect(monto).toBeCloseTo(12800, 2)
  })

  it('un vale blanco no se compara (lo precia el server a costo) y se cobra como siempre', () => {
    const aviso = avisoAltaQueYaHabiaEntrado(dup(333, 0), { ...carrito, tipoFactura: 'VB' })
    expect(aviso).toBeNull()
  })

  it('montoCobroDelAlta: con volvioDistinto es 0 aunque el estado de pago diga otra cosa', () => {
    const args = { estadoPago: 'pagado', montoDeclarado: 0, totalConEnvio: 12500, totalGuardado: 12500, saldoAplicado: 0, saldoMostrado: 0 }
    expect(montoCobroDelAlta({ ...args, volvioDistinto: true })).toBe(0)
    expect(montoCobroDelAlta({ ...args, volvioDistinto: false })).toBe(montoCobroAlta(args))
  })
})
