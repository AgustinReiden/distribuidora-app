import { describe, it, expect } from 'vitest'
import {
  motivoDatosDePrecio,
  resumirDatosDePrecio,
  sePuedeReintentarDatos,
  type EntradaDatoDePrecio,
} from './datosDePrecio'

const ok = (nombre: string): EntradaDatoDePrecio =>
  ({ nombre, hayDato: true, cargando: false, fallo: false, sinSenal: false })
const cargando = (nombre: string): EntradaDatoDePrecio =>
  ({ nombre, hayDato: false, cargando: true, fallo: false, sinSenal: false })
const cayo = (nombre: string): EntradaDatoDePrecio =>
  ({ nombre, hayDato: false, cargando: false, fallo: true, sinSenal: false })
const pausada = (nombre: string): EntradaDatoDePrecio =>
  ({ nombre, hayDato: false, cargando: false, fallo: false, sinSenal: true })

describe('datosDePrecio (FRV-1, #1559)', () => {
  it('con todo cargado no hay motivo ni nada que reintentar', () => {
    const r = resumirDatosDePrecio([ok('las escalas mayoristas'), ok('las promociones')])
    expect(motivoDatosDePrecio(r, { bloqueaSinSenal: true })).toBeNull()
    expect(sePuedeReintentarDatos(r, { bloqueaSinSenal: true })).toBe(false)
  })

  it('con las escalas caídas dice cuáles y se puede reintentar', () => {
    const r = resumirDatosDePrecio([cayo('las escalas mayoristas'), ok('las promociones')])
    expect(r.fallaron).toEqual(['las escalas mayoristas'])
    const motivo = motivoDatosDePrecio(r, { bloqueaSinSenal: false })
    expect(motivo).toMatch(/No se pudieron cargar las escalas mayoristas/)
    expect(sePuedeReintentarDatos(r, { bloqueaSinSenal: false })).toBe(true)
  })

  it('con varias caídas las nombra a todas', () => {
    const r = resumirDatosDePrecio([cayo('las promociones'), cayo('los mínimos de venta'), cayo('los combos')])
    expect(motivoDatosDePrecio(r, { bloqueaSinSenal: false }))
      .toMatch(/las promociones, los mínimos de venta y los combos/)
  })

  it('mientras carga bloquea pero no ofrece reintentar', () => {
    const r = resumirDatosDePrecio([cargando('las promociones'), ok('los combos')])
    expect(motivoDatosDePrecio(r, { bloqueaSinSenal: false })).toMatch(/Todavía se están cargando las promociones/)
    expect(sePuedeReintentarDatos(r, { bloqueaSinSenal: false })).toBe(false)
  })

  it('una falla manda sobre una carga en curso', () => {
    const r = resumirDatosDePrecio([cargando('los combos'), cayo('las escalas mayoristas')])
    expect(motivoDatosDePrecio(r, { bloqueaSinSenal: false })).toMatch(/No se pudieron cargar las escalas mayoristas/)
  })

  it('sin señal y sin dato: el alta no bloquea (se encola), la edición sí', () => {
    const r = resumirDatosDePrecio([pausada('las escalas mayoristas')])
    expect(motivoDatosDePrecio(r, { bloqueaSinSenal: false })).toBeNull()
    expect(sePuedeReintentarDatos(r, { bloqueaSinSenal: false })).toBe(false)
    expect(motivoDatosDePrecio(r, { bloqueaSinSenal: true })).toMatch(/Sin conexión/)
    expect(sePuedeReintentarDatos(r, { bloqueaSinSenal: true })).toBe(true)
  })

  it('una consulta con dato viejo y sin error no figura en ninguna lista', () => {
    const r = resumirDatosDePrecio([{ nombre: 'los combos', hayDato: true, cargando: false, fallo: false, sinSenal: true }])
    expect(r).toEqual({ cargando: [], fallaron: [], sinSenal: [] })
  })
})
