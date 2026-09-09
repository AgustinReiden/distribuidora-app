/**
 * Tests del aviso de deuda.
 *
 * POR QUE NO HAY CASOS DE "DESCONTAR ESTE PEDIDO"
 * ----------------------------------------------
 * Los había, y pasaban: verificaban que del saldo se restara la parte impaga
 * del pedido de la tarjeta para quedarse con "lo anterior". El cálculo era
 * correcto y la premisa no: `saldo_cuenta` es del presente, así que lo que
 * quedaba incluía los pedidos POSTERIORES y cada pedido nuevo inflaba el aviso
 * de las tarjetas viejas. Los tests verdes le daban respaldo a un modelo mental
 * equivocado. Se fueron con el cálculo.
 *
 * Lo que queda es formateo de un monto que el llamador ya decidió.
 */
import { describe, it, expect } from 'vitest'
import { avisoDeudaCliente, bloqueDeudaComanda } from './deudaCliente'

describe('avisoDeudaCliente', () => {
  it('no avisa cuando el cliente está al día', () => {
    expect(avisoDeudaCliente(0)).toBeNull()
  })

  it('no avisa cuando el cliente tiene saldo a favor', () => {
    // saldo_cuenta negativo = a favor del cliente (COMMENT de la columna).
    expect(avisoDeudaCliente(-5000)).toBeNull()
  })

  it('no avisa sin dato', () => {
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

  it('redondea a centavos: no muestra restos de float', () => {
    expect(avisoDeudaCliente(0.1 + 0.2)?.monto).toBe(0.3)
  })
})

describe('avisoDeudaCliente — monto posiblemente viejo (offline)', () => {
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

describe('bloqueDeudaComanda', () => {
  it('no imprime nada cuando el cliente no debe', () => {
    expect(bloqueDeudaComanda(0, [])).toBeNull()
    expect(bloqueDeudaComanda(null, null)).toBeNull()
  })

  it('lista cada boleta con su numero y fecha', () => {
    const bloque = bloqueDeudaComanda(20000, [
      { id: 1234, fecha: '2026-08-15', monto: 12000 },
      { id: 1250, fecha: '2026-08-22', monto: 8000 },
    ])
    expect(bloque?.total).toBe(20000)
    expect(bloque?.lineas).toEqual([
      { etiqueta: '#1234 15/08', monto: 12000 },
      { etiqueta: '#1250 22/08', monto: 8000 },
    ])
  })

  it('no corre la fecha de dia', () => {
    // "2026-08-01" con `new Date` en UTC-3 daria 31/07. Por eso se parsea a mano.
    const bloque = bloqueDeudaComanda(1000, [{ id: 1, fecha: '2026-08-01', monto: 1000 }])
    expect(bloque?.lineas[0].etiqueta).toBe('#1 01/08')
  })

  it('agrupa las boletas que no entran en el papel, y el desglose sigue sumando el total', () => {
    const boletas = Array.from({ length: 10 }, (_, i) => ({
      id: i + 1, fecha: '2026-08-10', monto: 1000,
    }))
    const bloque = bloqueDeudaComanda(10000, boletas, { maxLineas: 4 })
    expect(bloque?.lineas).toHaveLength(4)
    expect(bloque?.lineas[3]).toEqual({ etiqueta: 'y 7 boletas mas', monto: 7000 })
    const suma = bloque!.lineas.reduce((t, l) => t + l.monto, 0)
    expect(suma).toBe(bloque!.total)
  })

  it('singulariza "y 1 boleta mas"', () => {
    const boletas = Array.from({ length: 3 }, (_, i) => ({ id: i + 1, monto: 100 }))
    const bloque = bloqueDeudaComanda(300, boletas, { maxLineas: 2 })
    expect(bloque?.lineas[1].etiqueta).toBe('y 2 boletas mas')
  })

  it('cierra el desglose con el pago a cuenta que no esta imputado', () => {
    // Boletas por 20.000 pero el cliente tiene 5.000 a cuenta: debe 15.000.
    const bloque = bloqueDeudaComanda(15000, [{ id: 1, fecha: '2026-08-15', monto: 20000 }])
    expect(bloque?.total).toBe(15000)
    expect(bloque?.lineas[1]).toEqual({ etiqueta: 'A cuenta', monto: -5000 })
    const suma = bloque!.lineas.reduce((t, l) => t + l.monto, 0)
    expect(suma).toBe(15000)
  })

  it('cuadra aunque la base no haya mandado el detalle', () => {
    // Una query que pide deuda_previa pero no el detalle: mejor una linea sin
    // desglose que un ticket que dice "debe $X" y abajo no muestra nada.
    const bloque = bloqueDeudaComanda(20000, [])
    expect(bloque?.lineas).toEqual([{ etiqueta: 'Otros', monto: 20000 }])
  })

  it('descarta boletas en cero en vez de imprimir lineas vacias', () => {
    const bloque = bloqueDeudaComanda(5000, [
      { id: 1, fecha: '2026-08-15', monto: 5000 },
      { id: 2, fecha: '2026-08-16', monto: 0 },
    ])
    expect(bloque?.lineas).toHaveLength(1)
  })
})
