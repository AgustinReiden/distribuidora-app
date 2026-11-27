import { describe, expect, it } from 'vitest'
import { partirDireccion, ubicacionesSospechosas, type ParadaUbicada } from './ubicacionSospechosa'

// El caso de #1717, con datos inventados: dos alturas del mismo pasaje
// guardadas con el punto de la calle (la misma coordenada), a 1,5 km del vecino
// que sí quedó bien.
const PUNTO_CALLE = { latitud: -26.84, longitud: -65.24 }
const vecinoBien: ParadaUbicada = {
  id: 'p1', direccion: 'Pje. Los Ceibos 298, T4000 San Miguel de Tucumán, Tucumán, Argentina',
  latitud: -26.8275, longitud: -65.2402,
}
const calleA: ParadaUbicada = {
  id: 'p2', direccion: 'Los Ceibos 248, T4000 San Miguel de Tucumán, Tucumán, Argentina', ...PUNTO_CALLE,
}
const calleB: ParadaUbicada = {
  id: 'p3', direccion: 'Los Ceibos 296, T4000 San Miguel de Tucumán, Tucumán, Argentina', ...PUNTO_CALLE,
}

describe('partirDireccion', () => {
  it('saca el tipo de vía, la altura y el código postal', () => {
    expect(partirDireccion('Pje. Benjamín Paz 298, T4000 San Miguel de Tucumán, Tucumán')).toEqual({
      calle: 'benjamin paz', altura: 298, localidad: 'san miguel de tucuman', linea: 'benjamin paz 298',
    })
    expect(partirDireccion('Av. 25 de Mayo 1450, T4107AEZ Yerba Buena')?.calle).toBe('25 de mayo')
    expect(partirDireccion('Gral. José María Paz 2743, T4000 San Miguel')?.calle).toBe('jose maria paz')
  })

  it('sin altura o sin dirección', () => {
    expect(partirDireccion('Ruta 9 km, Tafí')?.altura).toBeNull()
    expect(partirDireccion('')).toBeNull()
    expect(partirDireccion(null)).toBeNull()
  })
})

describe('ubicacionesSospechosas', () => {
  it('marca dos direcciones distintas con la misma coordenada exacta', () => {
    expect(ubicacionesSospechosas([calleA, calleB])).toEqual([
      { tipo: 'misma_coordenada', ids: ['p2', 'p3'], metros: 0 },
    ])
  })

  it('marca la misma cuadra a más de 400 m, aunque una diga «Pje.» y la otra no', () => {
    const r = ubicacionesSospechosas([vecinoBien, calleA])
    expect(r).toHaveLength(1)
    expect(r[0].tipo).toBe('lejos_en_la_misma_cuadra')
    expect(r[0].ids).toEqual(['p1', 'p2'])
    expect(r[0].metros).toBeGreaterThan(1_000)
  })

  it('el caso entero: el par de la misma coordenada sale una vez, y cada una contra el vecino', () => {
    const r = ubicacionesSospechosas([vecinoBien, calleA, calleB])
    expect(r.map(s => `${s.tipo}:${s.ids.join('-')}`)).toEqual([
      'lejos_en_la_misma_cuadra:p1-p2',
      'lejos_en_la_misma_cuadra:p1-p3',
      'misma_coordenada:p2-p3',
    ])
  })

  it('no marca vecinos bien ubicados', () => {
    const cerca = { ...calleA, latitud: -26.8270, longitud: -65.2401 }
    expect(ubicacionesSospechosas([vecinoBien, cerca])).toEqual([])
  })

  it('no marca la misma calle en otra localidad (calles homónimas)', () => {
    const otraLocalidad: ParadaUbicada = {
      id: 'p9', direccion: '9 de Julio 1250, T4107AEZ Yerba Buena, Tucumán', latitud: -26.819, longitud: -65.288,
    }
    const capital: ParadaUbicada = {
      id: 'p8', direccion: '9 de Julio 1276, T4000 San Miguel de Tucumán, Tucumán', latitud: -26.848, longitud: -65.209,
    }
    expect(ubicacionesSospechosas([otraLocalidad, capital])).toEqual([])
  })

  it('no marca alturas lejanas de la misma calle', () => {
    const lejos = { ...calleA, id: 'p4', direccion: 'Los Ceibos 1051, T4000 San Miguel de Tucumán' }
    expect(ubicacionesSospechosas([vecinoBien, lejos])).toEqual([])
  })

  it('dos pedidos del mismo cliente no son sospechosos', () => {
    expect(ubicacionesSospechosas([calleA, { ...calleA, id: 'p5' }])).toEqual([])
  })

  it('ignora las paradas sin coordenadas o sin dirección', () => {
    expect(ubicacionesSospechosas([
      { ...calleA, latitud: null },
      { ...calleB, direccion: null },
      vecinoBien,
    ])).toEqual([])
  })

  it('acepta coordenadas como texto (vienen así de numeric)', () => {
    const a = { ...calleA, latitud: '-26.84', longitud: '-65.24' }
    const b = { ...calleB, latitud: '-26.84', longitud: '-65.24' }
    expect(ubicacionesSospechosas([a, b])).toHaveLength(1)
  })
})
