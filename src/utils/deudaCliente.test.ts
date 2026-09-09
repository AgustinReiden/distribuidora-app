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
import { avisoDeudaCliente } from './deudaCliente'

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
