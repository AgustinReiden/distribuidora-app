/**
 * Tests de `requestIdPersistente` (#1410): la clave de un cobro sobrevive a
 * cerrar el modal y a recargar la app, y deja de valer cuando el cobro sale
 * bien o vence.
 *
 * Cada test importa el módulo de cero (`vi.resetModules`): así "recargar la
 * app" es volver a importarlo con el mismo `localStorage`, y lo que quedó en
 * memoria de un test no tapa al siguiente.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

type Modulo = typeof import('./requestIdPersistente')

async function cargar(): Promise<Modulo> {
  vi.resetModules()
  return import('./requestIdPersistente')
}

const T0 = Date.parse('2026-11-04T15:00:00Z')
const HUELLA = 'simple|303|4625|2026-11-04||5000|efectivo|'

beforeEach(() => {
  localStorage.clear()
})

describe('requestIdPersistente', () => {
  it('cerrar y reabrir con la misma huella da el mismo id', async () => {
    const m = await cargar()
    const primero = m.requestIdPersistente(HUELLA, T0)
    expect(m.requestIdPersistente(HUELLA, T0 + 30_000)).toBe(primero)
  })

  it('sobrevive a una recarga de la app', async () => {
    const primero = (await cargar()).requestIdPersistente(HUELLA, T0)
    const trasRecargar = await cargar()
    expect(trasRecargar.requestIdPersistente(HUELLA, T0 + 60_000)).toBe(primero)
  })

  it('una huella distinta da un id nuevo', async () => {
    const m = await cargar()
    const de5000 = m.requestIdPersistente(HUELLA, T0)
    expect(m.requestIdPersistente(HUELLA.replace('5000', '4000'), T0)).not.toBe(de5000)
  })

  it('vencido, da un id nuevo', async () => {
    const m = await cargar()
    const primero = m.requestIdPersistente(HUELLA, T0)
    expect(m.requestIdPersistente(HUELLA, T0 + m.VIGENCIA_REQUEST_ID_MS)).not.toBe(primero)
  })

  it('el plazo corre desde el último intento, no desde el primero', async () => {
    const m = await cargar()
    const v = m.VIGENCIA_REQUEST_ID_MS
    const primero = m.requestIdPersistente(HUELLA, T0)
    m.requestIdPersistente(HUELLA, T0 + v - 1)
    expect(m.requestIdPersistente(HUELLA, T0 + 2 * v - 2)).toBe(primero)
  })

  it('después de un cobro que salió bien, el id no se reusa', async () => {
    const m = await cargar()
    const cobrado = m.requestIdPersistente(HUELLA, T0)
    m.olvidarRequestIds([HUELLA], T0)
    expect((await cargar()).requestIdPersistente(HUELLA, T0 + 1000)).not.toBe(cobrado)
  })

  it('olvidar un cobro no toca las huellas de otro', async () => {
    const m = await cargar()
    const otro = m.requestIdPersistente('fifo|303|general', T0)
    m.requestIdPersistente(HUELLA, T0)
    m.olvidarRequestIds([HUELLA], T0)
    expect(m.requestIdPersistente('fifo|303|general', T0)).toBe(otro)
  })

  it('si localStorage tira, cerrar y reabrir sigue dando el mismo id', async () => {
    const getItem = vi.spyOn(localStorage, 'getItem').mockImplementation(() => { throw new Error('SecurityError') })
    const setItem = vi.spyOn(localStorage, 'setItem').mockImplementation(() => { throw new Error('QuotaExceededError') })
    try {
      const m = await cargar()
      const primero = m.requestIdPersistente(HUELLA, T0)
      expect(m.requestIdPersistente(HUELLA, T0 + 1000)).toBe(primero)
      m.olvidarRequestIds([HUELLA], T0 + 2000)
      expect(m.requestIdPersistente(HUELLA, T0 + 3000)).not.toBe(primero)
    } finally {
      getItem.mockRestore()
      setItem.mockRestore()
    }
  })

  it('si localStorage trae basura, arranca de cero sin romper', async () => {
    localStorage.setItem('distribuidora:cobro-request-ids', '{no es json')
    const m = await cargar()
    expect(m.requestIdPersistente(HUELLA, T0)).toMatch(/^[0-9a-f-]{36}$/)
  })
})

describe('cobro sin confirmar', () => {
  const cobro = {
    pedidoId: '4625',
    fechaPago: '2026-11-04',
    observaciones: 'Pago al crear el pedido',
    pagos: [{ formaPago: 'efectivo', monto: 5000 }],
    clientRequestId: '11111111-1111-4111-8111-111111111111',
  }

  it('se lee después de recargar, con su clave', async () => {
    ;(await cargar()).guardarCobroSinConfirmar(cobro, T0)
    expect((await cargar()).leerCobroSinConfirmar('4625', T0 + 60_000)).toEqual(cobro)
  })

  it('vence con el mismo plazo', async () => {
    const m = await cargar()
    m.guardarCobroSinConfirmar(cobro, T0)
    expect(m.leerCobroSinConfirmar('4625', T0 + m.VIGENCIA_REQUEST_ID_MS)).toBeNull()
  })

  it('guarda el monto al centavo, como lo lee el modal', async () => {
    const m = await cargar()
    m.guardarCobroSinConfirmar({ ...cobro, pagos: [{ formaPago: 'efectivo', monto: 1234.505000001 }] }, T0)
    expect(m.leerCobroSinConfirmar('4625', T0)?.pagos[0].monto).toBe(1234.51)
  })

  it('cobrarRecordandoSinConfirmar: si falla, queda guardado con la primera clave', async () => {
    const m = await cargar()
    const { clientRequestId, ...resto } = cobro
    await expect(
      m.cobrarRecordandoSinConfirmar({ ...resto, clientRequestIds: [clientRequestId, 'otra'] }, () =>
        Promise.reject(new Error('Sin conexión'))),
    ).rejects.toThrow('Sin conexión')
    expect(m.leerCobroSinConfirmar('4625')?.clientRequestId).toBe(clientRequestId)
  })

  it('cobrarRecordandoSinConfirmar: si sale bien, borra el que había', async () => {
    const m = await cargar()
    m.guardarCobroSinConfirmar(cobro)
    const { clientRequestId, ...resto } = cobro
    await m.cobrarRecordandoSinConfirmar({ ...resto, clientRequestIds: [clientRequestId] }, () => Promise.resolve('ok'))
    expect(m.leerCobroSinConfirmar('4625')).toBeNull()
  })

  it('la huella del cobro sin confirmar es la que arma el modal con esos datos', async () => {
    const m = await cargar()
    expect(m.huellaCobroPedido({ ...cobro, observaciones: '  Pago al crear el pedido ' }))
      .toBe(m.huellaCobroPedido(cobro))
    expect(m.huellaCobroPedido({ ...cobro, pagos: [{ formaPago: 'efectivo', monto: 4999 }] }))
      .not.toBe(m.huellaCobroPedido(cobro))
  })
})
