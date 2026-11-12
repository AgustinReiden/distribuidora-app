/**
 * La clave del alta (`pedidos.offline_id`, mig 071) y su duda (#1543).
 *
 * El principio: nunca se acuña una clave nueva mientras no se sepa qué pasó con
 * la anterior. Un intento perdido después del COMMIT seguido de una edición
 * acuñaba otra clave y creaba un segundo pedido.
 */
import { describe, it, expect } from 'vitest'
import {
  claveDeAlta,
  pasoDeAlta,
  decidirTrasVerificar,
  enDudaTrasFallo,
  mensajeAltaQueYaHabiaEntrado,
  type ClaveDeAlta,
} from './idempotencia'
import { errorDeSupabase } from './errorDeSupabase'
import { RechazoDeNegocioError } from './rechazoDeNegocio'
import { PlazoDeRedVencido } from './retryWithBackoff'

const previa = (enDuda: boolean): ClaveDeAlta => ({ id: 'clave-1', huella: 'h1', enDuda })

describe('claveDeAlta', () => {
  it('con la misma huella reusa la clave', () => {
    expect(claveDeAlta(previa(false), 'h1')).toEqual(previa(false))
  })

  it('con otra huella acuña otra', () => {
    const nueva = claveDeAlta(previa(false), 'h2')
    expect(nueva.id).not.toBe('clave-1')
    expect(nueva.huella).toBe('h2')
  })

  it('sin anterior acuña una', () => {
    expect(claveDeAlta(null, 'h1').id).toBeTruthy()
  })
})

describe('pasoDeAlta', () => {
  it('misma huella: reusa la clave aunque esté en duda (el server contesta idempotente)', () => {
    expect(pasoDeAlta(previa(true), 'h1')).toEqual({ paso: 'enviar', clave: previa(true) })
  })

  it('huella distinta sin duda: acuña otra sin preguntar', () => {
    const paso = pasoDeAlta(previa(false), 'h2')
    expect(paso.paso).toBe('enviar')
    if (paso.paso !== 'enviar') return
    expect(paso.clave.id).not.toBe('clave-1')
    expect(paso.clave.enDuda).toBeFalsy()
  })

  it('huella distinta con la anterior en duda: primero se verifica la anterior', () => {
    expect(pasoDeAlta(previa(true), 'h2')).toEqual({ paso: 'verificar', anterior: previa(true) })
  })

  it('sin anterior: acuña', () => {
    expect(pasoDeAlta(null, 'h1').paso).toBe('enviar')
  })
})

describe('decidirTrasVerificar', () => {
  it('entró: no se crea otro pedido', () => {
    expect(decidirTrasVerificar({ resultado: 'entro', pedidoId: '501' }, 'h2'))
      .toEqual({ paso: 'ya_entro', pedidoId: '501' })
  })

  it('no entró: clave nueva, fuera de duda, con la huella nueva', () => {
    const d = decidirTrasVerificar({ resultado: 'no_entro' }, 'h2')
    expect(d.paso).toBe('enviar')
    if (d.paso !== 'enviar') return
    expect(d.clave.id).toBeTruthy()
    expect(d.clave.id).not.toBe('clave-1')
    expect(d.clave.huella).toBe('h2')
    expect(d.clave.enDuda).toBeFalsy()
  })

  it('no se pudo preguntar: no se crea ni se encola nada', () => {
    expect(decidirTrasVerificar({ resultado: 'sin_respuesta' }, 'h2')).toEqual({ paso: 'esperar_senal' })
  })
})

describe('enDudaTrasFallo', () => {
  const sinRed = errorDeSupabase({ message: 'TypeError: Failed to fetch', code: '' }, 'Sin conexión')

  it('un fallo de red deja la clave en duda', () => {
    expect(sinRed.sinServidor).toBe(true)
    expect(enDudaTrasFallo(false, sinRed)).toBe(true)
  })

  it('el plazo vencido, un 5xx de gateway y un Error sin código también', () => {
    expect(enDudaTrasFallo(false, new PlazoDeRedVencido(20_000))).toBe(true)
    expect(enDudaTrasFallo(false, errorDeSupabase({ message: 'gateway', code: 'HTTP_524' }, 'x'))).toBe(true)
    expect(enDudaTrasFallo(false, new Error('algo raro'))).toBe(true)
  })

  it('un rechazo de negocio la saca de duda: la RPC busca la clave antes de validar', () => {
    expect(enDudaTrasFallo(true, new RechazoDeNegocioError('Stock insuficiente para Coca'))).toBe(false)
    expect(enDudaTrasFallo(false, new RechazoDeNegocioError('Compra mínima'))).toBe(false)
  })

  it('"ya se sincronizó en otra sucursal" la deja en duda (JWT vencido sobre el pedido propio)', () => {
    expect(enDudaTrasFallo(false, new RechazoDeNegocioError('Este pedido ya se sincronizo en otra sucursal'))).toBe(true)
  })

  it('un error con código del servidor no cambia la duda que había', () => {
    const permiso = errorDeSupabase({ message: 'permission denied', code: '42501' }, 'x')
    expect(enDudaTrasFallo(false, permiso)).toBe(false)
    expect(enDudaTrasFallo(true, permiso)).toBe(true)
    expect(enDudaTrasFallo(false, errorDeSupabase({ message: 'no', code: 'HTTP_403' }, 'x'))).toBe(false)
  })
})

describe('mensajeAltaQueYaHabiaEntrado', () => {
  it('nombra el pedido, dice que lo cambiado no está, y avisa del cobro si se declaró', () => {
    const m = mensajeAltaQueYaHabiaEntrado('501', true)
    expect(m).toContain('#501')
    expect(m).toMatch(/NO está en ese pedido/)
    expect(m).toMatch(/cobro no quedó registrado/)
    expect(mensajeAltaQueYaHabiaEntrado('501', false)).not.toMatch(/cobro/)
  })
})
