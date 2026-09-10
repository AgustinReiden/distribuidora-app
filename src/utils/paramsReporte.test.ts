import { describe, it, expect } from 'vitest'
import {
  esFechaValida,
  leerRango,
  leerSucursal,
  escribirRango,
  escribirSucursal,
  linkAReportes,
} from './paramsReporte'

const sp = (q: string): URLSearchParams => new URLSearchParams(q)

describe('esFechaValida', () => {
  it('acepta una fecha real en formato ISO corto', () => {
    expect(esFechaValida('2026-08-01')).toBe(true)
  })

  it('rechaza un día que no existe en el calendario', () => {
    // El constructor de Date normaliza 31/02 a 03/03 en silencio: sin la
    // comparación de vuelta, la pantalla mostraría un período que nadie pidió.
    expect(esFechaValida('2026-02-31')).toBe(false)
    expect(esFechaValida('2026-13-01')).toBe(false)
  })

  it('rechaza basura y vacío', () => {
    expect(esFechaValida('ayer')).toBe(false)
    expect(esFechaValida('')).toBe(false)
    expect(esFechaValida(null)).toBe(false)
  })
})

describe('leerRango', () => {
  it('devuelve el rango cuando las dos fechas son válidas', () => {
    expect(leerRango(sp('desde=2026-08-01&hasta=2026-08-31'))).toEqual({
      desde: '2026-08-01', hasta: '2026-08-31',
    })
  })

  it('un rango a medias se descarta ENTERO, no a medias', () => {
    // Aplicar media fecha dejaría la pantalla mostrando un período que no se
    // corresponde con lo que dice el selector.
    expect(leerRango(sp('desde=2026-08-01'))).toEqual({ desde: null, hasta: null })
    expect(leerRango(sp('hasta=2026-08-31'))).toEqual({ desde: null, hasta: null })
  })

  it('nunca devuelve un rango invertido', () => {
    expect(leerRango(sp('desde=2026-08-31&hasta=2026-08-01'))).toEqual({ desde: null, hasta: null })
  })

  it('sin params no hay rango: la pantalla usa su default', () => {
    expect(leerRango(sp(''))).toEqual({ desde: null, hasta: null })
  })
})

describe('leerSucursal', () => {
  it('distingue "no vino" de "red", que no son lo mismo', () => {
    // undefined deja que cada pantalla aplique su default; null es la red
    // pedida explícitamente.
    expect(leerSucursal(sp(''))).toBeUndefined()
    expect(leerSucursal(sp('suc=red'))).toBeNull()
  })

  it('lee un id numérico', () => {
    expect(leerSucursal(sp('suc=2'))).toBe(2)
  })

  it('un id inválido cae al default en vez de reventar el RPC', () => {
    // El RPC tira "Acceso denegado" ante una sucursal ajena; un 'abc' o un 0
    // no deberían llegar hasta ahí.
    expect(leerSucursal(sp('suc=abc'))).toBeUndefined()
    expect(leerSucursal(sp('suc=0'))).toBeUndefined()
    expect(leerSucursal(sp('suc=-3'))).toBeUndefined()
  })
})

describe('escribirRango', () => {
  it('round-trip: lo que se escribe se vuelve a leer igual', () => {
    const escrito = escribirRango(sp(''), '2026-08-01', '2026-08-31')
    expect(leerRango(escrito)).toEqual({ desde: '2026-08-01', hasta: '2026-08-31' })
  })

  it('limpiar el período borra los params en vez de dejarlos colgados', () => {
    const escrito = escribirRango(sp('desde=2026-08-01&hasta=2026-08-31&tab=mermas'), null, null)
    expect(escrito.get('desde')).toBeNull()
    expect(escrito.get('hasta')).toBeNull()
    // Y no se lleva puesto lo que no le corresponde.
    expect(escrito.get('tab')).toBe('mermas')
  })

  it('un rango inválido no se escribe', () => {
    const escrito = escribirRango(sp(''), '2026-08-31', '2026-08-01')
    expect(escrito.toString()).toBe('')
  })

  it('no muta los params originales', () => {
    const original = sp('tab=mermas')
    escribirRango(original, '2026-08-01', '2026-08-31')
    expect(original.get('desde')).toBeNull()
  })
})

describe('escribirSucursal', () => {
  it('round-trip de una sucursal y de la red', () => {
    expect(leerSucursal(escribirSucursal(sp(''), 2))).toBe(2)
    expect(leerSucursal(escribirSucursal(sp(''), null))).toBeNull()
  })
})

describe('linkAReportes', () => {
  it('lleva pestaña, período y sucursal', () => {
    const url = linkAReportes({ tab: 'mermas', desde: '2026-08-01', hasta: '2026-08-31', sucursalId: 1 })
    expect(url).toBe('/reportes?tab=mermas&desde=2026-08-01&hasta=2026-08-31&suc=1')
  })

  it('la red viaja como suc=red', () => {
    const url = linkAReportes({ tab: 'clientes', desde: '2026-08-01', hasta: '2026-08-31', sucursalId: null })
    expect(url).toContain('suc=red')
  })

  it('sin período, no inventa uno', () => {
    // Cuentas por Cobrar no tiene argumentos de fecha: el aging es siempre al
    // día de hoy. Mandarle un período que va a ignorar sería mentir con la URL.
    const url = linkAReportes({ tab: 'cuentas', sucursalId: 1 })
    expect(url).toBe('/reportes?tab=cuentas&suc=1')
    expect(url).not.toContain('desde')
  })

  it('un rango inválido no se propaga al link', () => {
    const url = linkAReportes({ tab: 'mermas', desde: '2026-08-31', hasta: '2026-08-01', sucursalId: 1 })
    expect(url).not.toContain('desde')
  })
})
