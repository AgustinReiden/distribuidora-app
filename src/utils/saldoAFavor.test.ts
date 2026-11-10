import { describe, expect, it } from 'vitest'
import {
  avisoCobroAltaRecortado,
  avisoSaldoAFavorCliente,
  esSaldoAFavorAplicado,
  mensajeSaldoAFavorAlta,
  montoCobroAlta,
  partesCobroCambioCliente,
  saldoAFavorAplicado,
  saldoAFavorDelCliente,
  saldoMostradoAlta,
  saldoQueAbsorbeAlta,
  textoSaldoAFavorAplicado,
} from './saldoAFavor'

describe('saldoAFavorAplicado', () => {
  it('suma sólo los pagos marcados', () => {
    expect(saldoAFavorAplicado([
      { monto: 400, de_saldo_a_favor: true },
      { monto: '100.50', de_saldo_a_favor: true },
      { monto: 1000, de_saldo_a_favor: false },
      { monto: 50 },
    ])).toBe(500.5)
  })

  it('da 0 sin pagos o sin la columna (un bundle viejo contra una base vieja)', () => {
    expect(saldoAFavorAplicado(undefined)).toBe(0)
    expect(saldoAFavorAplicado([])).toBe(0)
    expect(saldoAFavorAplicado([{ monto: 100 }])).toBe(0)
  })
})

describe('textoSaldoAFavorAplicado', () => {
  it('arma el texto sólo si hay algo aplicado', () => {
    expect(textoSaldoAFavorAplicado(400)).toMatch(/^Saldo a favor aplicado: \$/)
    expect(textoSaldoAFavorAplicado(400)).toContain('400')
    expect(textoSaldoAFavorAplicado(0)).toBeNull()
  })
})

