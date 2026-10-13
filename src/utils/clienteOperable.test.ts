import { describe, it, expect } from 'vitest'
import { esClienteOperable } from './clienteOperable'

const YO = 'u-yo'
const OTRO = 'u-otro'
const prev = { rol: 'preventista', userId: YO }

describe('esClienteOperable', () => {
  it('preventista: opera con el cliente sin asignar', () => {
    expect(esClienteOperable({ preventista_ids: [] }, prev)).toBe(true)
    expect(esClienteOperable({}, prev)).toBe(true)
  })

  it('preventista: opera con el suyo, aunque esté compartido', () => {
    expect(esClienteOperable({ preventista_ids: [YO] }, prev)).toBe(true)
    expect(esClienteOperable({ preventista_ids: [OTRO, YO] }, prev)).toBe(true)
  })

  it('preventista: el cliente de otro es historial, no se opera', () => {
    expect(esClienteOperable({ preventista_ids: [OTRO] }, prev)).toBe(false)
  })

  it('preventista: el reservado no se opera aunque no tenga asignaciones', () => {
    // Un reservado nunca tiene preventista_ids: sin este chequeo pasaría por
    // "sin asignar", que es justo lo contrario.
    expect(esClienteOperable({ preventista_ids: [], reservado_admin: true }, prev)).toBe(false)
  })

  it('preventista sin id: no opera con nada', () => {
    expect(esClienteOperable({ preventista_ids: [] }, { rol: 'preventista', userId: null })).toBe(false)
  })

  it.each(['admin', 'encargado', 'transportista', 'deposito', null, undefined])(
    'rol %s: opera con todo lo que ve',
    rol => {
      expect(esClienteOperable({ preventista_ids: [OTRO], reservado_admin: true }, { rol, userId: YO })).toBe(true)
    },
  )
})
