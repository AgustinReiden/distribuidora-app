import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * Test-TRINQUETE de la migración de botones a `Button` (issue #707).
 *
 * Cuenta los `<button …>` de `src/` que todavía pintan su fondo con un color
 * crudo de Tailwind (`bg-*-500|600|700`, o un degradé `from-*` / `to-*` de esos
 * tonos) fuera de `src/components/ui/`, que es donde vive el primitivo. Ese
 * número SÓLO PUEDE BAJAR: cada lote de la migración lo baja y actualiza el
 * techo de abajo en el mismo PR. Si un PR lo sube, es que alguien escribió un
 * botón nuevo a mano en vez de usar `Button`, y eso es exactamente lo que este
 * test existe para frenar.
 *
 * Cómo cuenta: recorre cada `.tsx` / `.jsx` de `src/` (sin tests), busca cada
 * `<button` y toma la etiqueta de apertura entera hasta su `>` de cierre. El
 * cierre se decide contando llaves: un `>` adentro de `{ … }` (el `=>` de un
 * `onClick={() => …}`, un ternario con `>`) NO cierra la etiqueta. Con un
 * `[^>]*` a secas, un botón con `onClick={() => …}` antes del `className` se
 * recortaba en el `=>` y su color quedaba sin contar.
 *
 * Qué NO cuenta, a propósito:
 *  - `<Button …>` (el primitivo): no es un `<button` literal.
 *  - Botones secundarios / ghost (`bg-white`, `bg-gray-100`…): el issue mide el
 *    color crudo saturado; los demás caen con las variantes `secondary`/`ghost`
 *    y se ven en el diff, no hace falta un contador aparte.
 *  - `src/components/ui/**`: el primitivo pinta con `brand`, y ése es el único
 *    lugar donde un color de botón se escribe a mano.
 */

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SRC = path.resolve(__dirname, '..', '..')
const EXCLUIDO = path.join(SRC, 'components', 'ui') + path.sep

/**
 * TECHO. Se baja en cada lote de #707 al número que deja el lote. Nunca se sube.
 * Historial:
 *  - 2026-09-19, antes de WP-17a: 174 (medido con este mismo test).
 *  - 2026-09-19, WP-17a (5 CTAs a `<Button variant="hero">`, sobre un main que
 *    ya había sumado uno en ModalPedido): 170.
 */
const TECHO_BOTONES_CRUDOS = 170

// Colores SATURADOS, con o sin `hover:`/`active:`. Los neutros (gray, stone,
// slate, zinc, neutral) quedan afuera: `hover:bg-gray-700` es un ghost en modo
// oscuro, no un botón de color crudo. Y `dark:` no se acepta como prefijo por
// lo mismo: la variante oscura de un secundario es un neutro 700.
const RE_COLOR_CRUDO =
  /(?:^|[\s'"`])(?:hover:|active:)?(?:bg|from|to)-(?!(?:gray|stone|slate|zinc|neutral)-)[a-z]+-(?:500|600|700)(?=$|[\s'"`/])/

function listarArchivos(dir: string, acc: string[] = []): string[] {
  for (const nombre of fs.readdirSync(dir)) {
    const ruta = path.join(dir, nombre)
    if (fs.statSync(ruta).isDirectory()) {
      if (nombre === 'node_modules' || nombre === '__tests__') continue
      listarArchivos(ruta, acc)
    } else if (/\.(tsx|jsx)$/.test(nombre) && !/\.(test|spec)\./.test(nombre)) {
      acc.push(ruta)
    }
  }
  return acc
}

/** Devuelve cada etiqueta de apertura `<button …>` completa del archivo. */
export function etiquetasButton(codigo: string): string[] {
  const etiquetas: string[] = []
  let desde = 0
  for (;;) {
    const inicio = codigo.indexOf('<button', desde)
    if (inicio === -1) break
    // `<button` tiene que terminar ahí: `<buttonX` no es un botón.
    const sig = codigo[inicio + 7]
    if (sig && /[A-Za-z0-9_-]/.test(sig)) {
      desde = inicio + 7
      continue
    }
    let profundidad = 0
    let fin = -1
    for (let i = inicio + 7; i < codigo.length; i++) {
      const c = codigo[i]
      if (c === '{') profundidad++
      else if (c === '}') profundidad--
      else if (c === '>' && profundidad === 0) {
        fin = i
        break
      }
    }
    if (fin === -1) break
    etiquetas.push(codigo.slice(inicio, fin + 1))
    desde = fin + 1
  }
  return etiquetas
}

export function contarBotonesCrudos(): { total: number; porArchivo: Record<string, number> } {
  const porArchivo: Record<string, number> = {}
  let total = 0
  for (const archivo of listarArchivos(SRC)) {
    if (archivo.startsWith(EXCLUIDO)) continue
    const codigo = fs.readFileSync(archivo, 'utf8')
    const crudos = etiquetasButton(codigo).filter((tag) => RE_COLOR_CRUDO.test(tag)).length
    if (crudos > 0) {
      porArchivo[path.relative(SRC, archivo).split(path.sep).join('/')] = crudos
      total += crudos
    }
  }
  return { total, porArchivo }
}

describe('trinquete: botones con color crudo fuera de ui/ (#707)', () => {
  it('el parser toma la etiqueta entera aunque haya un => antes del className', () => {
    const codigo = `<button onClick={() => hacer(a > b)} className="bg-red-600">x</button>`
    const [tag] = etiquetasButton(codigo)
    expect(tag).toBe('<button onClick={() => hacer(a > b)} className="bg-red-600">')
    expect(RE_COLOR_CRUDO.test(tag)).toBe(true)
  })

  it('no confunde bg-white ni un <Button> con un botón crudo', () => {
    expect(etiquetasButton('<Button variant="hero">x</Button>')).toEqual([])
    expect(RE_COLOR_CRUDO.test('<button className="bg-white text-gray-700">')).toBe(false)
    expect(RE_COLOR_CRUDO.test('<button className="bg-brand-600 text-white">')).toBe(true)
    expect(RE_COLOR_CRUDO.test('<button className="bg-gradient-to-br from-green-500 to-green-600">')).toBe(true)
    expect(RE_COLOR_CRUDO.test('<button className="hover:bg-gray-100 dark:hover:bg-gray-700">')).toBe(false)
    expect(RE_COLOR_CRUDO.test('<button className="bg-white dark:bg-gray-800 dark:hover:bg-blue-700">')).toBe(false)
  })

  it(`no hay más de ${TECHO_BOTONES_CRUDOS} botones crudos; si bajó, bajá el techo en este archivo`, () => {
    const { total, porArchivo } = contarBotonesCrudos()
    const detalle = Object.entries(porArchivo)
      .sort((a, b) => b[1] - a[1])
      .map(([f, n]) => `${String(n).padStart(3)}  ${f}`)
      .join('\n')
    expect(total, `Botones crudos por archivo:\n${detalle}`).toBeLessThanOrEqual(TECHO_BOTONES_CRUDOS)
  })
})