describe('mensajeSaldoAFavorAlta', () => {
  it('dice lo que cayó en la boleta nueva', () => {
    const m = mensajeSaldoAFavorAlta(12, 400, 0)
    expect(m).toContain('#12')
    expect(m).toContain('400')
    expect(m).not.toContain('anteriores')
  })

  it('dice lo que fue a boletas más viejas', () => {
    const m = mensajeSaldoAFavorAlta(12, 0, 30)
    expect(m).not.toContain('#12')
    expect(m).toContain('boletas anteriores')
    expect(m?.charAt(0)).toBe(m?.charAt(0).toUpperCase())
  })

  it('las dos cosas, o nada', () => {
    expect(mensajeSaldoAFavorAlta(12, 100, 50)).toMatch(/#12.*y .*anteriores/)
    expect(mensajeSaldoAFavorAlta(12, 0, 0)).toBeNull()
  })
})

describe('montoCobroAlta', () => {
  const base = { montoDeclarado: 0, totalConEnvio: 1000, totalGuardado: 1000, saldoAplicado: 0 }

  it('sin saldo aplicado, como antes', () => {
    expect(montoCobroAlta({ ...base, estadoPago: 'pagado' })).toBe(1000)
    expect(montoCobroAlta({ ...base, estadoPago: 'parcial', montoDeclarado: 300 })).toBe(300)
    expect(montoCobroAlta({ ...base, estadoPago: 'pendiente', montoDeclarado: 300 })).toBe(0)
  })

  it('pagado: descuenta lo que la boleta absorbió', () => {
    expect(montoCobroAlta({ ...base, estadoPago: 'pagado', saldoAplicado: 400 })).toBe(600)
  })

  it('parcial: tope en lo que falta', () => {
    expect(montoCobroAlta({ ...base, estadoPago: 'parcial', montoDeclarado: 900, saldoAplicado: 400 })).toBe(600)
    expect(montoCobroAlta({ ...base, estadoPago: 'parcial', montoDeclarado: 200, saldoAplicado: 400 })).toBe(200)
  })

  it('una boleta saldada por el crédito no cobra nada', () => {
    expect(montoCobroAlta({ ...base, estadoPago: 'pagado', saldoAplicado: 1000 })).toBe(0)
    expect(montoCobroAlta({ ...base, estadoPago: 'parcial', montoDeclarado: 50, saldoAplicado: 1000 })).toBe(0)
  })

  // #1509: con "Pagado" se registra lo que el modal dijo que había que cobrar,
  // con tope en lo que falta. Antes era el total menos lo absorbido por el
  // servidor: si absorbía menos que lo mostrado, se registraba plata que no entró.
  it('pagado: registra lo que el modal mostró para cobrar', () => {
    expect(montoCobroAlta({ ...base, estadoPago: 'pagado', saldoAplicado: 400, saldoMostrado: 400 })).toBe(600)
  })

  it('pagado: si el servidor absorbió menos que lo mostrado, no registra de más', () => {
    // Mostró $400 a favor (a cobrar $600) y el servidor absorbió $0: falta $1.000,
    // pero en la mano hay $600.
    expect(montoCobroAlta({ ...base, estadoPago: 'pagado', saldoAplicado: 0, saldoMostrado: 400 })).toBe(600)
  })

  it('pagado: si el servidor absorbió más que lo mostrado, el tope es lo que falta', () => {
    expect(montoCobroAlta({ ...base, estadoPago: 'pagado', saldoAplicado: 500, saldoMostrado: 400 })).toBe(500)
  })
})

describe('saldoMostradoAlta (#1509)', () => {
  const base = { saldoCuenta: -400, totalConEnvio: 1000, puedeVerDeuda: true, esVB: false, isOffline: false }

  it('es el saldo a favor que absorbe la boleta, con tope en el total', () => {
    expect(saldoMostradoAlta(base)).toBe(400)
    expect(saldoMostradoAlta({ ...base, saldoCuenta: -1500 })).toBe(1000)
  })

  it('0 si no se muestra: sin permiso de ver la deuda, en un VB o sin conexión', () => {
    expect(saldoMostradoAlta({ ...base, puedeVerDeuda: false })).toBe(0)
    expect(saldoMostradoAlta({ ...base, puedeVerDeuda: undefined })).toBe(0)
    expect(saldoMostradoAlta({ ...base, esVB: true })).toBe(0)
    expect(saldoMostradoAlta({ ...base, isOffline: true })).toBe(0)
  })

  it('0 si el cliente debe', () => {
    expect(saldoMostradoAlta({ ...base, saldoCuenta: 300 })).toBe(0)
  })
})

describe('partesCobroCambioCliente (#1489)', () => {
  it('separa lo que vino del saldo a favor o de un pago a cuenta del cobro de la boleta', () => {
    expect(partesCobroCambioCliente(700, [
      { monto: 400, de_saldo_a_favor: true },
      { monto: 200, a_cuenta: true },
      { monto: 100 },
    ])).toEqual({ delCliente: 600, cobro: 100 })
  })

  it('todo del saldo a favor: no hay cobro que decidir', () => {
    expect(partesCobroCambioCliente('400.00', [{ monto: '400.00', de_saldo_a_favor: true, a_cuenta: true }]))
      .toEqual({ delCliente: 400, cobro: 0 })
  })

  it('sin la lista de pagos todo es cobro, y nunca da negativo', () => {
    expect(partesCobroCambioCliente(500, undefined)).toEqual({ delCliente: 0, cobro: 500 })
    expect(partesCobroCambioCliente(100, [{ monto: 300, de_saldo_a_favor: true }])).toEqual({ delCliente: 100, cobro: 0 })
    expect(partesCobroCambioCliente(null, null)).toEqual({ delCliente: 0, cobro: 0 })
  })
})

// #1503: el alta muestra el saldo a favor ANTES de cobrar, y avisa si el cobro
// registrado es menor que lo declarado.
describe('saldoAFavorDelCliente', () => {
  it('es el saldo negativo, en positivo', () => {
    expect(saldoAFavorDelCliente(-400)).toBe(400)
    expect(saldoAFavorDelCliente('-120.5')).toBe(120.5)
  })

  it('da 0 si debe, sin dato o con ruido de centavos', () => {
    expect(saldoAFavorDelCliente(12345)).toBe(0)
    expect(saldoAFavorDelCliente(0)).toBe(0)
    expect(saldoAFavorDelCliente(null)).toBe(0)
    expect(saldoAFavorDelCliente(undefined)).toBe(0)
    expect(saldoAFavorDelCliente('abc')).toBe(0)
    expect(saldoAFavorDelCliente(-0.004)).toBe(0)
  })
})

describe('saldoQueAbsorbeAlta', () => {
  it('absorbe todo el saldo a favor, con tope en el total', () => {
    expect(saldoQueAbsorbeAlta(-400, 1000)).toBe(400)
    expect(saldoQueAbsorbeAlta(-1500, 1000)).toBe(1000)
  })

  it('un cliente que debe no le pasa nada a la boleta nueva', () => {
    expect(saldoQueAbsorbeAlta(300, 1000)).toBe(0)
  })

  it('un carrito vacío no absorbe nada', () => {
    expect(saldoQueAbsorbeAlta(-400, 0)).toBe(0)
  })
})

describe('avisoSaldoAFavorCliente', () => {
  it('dice cuánto tiene a favor y que se descuenta de esta boleta', () => {
    const t = avisoSaldoAFavorCliente(-400)
    expect(t).toMatch(/^Este cliente tiene \$/)
    expect(t).toContain('400')
    expect(t).toMatch(/se descuenta de esta boleta/)
  })

  it('sin conexión habla en pasado y fecha el dato', () => {
    const t = avisoSaldoAFavorCliente(-400, { saldoAl: '06/11/2026' })
    expect(t).toMatch(/^Sin conexión: al 06\/11\/2026 este cliente tenía \$/)
  })

  it('null si no tiene nada a favor', () => {
    expect(avisoSaldoAFavorCliente(12345)).toBeNull()
    expect(avisoSaldoAFavorCliente(null)).toBeNull()
  })
})

describe('avisoCobroAltaRecortado', () => {
  const base = { pedidoId: 12, montoDeclarado: 0, totalConEnvio: 1000, saldoAplicado: 0 }

  it('pagado con saldo a favor: dice lo registrado y lo que no quedó', () => {
    const t = avisoCobroAltaRecortado({ ...base, estadoPago: 'pagado', registrado: 600, saldoAplicado: 400 })
    expect(t).toMatch(/^En el pedido #12 se registró un cobro de \$/)
    expect(t).toContain('600')
    expect(t).toMatch(/saldo a favor del cliente cubrió \$\s400/)
    expect(t).toMatch(/Si cobraste \$\s1\.000,00, \$\s400,00 no quedaron registrados\./)
  })

  it('parcial recortado: lo declarado contra lo registrado', () => {
    const t = avisoCobroAltaRecortado({ ...base, estadoPago: 'parcial', montoDeclarado: 800, registrado: 600, saldoAplicado: 400 })
    expect(t).toMatch(/Si cobraste \$\s800,00, \$\s200,00 no quedaron registrados\./)
  })

  it('el crédito saldó la boleta: no se registró ningún cobro', () => {
    const t = avisoCobroAltaRecortado({ ...base, estadoPago: 'pagado', registrado: 0, saldoAplicado: 1000 })
    expect(t).toMatch(/^En el pedido #12 no se registró ningún cobro: /)
  })

  it('un parcial por encima del total, sin saldo a favor, también se avisa', () => {
    const t = avisoCobroAltaRecortado({ ...base, estadoPago: 'parcial', montoDeclarado: 1200, registrado: 1000 })
    expect(t).toMatch(/la boleta no debía más que eso/)
  })

  it('null si se registró lo declarado, o si no se declaró cobro', () => {
    expect(avisoCobroAltaRecortado({ ...base, estadoPago: 'pagado', registrado: 1000 })).toBeNull()
    expect(avisoCobroAltaRecortado({ ...base, estadoPago: 'parcial', montoDeclarado: 300, registrado: 300 })).toBeNull()
    expect(avisoCobroAltaRecortado({ ...base, estadoPago: 'pendiente', montoDeclarado: 300, registrado: 0 })).toBeNull()
  })

  // #1509: el modal ya había descontado el saldo a favor que mostró. Quien cobró
  // lo que el modal le pidió no tiene nada que corregir.
  it('pagado: sin aviso si se cobró lo que el modal mostró y el servidor absorbió eso', () => {
    expect(avisoCobroAltaRecortado({
      ...base, estadoPago: 'pagado', registrado: 600, saldoAplicado: 400, saldoMostrado: 400, totalGuardado: 1000,
    })).toBeNull()
  })

  it('pagado: el servidor absorbió más que lo mostrado y lo cobrado de más no quedó registrado', () => {
    const t = avisoCobroAltaRecortado({
      ...base, estadoPago: 'pagado', registrado: 500, saldoAplicado: 500, saldoMostrado: 400, totalGuardado: 1000,
    })
    expect(t).toMatch(/cubrió \$\s500,00 y no \$\s400,00, como mostraba el pedido/)
    expect(t).toMatch(/Si cobraste \$\s600,00, \$\s100,00 no quedaron registrados\./)
  })

  it('pagado: el servidor absorbió menos que lo mostrado y la boleta quedó debiendo', () => {
    const t = avisoCobroAltaRecortado({
      ...base, estadoPago: 'pagado', registrado: 600, saldoAplicado: 0, saldoMostrado: 400, totalGuardado: 1000,
    })
    expect(t).toMatch(/^El pedido #12 quedó debiendo \$\s400,00: el saldo a favor del cliente cubrió \$\s0,00 y no \$\s400,00/)
    expect(t).toMatch(/Se registró el cobro de \$\s600,00\.$/)
  })

  it('parcial: que la boleta quede debiendo es lo esperado y no se avisa', () => {
    expect(avisoCobroAltaRecortado({
      ...base, estadoPago: 'parcial', montoDeclarado: 300, registrado: 300, saldoAplicado: 0, saldoMostrado: 400, totalGuardado: 1000,
    })).toBeNull()
  })
})

describe('esSaldoAFavorAplicado', () => {
  it('un cobro común de la boleta no es saldo a favor aplicado', () => {
    expect(esSaldoAFavorAplicado({ pedido_id: '5' })).toBe(false)
    expect(esSaldoAFavorAplicado({ pedido_id: '5', de_saldo_a_favor: false, a_cuenta: false, pago_origen_id: null })).toBe(false)
  })

  it('un pago suelto no está aplicado a ninguna boleta, aunque conserve las marcas', () => {
    expect(esSaldoAFavorAplicado({ pedido_id: null, de_saldo_a_favor: true, a_cuenta: true, pago_origen_id: '9' })).toBe(false)
    expect(esSaldoAFavorAplicado({ de_saldo_a_favor: true })).toBe(false)
  })

  it('cada una de las tres marcas alcanza', () => {
    expect(esSaldoAFavorAplicado({ pedido_id: '5', de_saldo_a_favor: true })).toBe(true)
    expect(esSaldoAFavorAplicado({ pedido_id: '5', a_cuenta: true })).toBe(true)
    expect(esSaldoAFavorAplicado({ pedido_id: '5', pago_origen_id: '9' })).toBe(true)
    expect(esSaldoAFavorAplicado({ pedido_id: 5, pago_origen_id: 9 })).toBe(true)
  })
})
