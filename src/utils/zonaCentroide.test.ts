import { describe, it, expect } from 'vitest'
import {
  centroideZona,
  chequearCoordenadaEnZona,
  MIN_CLIENTES_PARA_CENTROIDE,
  UMBRAL_LEJOS_DE_ZONA_METROS,
} from './zonaCentroide'

// San Miguel de Tucumán y Banda del Río Salí: el caso real que motivó esto
// (Chacabuco vs Batalla de Chacabuco). Están a ~11 km.
const SMT = { lat: -26.8241, lng: -65.2226 }
const BANDA = { lat: -26.8419, lng: -65.1178 }

const cliente = (id: string, zona: string, lat: number, lng: number) => ({
  id, zona_id: zona, latitud: lat, longitud: lng,
})

const zonaSMT = [
  cliente('1', 'z1', SMT.lat, SMT.lng),
  cliente('2', 'z1', SMT.lat + 0.005, SMT.lng),
  cliente('3', 'z1', SMT.lat, SMT.lng + 0.005),
]

describe('centroideZona', () => {
  it('no devuelve centroide con muestra insuficiente', () => {
    expect(centroideZona(zonaSMT.slice(0, MIN_CLIENTES_PARA_CENTROIDE - 1), 'z1')).toBeNull()
  })

  it('promedia solo los clientes de la zona pedida', () => {
    const conOtraZona = [...zonaSMT, cliente('9', 'z2', BANDA.lat, BANDA.lng)]
    const r = centroideZona(conOtraZona, 'z1')
    expect(r?.muestra).toBe(3)
    expect(r?.centro.lat).toBeCloseTo((SMT.lat * 2 + (SMT.lat + 0.005)) / 3, 5)
  })

  it('ignora coordenadas nulas y el (0,0) del que nunca se cargó', () => {
    const sucios = [
      ...zonaSMT,
      { id: '7', zona_id: 'z1', latitud: null, longitud: null },
      cliente('8', 'z1', 0, 0),
    ]
    expect(centroideZona(sucios, 'z1')?.muestra).toBe(3)
  })

  it('excluye al cliente que se está editando, para no compararlo consigo mismo', () => {
    expect(centroideZona(zonaSMT, 'z1', '1')).toBeNull() // quedan 2 < 3
  })
})

describe('chequearCoordenadaEnZona', () => {
  it('una dirección dentro de la zona no dispara alerta', () => {
    const r = chequearCoordenadaEnZona({ latitud: SMT.lat, longitud: SMT.lng }, zonaSMT, 'z1')
    expect(r.lejos).toBe(false)
    expect(r.distanciaMetros).toBeLessThan(UMBRAL_LEJOS_DE_ZONA_METROS)
    expect(r.muestra).toBe(3)
  })

  it('la calle homónima en la otra localidad sí dispara alerta', () => {
    const r = chequearCoordenadaEnZona({ latitud: BANDA.lat, longitud: BANDA.lng }, zonaSMT, 'z1')
    expect(r.lejos).toBe(true)
    expect(r.distanciaMetros).toBeGreaterThan(UMBRAL_LEJOS_DE_ZONA_METROS)
  })

  it('sin zona, sin coords o con muestra chica no evalúa nada', () => {
    expect(chequearCoordenadaEnZona({ latitud: SMT.lat, longitud: SMT.lng }, zonaSMT, null).distanciaMetros).toBeNull()
    expect(chequearCoordenadaEnZona({ latitud: null, longitud: null }, zonaSMT, 'z1').distanciaMetros).toBeNull()
    expect(chequearCoordenadaEnZona({ latitud: SMT.lat, longitud: SMT.lng }, zonaSMT.slice(0, 2), 'z1').distanciaMetros).toBeNull()
  })

  it('una coordenada en (0,0) no se compara: es "sin cargar", no "lejos"', () => {
    expect(chequearCoordenadaEnZona({ latitud: 0, longitud: 0 }, zonaSMT, 'z1').lejos).toBe(false)
  })
})
