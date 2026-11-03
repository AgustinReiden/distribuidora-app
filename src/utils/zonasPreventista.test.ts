import { describe, it, expect } from 'vitest'
import {
  zonaSugeridaParaAlta,
  preventistasAlCambiarZona,
  textoConfirmacionLinkZona,
  asignacionContraLaBase,
  asignacionFueraDeZona,
  zonasDelPreventista,
  textoAvisoFueraDeZona,
} from './zonasPreventista'

// Dos barrios de Tucumán a ~11 km: centro y Banda del Río Salí.
const SMT = { lat: -26.8241, lng: -65.2226 }
const BANDA = { lat: -26.8419, lng: -65.1178 }

const cerca = (base: { lat: number; lng: number }, i: number) => ({
  lat: base.lat + i * 0.001,
  lng: base.lng + i * 0.001,
})

const clientes = [
  ...[1, 2, 3].map(i => ({ id: `c${i}`, zona_id: 'z-centro', latitud: cerca(SMT, i).lat, longitud: cerca(SMT, i).lng })),
  ...[4, 5, 6].map(i => ({ id: `c${i}`, zona_id: 'z-banda', latitud: cerca(BANDA, i).lat, longitud: cerca(BANDA, i).lng })),
  // Zona con un solo cliente ubicado: no alcanza para centroide.
  { id: 'c7', zona_id: 'z-chica', latitud: SMT.lat, longitud: SMT.lng },
]

describe('zonaSugeridaParaAlta', () => {
  it('sin zonas propias no sugiere nada', () => {
    expect(zonaSugeridaParaAlta([], SMT, clientes)).toBeNull()
  })

  it('con una sola zona la sugiere aunque no haya coordenada', () => {
    expect(zonaSugeridaParaAlta(['z-banda'], null, clientes)).toBe('z-banda')
  })

  it('con varias elige la de centroide más cercano', () => {
    expect(zonaSugeridaParaAlta(['z-centro', 'z-banda'], SMT, clientes)).toBe('z-centro')
    expect(zonaSugeridaParaAlta(['z-centro', 'z-banda'], BANDA, clientes)).toBe('z-banda')
  })

  it('con varias y sin coordenada no adivina', () => {
    expect(zonaSugeridaParaAlta(['z-centro', 'z-banda'], null, clientes)).toBeNull()
    expect(zonaSugeridaParaAlta(['z-centro', 'z-banda'], { lat: 0, lng: 0 }, clientes)).toBeNull()
  })

  it('ignora las zonas sin centroide y, si ninguna tiene, no adivina', () => {
    expect(zonaSugeridaParaAlta(['z-chica', 'z-banda'], SMT, clientes)).toBe('z-banda')
    expect(zonaSugeridaParaAlta(['z-chica', 'z-vacia'], SMT, clientes)).toBeNull()
  })
})

describe('preventistasAlCambiarZona', () => {
  const duenios = new Map([['z1', 'p-vic']])

  it('la zona con dueño deja sólo al dueño', () => {
    expect(preventistasAlCambiarZona('z1', duenios, ['p-osv', 'p-mar'], false)).toEqual(['p-vic'])
  })

  it('la zona sin dueño conserva lo que había', () => {
    expect(preventistasAlCambiarZona('z2', duenios, ['p-osv'], false)).toEqual(['p-osv'])
  })

  it('sin zona conserva lo que había', () => {
    expect(preventistasAlCambiarZona('', duenios, ['p-osv'], false)).toEqual(['p-osv'])
  })

  it('el reservado a administración no recibe preventista', () => {
    expect(preventistasAlCambiarZona('z1', duenios, [], true)).toEqual([])
  })
})

