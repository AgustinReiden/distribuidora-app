/**
 * Tests de `requestIdPersistente` (#1410): la clave de un cobro sobrevive a
 * cerrar el modal y a recargar la app, es de cada usuario, y deja de valer
 * cuando el cobro sale bien o vence.
 *
 * Cada test importa el módulo de cero (`vi.resetModules`): así "recargar la
 * app" es volver a importarlo con el mismo `localStorage`, y lo que quedó en
 * memoria de un test no tapa al siguiente.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

type Modulo = typeof import('./requestIdPersistente')

/** Importa el módulo de cero, con la sesión de `usuario` (como hace `useAuth`). */
async function cargar(usuario: string | null = 'u-ana'): Promise<Modulo> {
  vi.resetModules()
  const m = await import('./requestIdPersistente')
  m.fijarUsuarioRequestIds(usuario)
  return m
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

  it('la clave que ya tiene el modal manda sobre lo guardado, y se vuelve a guardar', async () => {
    const m = await cargar()
    const delModal = m.requestIdPersistente(HUELLA, T0)
    // Otra pestaña pisó el mapa (o venció, o el tope la sacó).
    localStorage.clear()
    expect(m.requestIdPersistente(HUELLA, T0 + 1000, delModal)).toBe(delModal)
    expect((await cargar()).requestIdPersistente(HUELLA, T0 + 2000)).toBe(delModal)
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
    localStorage.setItem('distribuidora:cobro-request-ids:u-ana', '{no es json')
    const m = await cargar()
    expect(m.requestIdPersistente(HUELLA, T0)).toMatch(/^[0-9a-f-]{36}$/)
  })
})

describe('requestIdPersistente — es de cada usuario', () => {
  it('la misma huella con otro usuario en el equipo lleva otra clave', async () => {
    const deAna = (await cargar('u-ana')).requestIdPersistente(HUELLA, T0)
    const deBeto = (await cargar('u-beto')).requestIdPersistente(HUELLA, T0 + 1000)
    expect(deBeto).not.toBe(deAna)
  })

  it('el cobro sin confirmar de un usuario no se le propone a otro', async () => {
    ;(await cargar('u-ana')).guardarCobroSinConfirmar(cobro, T0)
    expect((await cargar('u-beto')).leerCobroSinConfirmar('4625', T0 + 1000)).toBeNull()
    expect((await cargar('u-ana')).leerCobroSinConfirmar('4625', T0 + 1000)).not.toBeNull()
  })

  it('el logout borra lo del que sale y no lo de los demás', async () => {
    const ana = await cargar('u-ana')
    ana.requestIdPersistente(HUELLA, T0)
    ana.guardarCobroSinConfirmar(cobro, T0)
    const deBeto = (await cargar('u-beto')).requestIdPersistente(HUELLA, T0)

    ana.olvidarRequestIdsDe('u-ana')

    const anaOtraVez = await cargar('u-ana')
    expect(anaOtraVez.leerCobroSinConfirmar('4625', T0)).toBeNull()
    expect(localStorage.getItem('distribuidora:cobro-request-ids:u-ana')).toBeNull()
    expect((await cargar('u-beto')).requestIdPersistente(HUELLA, T0)).toBe(deBeto)
  })

  it('sin sesión no guarda nada en el dispositivo', async () => {
    const m = await cargar(null)
    m.requestIdPersistente(HUELLA, T0)
    expect(localStorage.length).toBe(0)
  })
})

const cobro = {
  pedidoId: '4625',
  fechaPago: '2026-11-04',
  observaciones: 'Pago al crear el pedido',
  pagos: [{ formaPago: 'efectivo', monto: 5000 }],
  clientRequestId: '11111111-1111-4111-8111-111111111111',
  pagadoAntes: 1000,
}

describe('cobro sin confirmar', () => {
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

  it('una entrada vieja, sin lo pagado antes, no se propone', async () => {
    const { pagadoAntes: _, ...sinPagado } = cobro
    localStorage.setItem('distribuidora:cobros-sin-confirmar:u-ana', JSON.stringify({
      4625: { id: cobro.clientRequestId, t: T0, cobro: sinPagado },
    }))
    expect((await cargar()).leerCobroSinConfirmar('4625', T0)).toBeNull()
  })

  it('estado: igual que antes no entró; más el cobro entró; otra cosa cambió por otro camino', async () => {
    const m = await cargar()
    expect(m.estadoCobroSinConfirmar(cobro, 1000)).toBe('no_entro')
    expect(m.estadoCobroSinConfirmar(cobro, 6000)).toBe('entro')
    expect(m.estadoCobroSinConfirmar(cobro, 3000)).toBe('cambio')
  })

  it('la huella del cobro sin confirmar es la que arma el modal con esos datos', async () => {
    const m = await cargar()
    expect(m.huellaCobroPedido({ ...cobro, observaciones: '  Pago al crear el pedido ' }))
      .toBe(m.huellaCobroPedido(cobro))
    expect(m.huellaCobroPedido({ ...cobro, pagos: [{ formaPago: 'efectivo', monto: 4999 }] }))
      .not.toBe(m.huellaCobroPedido(cobro))
  })
})

describe('cobrarRecordandoSinConfirmar', () => {
  const { clientRequestId, ...resto } = cobro
  const intento = { ...resto, clientRequestIds: [clientRequestId, 'otra'] }

  it('sin respuesta del server: queda guardado con la primera clave', async () => {
    const m = await cargar()
    const { ErrorDeSupabase } = await import('./errorDeSupabase')
    const sinRespuesta = new ErrorDeSupabase('Sin conexión: no se pudo confirmar el pago.', {}, true)

    await expect(m.cobrarRecordandoSinConfirmar(intento, () => Promise.reject(sinRespuesta))).rejects.toBe(sinRespuesta)

    expect(m.leerCobroSinConfirmar('4625')?.clientRequestId).toBe(clientRequestId)
  })

  it('un 5xx del gateway también: el server pudo haber seguido', async () => {
    const m = await cargar()
    const { ErrorDeSupabase } = await import('./errorDeSupabase')
    const gateway = new ErrorDeSupabase('Error del servidor (HTTP 502)', { code: 'HTTP_502' }, false)

    await expect(m.cobrarRecordandoSinConfirmar(intento, () => Promise.reject(gateway))).rejects.toBe(gateway)

    expect(m.leerCobroSinConfirmar('4625')).not.toBeNull()
  })

  it('un rechazo del server no se guarda: no entró y no hay nada que reintentar igual', async () => {
    const m = await cargar()
    const { ErrorDeSupabase } = await import('./errorDeSupabase')
    const rechazo = new ErrorDeSupabase('El monto supera lo que falta cobrar', { code: 'P0001' }, false)

    await expect(m.cobrarRecordandoSinConfirmar(intento, () => Promise.reject(rechazo))).rejects.toBe(rechazo)

    expect(m.leerCobroSinConfirmar('4625')).toBeNull()
  })

  it('si sale bien, borra el que había', async () => {
    const m = await cargar()
    m.guardarCobroSinConfirmar(cobro)
    await m.cobrarRecordandoSinConfirmar({ ...resto, clientRequestIds: [clientRequestId] }, () => Promise.resolve('ok'))
    expect(m.leerCobroSinConfirmar('4625')).toBeNull()
  })
})
