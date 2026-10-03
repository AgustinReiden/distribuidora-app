import { describe, it, expect } from 'vitest'
import { filtrarOpciones, normalizarBusqueda, hayCoincidenciaExacta } from './filtrarOpciones'

interface Prov { id: string; nombre: string; cuit: string | null }

const PROVS: Prov[] = [
  { id: '1', nombre: 'José Farías e Hijos SRL', cuit: '30-71234567-8' },
  { id: '2', nombre: 'Manaos SA', cuit: null },
  { id: '3', nombre: 'Distribuidora Norte', cuit: '20-11111111-1' },
  { id: '4', nombre: 'Aguas Manantial', cuit: null },
]
const textos = (p: Prov) => [p.nombre, p.cuit]
const ids = (r: Prov[]) => r.map(p => p.id)

describe('normalizarBusqueda', () => {
  it('minúsculas, sin tildes, espacios colapsados', () => {
    expect(normalizarBusqueda('  José   FARÍAS ')).toBe('jose farias')
  })
})

describe('filtrarOpciones', () => {
  it('consulta vacía devuelve todas en orden, respetando el límite', () => {
    expect(ids(filtrarOpciones(PROVS, '  ', textos))).toEqual(['1', '2', '3', '4'])
    expect(ids(filtrarOpciones(PROVS, '', textos, 2))).toEqual(['1', '2'])
  })

  it('encuentra sin tildes y sin importar mayúsculas', () => {
    expect(ids(filtrarOpciones(PROVS, 'farias', textos))).toEqual(['1'])
    expect(ids(filtrarOpciones(PROVS, 'FARÍAS', textos))).toEqual(['1'])
  })

  it('todas las palabras, en cualquier orden', () => {
    expect(ids(filtrarOpciones(PROVS, 'hijos jose', textos))).toEqual(['1'])
    expect(ids(filtrarOpciones(PROVS, 'jose norte', textos))).toEqual([])
  })

  it('busca por CUIT con o sin guiones', () => {
    expect(ids(filtrarOpciones(PROVS, '30-7123', textos))).toEqual(['1'])
    expect(ids(filtrarOpciones(PROVS, '3071234567', textos))).toEqual(['1'])
  })

  it('primero las que empiezan con la consulta', () => {
    // "Manaos SA" empieza con "man"; "Aguas Manantial" sólo tiene una palabra que empieza.
    expect(ids(filtrarOpciones(PROVS, 'man', textos))).toEqual(['2', '4'])
    expect(ids(filtrarOpciones(PROVS, 'anti', textos))).toEqual(['4'])
  })
})

describe('hayCoincidenciaExacta', () => {
  it('compara normalizado', () => {
    expect(hayCoincidenciaExacta(PROVS, 'manaos sa', p => p.nombre)).toBe(true)
    expect(hayCoincidenciaExacta(PROVS, 'manaos', p => p.nombre)).toBe(false)
    expect(hayCoincidenciaExacta(PROVS, '', p => p.nombre)).toBe(false)
  })
})