describe('asignacionContraLaBase (#1316)', () => {
  it('sin cambiar zona ni liberar un reservado, guarda la diferencia', () => {
    expect(asignacionContraLaBase({ zona_id: 5, reservado_admin: false }, '5', false, ['p'])).toBe(false)
    expect(asignacionContraLaBase({ zona_id: null }, '', false, [])).toBe(false)
  })
  it('cambiar la zona reemplaza lo de la base, aun con la lista vacía', () => {
    expect(asignacionContraLaBase({ zona_id: 5 }, '6', false, ['pedro'])).toBe(true)
    expect(asignacionContraLaBase({ zona_id: 5 }, '6', false, [])).toBe(true)
    expect(asignacionContraLaBase({ zona_id: null }, '6', false, [])).toBe(true)
  })
  it('liberar un reservado eligiendo preventista reemplaza; sin elegir, queda el dueño de la zona', () => {
    expect(asignacionContraLaBase({ zona_id: 5, reservado_admin: true }, '5', false, ['pedro'])).toBe(true)
    expect(asignacionContraLaBase({ zona_id: 5, reservado_admin: true }, '5', false, [])).toBe(false)
  })
  it('reservar no reemplaza: el trigger de la base ya vacía la asignación', () => {
    expect(asignacionContraLaBase({ zona_id: 5, reservado_admin: false }, '5', true, [])).toBe(false)
  })
})

describe('textoConfirmacionLinkZona', () => {
  const base = { clientes_zona: 65, cambian: 7, reservados: 0, quitados: [{ nombre: 'Ana', clientes: 6 }, { nombre: 'Beto', clientes: 1 }] }

  it('linkear: cuenta cuántos cambian y a quién se le sacan', () => {
    expect(textoConfirmacionLinkZona('ZONA 1', 'Caro', base)).toEqual([
      'Linkear "ZONA 1" con Caro: 7 de los 65 clientes de la zona pasan a ser sólo de Caro.',
      'Se le sacan a Ana (6), Beto (1). Siguen viendo sus pedidos viejos, pero ya no les cargan pedidos nuevos.',
    ])
  })

  it('linkear sin cambios lo dice', () => {
    const t = textoConfirmacionLinkZona('ZONA 1', 'Caro', { ...base, cambian: 0, quitados: [] })
    expect(t).toEqual(['Linkear "ZONA 1" con Caro. Los clientes de la zona ya son todos de Caro.'])
  })

  it('menciona los reservados que no se tocan', () => {
    const t = textoConfirmacionLinkZona('ZONA 1', 'Caro', { ...base, reservados: 1, quitados: [] })
    expect(t[t.length - 1]).toBe('El cliente reservado a administración no se toca.')
  })

  it('uno solo cambia: concuerda en singular', () => {
    const t = textoConfirmacionLinkZona('ZONA 1', 'Caro', { ...base, cambian: 1, quitados: [] })
    expect(t[0]).toBe('Linkear "ZONA 1" con Caro: 1 de los 65 clientes de la zona pasa a ser sólo de Caro.')
  })

  it('quitar: los clientes conservan su preventista', () => {
    expect(textoConfirmacionLinkZona('ZONA 1', null, base)[1]).toMatch(/^Sus 65 clientes conservan el preventista que tienen hoy\./)
    expect(textoConfirmacionLinkZona('ZONA 1', null, { ...base, clientes_zona: 1 })[1]).toMatch(/^Su cliente conserva el preventista que tiene hoy\./)
  })
})

