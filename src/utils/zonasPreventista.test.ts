import { describe, it, expect } from 'vitest'
import { zonaSugeridaParaAlta, preventistasAlCambiarZona, textoConfirmacionLinkZona } from './zonasPreventista'

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
