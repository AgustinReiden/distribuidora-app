import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * 1563-b4: invalidaciones a claves que ninguna consulta usa.
 *
 * `invalidateQueries({ queryKey: ['recorridos'] })` compara elemento a elemento, no por
 * prefijo de texto: no alcanza a `'recorridos-hoja-ruta'` ni a `'recorrido-activo'`. Las tres de
 * abajo no las lee ninguna `useQuery`, así que invalidarlas no refrescaba nada y le daba al que
 * lee el código la idea de que algo se refrescaba:
 *
 *  - `['recorridos']`: las claves de ruta son `recorrido-activo`, `recorrido-existente` y
 *    `recorridos-hoja-ruta`.
 *  - `['pagos']`: ninguna consulta de TanStack lee `pagos`; lo derivado es `clientes` (el saldo),
 *    `pedidos` (el estado de pago) y `deudores-mora`.
 *  - `['ficha-cliente']`: la ficha es estado local (`useFichaCliente`), no una consulta; el modal
 *    de pago cierra la ficha, y al reabrirla se vuelve a cargar.
 *
 * Una clave nueva que se invalida tiene que existir como `queryKey` de alguna consulta.
 */
const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SRC = path.resolve(__dirname, '..')

const CLAVES_MUERTAS = ['recorridos', 'pagos', 'ficha-cliente']

function archivosDeProduccion(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap(e => {
    const ruta = path.join(dir, e.name)
    if (e.isDirectory()) return e.name === '__tests__' || e.name === 'test' ? [] : archivosDeProduccion(ruta)
    return /\.(ts|tsx)$/.test(e.name) && !/\.(test|spec)\./.test(e.name) ? [ruta] : []
  })
}

describe('invalidaciones a claves que nadie usa (1563-b4)', () => {
  const archivos = archivosDeProduccion(SRC)

  it('encuentra el código a revisar', () => {
    expect(archivos.length).toBeGreaterThan(100)
  })

  for (const clave of CLAVES_MUERTAS) {
    it(`nadie invalida ['${clave}']`, () => {
      const patron = new RegExp(`queryKey:\\s*\\[\\s*['"]${clave}['"]\\s*[\\],]`)
      const infractores = archivos
        .filter(f => patron.test(fs.readFileSync(f, 'utf8')))
        .map(f => path.relative(SRC, f))
      expect(infractores).toEqual([])
    })
  }
})
