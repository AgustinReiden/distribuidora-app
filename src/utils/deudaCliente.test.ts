/**
 * Tests del aviso de deuda previa.
 *
 * POR QUE ESTOS CASOS
 * -------------------
 * El caso que manda es "el saldo incluye este pedido": el trigger
 * `actualizar_saldo_pedido` suma lo impago del pedido al saldo del cliente en el
 * mismo INSERT, así que sin descontarlo la tarjeta de CUALQUIER pedido impago
 * diría "debe" — que es exactamente lo contrario de avisar de un pedido
 * anterior. Si alguien saca ese descuento, este archivo tiene que ponerse rojo.
 *
 * El segundo en importancia es el sobrepago: ahí la contribución del pedido al
 * saldo es negativa, y restarla sin clamp inventaría deuda. Este aviso se lee
 * delante del cliente; que subestime es aceptable, que acuse de más no.
 */
import { describe, it, expect } from 'vitest'
import { avisoDeudaCliente } from './deudaCliente'

describe('avisoDeudaCliente — al crear el pedido (sin pedido propio)', () => {
  it('no avisa cuando el cliente está al día', () => {
    expect(avisoDeudaCliente(0)).toBeNull()
  })

  it('no avisa cuando el cliente tiene saldo a favor', () => {
    // saldo_cuenta negativo = a favor del cliente (COMMENT de la columna).
    expect(avisoDeudaCliente(-5000)).toBeNull()
  })

  it('no avisa sin dato de saldo', () => {
    expect(avisoDeudaCliente(null)).toBeNull()
    expect(avisoDeudaCliente(undefined)).toBeNull()
    expect(avisoDeudaCliente(NaN)).toBeNull()
  })

  it('avisa con el monto cuando el cliente debe', () => {
    const aviso = avisoDeudaCliente(12500)
    expect(aviso?.monto).toBe(12500)
    expect(aviso?.etiqueta).toContain('12.500')
    expect(aviso?.detalle).toContain('12.500')
  })

  it('ignora restos por debajo del centavo en vez de avisar $0', () => {
    expect(avisoDeudaCliente(0.004)).toBeNull()
    expect(avisoDeudaCliente(0.01)).not.toBeNull()
  })
})

describe('avisoDeudaCliente — en la tarjeta (el saldo YA incluye este pedido)', () => {
  it('no avisa cuando la deuda es sólo este pedido', () => {
    // Único pedido impago del cliente: saldo == lo que este pedido debe.
    expect(
      avisoDeudaCliente(30000, { pedido: { total: 30000, monto_pagado: 0 } }),
    ).toBeNull()
  })

  it('avisa sólo por lo anterior cuando hay deuda vieja además de este pedido', () => {
    // Saldo 50.000 = 30.000 de este pedido + 20.000 de antes.
    const aviso = avisoDeudaCliente(50000, { pedido: { total: 30000, monto_pagado: 0 } })
    expect(aviso?.monto).toBe(20000)
  })

  it('descuenta sólo la parte impaga de un pedido con pago parcial', () => {
    // Este pedido aporta 30.000 - 18.000 = 12.000 al saldo; lo anterior son 8.000.
    const aviso = avisoDeudaCliente(20000, { pedido: { total: 30000, monto_pagado: 18000 } })
    expect(aviso?.monto).toBe(8000)
  })

  it('un pedido ya cobrado no descuenta nada: el saldo es todo deuda previa', () => {
    const aviso = avisoDeudaCliente(20000, { pedido: { total: 30000, monto_pagado: 30000 } })
    expect(aviso?.monto).toBe(20000)
  })

  it('un pedido sobrepagado no infla la deuda avisada', () => {
    // Aporte real al saldo = -5.000. Restarlo daría 25.000: deuda inventada.
    const aviso = avisoDeudaCliente(20000, { pedido: { total: 30000, monto_pagado: 35000 } })
    expect(aviso?.monto).toBe(20000)
  })

  it('un pedido cancelado (total 0, mig 175) no descuenta nada', () => {
    const aviso = avisoDeudaCliente(20000, { pedido: { total: 0, monto_pagado: 0 } })
    expect(aviso?.monto).toBe(20000)
  })

  it('trata monto_pagado ausente como 0, igual que el COALESCE del trigger', () => {
    expect(avisoDeudaCliente(30000, { pedido: { total: 30000 } })).toBeNull()
  })

  it('no deja resto de float cuando el pedido es toda la deuda', () => {
    // 0.1 + 0.2 en float no da 0.3: sin redondeo esto avisaría por milésimas.
    expect(avisoDeudaCliente(0.3, { pedido: { total: 0.1 + 0.2, monto_pagado: 0 } })).toBeNull()
  })
})

describe('avisoDeudaCliente — saldo posiblemente viejo (offline)', () => {
  it('habla en pasado y dice de cuándo es el dato', () => {
    const aviso = avisoDeudaCliente(12500, { saldoAl: '6/9, 14:32' })
    expect(aviso?.etiqueta).toContain('6/9, 14:32')
    expect(aviso?.detalle).toContain('6/9, 14:32')
    expect(aviso?.detalle).toContain('cobrado después')
  })

  it('sin fecha del dato no inventa una', () => {
    const aviso = avisoDeudaCliente(12500, { saldoAl: '   ' })
    expect(aviso?.etiqueta).toMatch(/^Debe\s+\$\s?12\.500,00$/)
  })
})
