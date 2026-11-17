import { describe, it, expect } from 'vitest'
import { campoFechaDeEntrega, errorDeFechaEntrega, rangoFechaEntrega } from './fechaEntrega'

// Espejo de _fecha_entrega_fuera_de_rango (GTO-15, #1597): mismos bordes y mismos textos.
const hoy = '2026-11-15'

describe('rangoFechaEntrega', () => {
  it('quien no es admin: de hoy hasta los días de la política', () => {
    expect(rangoFechaEntrega({ esAdmin: false, diasAtras: 5, hoy })).toEqual({ min: '2026-11-10', max: hoy })
  })

  it('sin política, 7 días', () => {
    expect(rangoFechaEntrega({ esAdmin: false, diasAtras: undefined, hoy })).toEqual({ min: '2026-11-08', max: hoy })
  })

  it('el admin: hasta 60 días atrás, nunca después de hoy', () => {
    expect(rangoFechaEntrega({ esAdmin: true, diasAtras: 5, hoy })).toEqual({ min: '2026-09-16', max: hoy })
  })
})

describe('campoFechaDeEntrega (el campo de fecha de «Confirmar entrega»)', () => {
  it('arranca en hoy y lleva el piso y el techo de su rol', () => {
    const c = campoFechaDeEntrega({ esAdmin: false, diasAtras: 5, hoy })
    expect(c).toMatchObject({ label: 'Fecha de entrega', valorInicial: hoy, min: '2026-11-10', max: hoy })
    expect(campoFechaDeEntrega({ esAdmin: true, diasAtras: 5, hoy }).min).toBe('2026-09-16')
  })

  it('valida con el texto del server: lo de afuera del rango trae su motivo, lo de adentro no', () => {
    const c = campoFechaDeEntrega({ esAdmin: false, diasAtras: 5, hoy })
    expect(c.validar('2026-11-10')).toBeNull()
    expect(c.validar('2026-11-09')).toMatch(/no puede ser anterior al 10\/11\/2026/)
    expect(c.validar('2026-11-16')).toMatch(/no puede ser posterior a hoy/)
  })
})

describe('errorDeFechaEntrega', () => {
  it('el borde del piso entra y el día anterior no, con el texto del server', () => {
    const regla = { esAdmin: false, diasAtras: 5, hoy }
    expect(errorDeFechaEntrega('2026-11-10', regla)).toBeNull()
    expect(errorDeFechaEntrega(hoy, regla)).toBeNull()
    expect(errorDeFechaEntrega('2026-11-09', regla)).toBe(
      'La fecha de entrega (09/11/2026) no puede ser anterior al 10/11/2026: hasta 5 días atrás. Si la entrega es de antes, la carga un admin.',
    )
  })

  it('nadie con fecha futura, tampoco el admin', () => {
    const texto = 'La fecha de entrega (16/11/2026) no puede ser posterior a hoy.'
    expect(errorDeFechaEntrega('2026-11-16', { esAdmin: false, diasAtras: 7, hoy })).toBe(texto)
    expect(errorDeFechaEntrega('2026-11-16', { esAdmin: true, diasAtras: 7, hoy })).toBe(texto)
  })

  it('el admin: hoy-60 entra y hoy-61 no; una fecha de 2016 tampoco', () => {
    const regla = { esAdmin: true, diasAtras: 7, hoy }
    expect(errorDeFechaEntrega('2026-09-16', regla)).toBeNull()
    expect(errorDeFechaEntrega('2026-09-15', regla)).toBe(
      'La fecha de entrega (15/09/2026) no puede ser anterior al 16/09/2026: hasta 60 días atrás.',
    )
    expect(errorDeFechaEntrega('2016-11-12', regla)).not.toBeNull()
  })

  it('con 0 o 1 día, el texto cambia como en el server', () => {
    expect(errorDeFechaEntrega('2026-11-14', { esAdmin: false, diasAtras: 0, hoy })).toBe(
      'La fecha de entrega (14/11/2026) no puede ser anterior a hoy. Si la entrega es de antes, la carga un admin.',
    )
    expect(errorDeFechaEntrega('2026-11-13', { esAdmin: false, diasAtras: 1, hoy })).toContain('hasta 1 día atrás.')
  })

  it('una fecha vacía no se juzga, y una con hora se mide por el día', () => {
    expect(errorDeFechaEntrega('', { esAdmin: false, diasAtras: 7, hoy })).toBeNull()
    expect(errorDeFechaEntrega('2026-11-15T12:00:00-03:00', { esAdmin: false, diasAtras: 7, hoy })).toBeNull()
  })
})
