import { describe, it, expect } from 'vitest'
import { huellaDeAlta } from './huellaDeAlta'

type Alta = { id?: number | null; clave?: string; nombre?: string; monto?: number }
const alta = (a: Alta): Alta => a

describe('huellaDeAlta (reportes-R3, tanda 6 de #1603)', () => {
  it('el mismo alta da la misma huella, con o sin la clave puesta', () => {
    const a = alta({ nombre: 'X', monto: 10 })
    expect(huellaDeAlta(1, a)).toBe(huellaDeAlta(1, { ...a }))
    expect(huellaDeAlta(1, { ...a, clave: 'k' })).toBe(huellaDeAlta(1, a))
  })

  it('otro contenido u otra sucursal dan otra huella', () => {
    expect(huellaDeAlta(1, alta({ monto: 10 }))).not.toBe(huellaDeAlta(1, alta({ monto: 11 })))
    expect(huellaDeAlta(1, alta({ monto: 10 }))).not.toBe(huellaDeAlta(2, alta({ monto: 10 })))
  })

  it('una edición (con id) no tiene huella: no lleva clave', () => {
    expect(huellaDeAlta(1, alta({ id: 5 }))).toBeNull()
    expect(huellaDeAlta(1, alta({ id: null }))).not.toBeNull()
  })
})
