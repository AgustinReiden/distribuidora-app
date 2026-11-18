import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * T2 de la tercera pasada de #1644: un formulario que frena su Guardar con el registro de lo
 * ilegible (`RegistroIlegiblesContext.Provider`) monta `AvisoCamposEnRojo` al lado del botón, para
 * que el Guardar gris diga por qué y lleve al campo en rojo. Sin esto, la pieza quedó en 5 de 23
 * formularios y el resto con el botón gris callado.
 */
const __dirname = path.dirname(fileURLToPath(import.meta.url))
const COMPONENTES = path.resolve(__dirname, '../components')

function archivos(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => {
    const ruta = path.join(dir, e.name)
    if (e.isDirectory()) return e.name === '__tests__' ? [] : archivos(ruta)
    return /\.tsx$/.test(e.name) && !/\.(test|spec)\./.test(e.name) ? [ruta] : []
  })
}

describe('AvisoCamposEnRojo: el Guardar frenado dice por qué (T2)', () => {
  const conRegistro = archivos(COMPONENTES).filter(r => fs.readFileSync(r, 'utf-8').includes('RegistroIlegiblesContext.Provider'))

  it('encuentra los formularios con registro', () => {
    expect(conRegistro.length).toBeGreaterThan(20)
  })

  it('todo formulario con registro monta AvisoCamposEnRojo', () => {
    const sinAviso = conRegistro
      .filter(r => !/<AvisoCamposEnRojo\b/.test(fs.readFileSync(r, 'utf-8')))
      .map(r => path.relative(path.resolve(__dirname, '../..'), r).replace(/\\/g, '/'))
    expect(sinAviso, 'Poné <AvisoCamposEnRojo /> al lado del Guardar que frena el registro').toEqual([])
  })
})