describe('asignacionFueraDeZona (#1385)', () => {
  const duenios = new Map([['z1', 'p-vic'], ['z3', 'p-vic'], ['z2', 'p-osv']])
  const admin = { esAdmin: true }
  const form = (zona_id: string, preventista_ids: string[], reservado_admin = false) => ({
    zona_id, preventista_ids, reservado_admin,
  })

  it('el dueño solo está bien', () => {
    expect(asignacionFueraDeZona(form('z1', ['p-vic']), duenios, admin)).toBeNull()
  })

  it('otro que el dueño se avisa', () => {
    expect(asignacionFueraDeZona(form('z1', ['p-osv']), duenios, admin))
      .toEqual({ duenio: 'p-vic', ajenos: ['p-osv'] })
  })

  it('el dueño con otro también: ASG-A pide el dueño y nadie más', () => {
    expect(asignacionFueraDeZona(form('z1', ['p-vic', 'p-osv']), duenios, admin))
      .toEqual({ duenio: 'p-vic', ajenos: ['p-osv'] })
  })

  it('sin asignar en una zona con dueño se avisa', () => {
    expect(asignacionFueraDeZona(form('z1', []), duenios, admin))
      .toEqual({ duenio: 'p-vic', ajenos: [] })
  })

  it('una zona sin dueño admite cualquier asignación, o ninguna', () => {
    expect(asignacionFueraDeZona(form('z9', ['p-osv']), duenios, admin)).toBeNull()
    expect(asignacionFueraDeZona(form('z9', []), duenios, admin)).toBeNull()
  })

  it('sin zona no hay nada que avisar', () => {
    expect(asignacionFueraDeZona(form('', ['p-osv']), duenios, admin)).toBeNull()
  })

  it('un reservado no lleva preventistas y la zona no lo toca', () => {
    expect(asignacionFueraDeZona(form('z1', [], true), duenios, admin)).toBeNull()
  })

  it('liberar un reservado sin elegir a nadie no avisa: el trigger se lo da al dueño', () => {
    expect(asignacionFueraDeZona(form('z1', []), duenios, { esAdmin: true, reservadoCargado: true })).toBeNull()
  })

  it('liberar un reservado eligiendo a otro sí avisa', () => {
    expect(asignacionFueraDeZona(form('z1', ['p-osv']), duenios, { esAdmin: true, reservadoCargado: true }))
      .toEqual({ duenio: 'p-vic', ajenos: ['p-osv'] })
  })

  it('el que no es admin no elige preventistas', () => {
    expect(asignacionFueraDeZona(form('z1', ['p-osv']), duenios, { esAdmin: false })).toBeNull()
  })

  it('zonasDelPreventista trae las suyas y nada más', () => {
    expect(zonasDelPreventista('p-vic', duenios)).toEqual(['z1', 'z3'])
    expect(zonasDelPreventista('p-nadie', duenios)).toEqual([])
  })
})

describe('textoAvisoFueraDeZona (#1385)', () => {
  it('nombra al dueño, al elegido y lo que va a pasar', () => {
    const { titulo, mensaje } = textoAvisoFueraDeZona('Zona 1', 'Víctor', ['Osvaldo'], false, true)
    expect(titulo).toBe('El preventista no es el de la zona')
    expect(mensaje).toContain('La zona "Zona 1" es de Víctor y el cliente queda asignado a Osvaldo.')
    expect(mensaje).toContain('Cuando se vincule la zona, el cliente vuelve a Víctor.')
    expect(mensaje).toContain('Si lo atiende Osvaldo, pasalo a una de sus zonas:')
  })

  it('si el elegido no tiene zonas, dice qué hacer', () => {
    const { mensaje } = textoAvisoFueraDeZona('Zona 1', 'Víctor', ['Osvaldo'], false, false)
    expect(mensaje).toContain('Osvaldo no tiene zonas')
  })

  it('con el dueño y otro, lo dice distinto', () => {
    const { mensaje } = textoAvisoFueraDeZona('Zona 1', 'Víctor', ['Osvaldo'], true, true)
    expect(mensaje).toContain('es sólo de Víctor y el cliente también queda asignado a Osvaldo')
  })

  it('con dos ajenos no ofrece zonas: ninguna deja a los dos', () => {
    const { mensaje } = textoAvisoFueraDeZona('Zona 1', 'Víctor', ['Osvaldo', 'Marta'], false, false)
    expect(mensaje).toContain('queda asignado a Osvaldo, Marta')
    expect(mensaje).not.toContain('sus zonas')
    expect(mensaje).not.toContain('no tiene zonas')
  })

  it('sin asignar tiene su propio título', () => {
    const { titulo, mensaje } = textoAvisoFueraDeZona('Zona 1', 'Víctor', [], false, false)
    expect(titulo).toBe('El cliente queda sin preventista')
    expect(mensaje).toContain('lo ven todos los preventistas')
  })
})
