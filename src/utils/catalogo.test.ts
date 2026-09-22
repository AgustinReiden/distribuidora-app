import { describe, it, expect } from 'vitest'
import { buscarEnCatalogo, limpiarNombreCatalogo } from './catalogo'

const CATALOGO = [
  { id: '1', nombre: 'AZÚCAR' },
  { id: '2', nombre: 'PAPEL HIGIENICO' },
  { id: '3', nombre: 'MAÑANITA' },
]

describe('limpiarNombreCatalogo', () => {
  it('saca los espacios de más y lo pasa a mayúsculas', () => {
    expect(limpiarNombreCatalogo('  papel   higienico ')).toBe('PAPEL HIGIENICO')
  })

  it('conserva tildes y eñes al pasar a mayúsculas', () => {
    expect(limpiarNombreCatalogo('azúcar')).toBe('AZÚCAR')
    expect(limpiarNombreCatalogo('mañanita')).toBe('MAÑANITA')
  })

  it('solo espacios queda vacío', () => {
    expect(limpiarNombreCatalogo('   ')).toBe('')
  })
})

describe('buscarEnCatalogo', () => {
  it('encuentra el nombre escrito con otras mayúsculas y sin tilde', () => {
    expect(buscarEnCatalogo(CATALOGO, 'azucar')?.id).toBe('1')
  })

  it('no le importan los espacios de más', () => {
    expect(buscarEnCatalogo(CATALOGO, ' Papel  Higienico ')?.id).toBe('2')
  })

  it('la eñe es otra letra: MANANITA no es MAÑANITA', () => {
    expect(buscarEnCatalogo(CATALOGO, 'mananita')).toBeUndefined()
    expect(buscarEnCatalogo(CATALOGO, 'mañanita')?.id).toBe('3')
  })

  it('un nombre vacío no encuentra nada', () => {
    expect(buscarEnCatalogo(CATALOGO, '  ')).toBeUndefined()
  })

  it('un nombre que no está devuelve undefined', () => {
    expect(buscarEnCatalogo(CATALOGO, 'FRAU')).toBeUndefined()
  })
})
