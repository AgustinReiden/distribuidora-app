import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { COLUMNAS_COSTO_PEDIDO_ITEM, PEDIDO_ITEM_COLUMNAS } from './pedidoItemColumnas'

/**
 * #1003 · `authenticated` ya no tiene SELECT sobre `pedido_items.costo_unitario_al_crear`:
 * la tabla se concede columna por columna y el costo de la venta sale sólo por
 * la RPC `costos_pedido_items()` (admin y encargado).
 *
 * En PostgREST un `*` sobre una tabla con una columna sin permiso hace fallar la
 * consulta ENTERA, y no sólo para el preventista: también para el admin. Un
 * `pedido_items(*)` nuevo rompe la pantalla en runtime, y no lo ven ni `tsc` ni
 * eslint ni los tests que mockean supabase. Este test es esa guarda (mismo molde
 * que `productoColumnas.test.ts`, #974).
 */

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SRC = path.resolve(__dirname, '..')
const RAIZ = path.resolve(SRC, '..')

function listarArchivos(dir: string, acc: string[] = []): string[] {
  for (const nombre of fs.readdirSync(dir)) {
    const ruta = path.join(dir, nombre)
    if (fs.statSync(ruta).isDirectory()) {
      if (nombre === 'node_modules' || nombre === '__tests__') continue
      listarArchivos(ruta, acc)
    } else if (/\.(ts|tsx|js|jsx)$/.test(nombre) && !/\.(test|spec)\./.test(nombre)) {
      acc.push(ruta)
    }
  }
  return acc
}

const relativo = (ruta: string) => path.relative(RAIZ, ruta).split(path.sep).join('/')
const linea = (texto: string, idx: number) => texto.slice(0, idx).split('\n').length

/**
 * Las columnas del primer nivel del `select(...)` que arranca en `desde`: el
 * contenido del primer string literal (comilla o template literal), partido por
 * las comas que no están dentro de paréntesis. Un `*` anidado en un embed
 * (`pedido:pedidos(*)`) no cuenta: es de otra tabla.
 */
function columnasDelPrimerNivel(texto: string, desde: number): string[] | null {
  let i = desde
  while (i < texto.length && /\s/.test(texto[i])) i++
  const comilla = texto[i]
  if (comilla !== "'" && comilla !== '"' && comilla !== '`') return null
  const fin = texto.indexOf(comilla, i + 1)
  if (fin === -1) return null
  const columnas: string[] = []
  let prof = 0
  let actual = ''
  for (const c of texto.slice(i + 1, fin)) {
    if (c === '(') prof++
    else if (c === ')') prof--
    if (c === ',' && prof === 0) {
      columnas.push(actual.trim())
      actual = ''
    } else {
      actual += c
    }
  }
  columnas.push(actual.trim())
  return columnas
}

/**
 * Las consultas que sí o sí fallarían con el permiso por columnas:
 *  - `.from('pedido_items')` seguido —antes del próximo `.from(`— de un
 *    `.select()` sin argumentos (que PostgREST pide como `*`), o de un select
 *    cuya lista del primer nivel tiene un `*` en CUALQUIER posición
 *    (`'*'`, `'*, pedido:pedidos(...)'`, `` `id, *` ``);
 *  - un embed de pedido_items con `*` (`pedido_items(*)`, `items:pedido_items(*, ...)`,
 *    `pedido_items!fk(*)`);
 *  - un embed o un select de pedido_items que nombra la columna de costo.
 *
 * Es una función pura sobre un texto para poder probarla con casos sintéticos
 * sin dejar un archivo con el bug en src/.
 */
function consultasRotasEnTexto(texto: string, etiqueta: string): string[] {
  const hallazgos: string[] = []
  const esCosto = (columnas: string) =>
    COLUMNAS_COSTO_PEDIDO_ITEM.some(c => new RegExp(`\\b${c}\\b`).test(columnas))

  // El cierre del embed se busca balanceando paréntesis: un `[^()]*` no ve una
  // lista armada con `${X.join(', ')}` adentro.
  function* embeds(): Generator<{ index: number; columnas: string }> {
    for (const m of texto.matchAll(/pedido_items(?:!\w+)?\s*\(/g)) {
      let prof = 1
      let i = m.index! + m[0].length
      for (; i < texto.length && prof > 0; i++) {
        if (texto[i] === '(') prof++
        else if (texto[i] === ')') prof--
      }
      yield { index: m.index!, columnas: texto.slice(m.index! + m[0].length, i - 1) }
    }
  }

  for (const m of texto.matchAll(/\.from\(\s*['"`]pedido_items['"`]\s*\)/g)) {
    const desde = m.index! + m[0].length
    const siguiente = texto.indexOf('.from(', desde)
    const tramo = texto.slice(desde, siguiente === -1 ? undefined : siguiente)
    const sel = tramo.match(/\.select\(/)
    if (!sel) continue
    const donde = `${etiqueta}:${linea(texto, desde + sel.index!)}`
    if (/^\.select\(\s*\)/.test(tramo.slice(sel.index!))) {
      hallazgos.push(`${donde} · select * sobre pedido_items`)
      continue
    }
    const columnas = columnasDelPrimerNivel(texto, desde + sel.index! + sel[0].length)
    if (!columnas) continue
    if (columnas.some(c => c === '*')) hallazgos.push(`${donde} · select * sobre pedido_items`)
    else if (esCosto(columnas.join(','))) hallazgos.push(`${donde} · select de pedido_items con columna de costo`)
  }

  for (const m of embeds()) {
    const columnas = m.columnas
    if (/(^|,)\s*\*\s*(,|$)/.test(columnas)) {
      hallazgos.push(`${etiqueta}:${linea(texto, m.index)} · embed pedido_items(*)`)
    } else if (
      esCosto(columnas) ||
      // La lista armada con la constante de la cascada (analyticsExport).
      /COLUMNAS_COSTO/.test(columnas)
    ) {
      hallazgos.push(`${etiqueta}:${linea(texto, m.index)} · embed de pedido_items con columna de costo`)
    }
  }
  return hallazgos
}

function consultasRotas(): string[] {
  return listarArchivos(SRC).flatMap(archivo =>
    consultasRotasEnTexto(fs.readFileSync(archivo, 'utf8'), relativo(archivo)))
}

describe('la guarda detecta cada forma de `*` sobre pedido_items', () => {
  const detecta = (codigo: string) => consultasRotasEnTexto(codigo, 'x.ts')

  it.each([
    ["select('*')", ".from('pedido_items').select('*')"],
    ['select() pelado', ".from('pedido_items').select()"],
    ["'*' con embed de otra tabla", ".from('pedido_items').select('*, pedido:pedidos(id, estado)')"],
    ["'*' al final", ".from('pedido_items').select('id, *')"],
    ["'*' en el medio", ".from('pedido_items').select('id, *, pedido:pedidos(id)')"],
    ['template literal con *', ".from('pedido_items').select(`*, pedido:pedidos(${COLS})`)"],
    ['comillas dobles', '.from("pedido_items").select("*, x(y)")'],
    ['multilínea', ".from('pedido_items')\n  .eq('a', 1)\n  .select('*, pedido:pedidos(id)')"],
    ['embed con alias', "select('*, items:pedido_items(*, producto:productos(id))')"],
    ['embed con fk', "select('*, pedido_items!fk(*)')"],
  ])('%s', (_nombre, codigo) => {
    expect(detecta(codigo)).toHaveLength(1)
  })

  it('detecta la columna de costo en un select directo', () => {
    expect(detecta(".from('pedido_items').select('id, costo_unitario_al_crear')")).toHaveLength(1)
  })

  it('no marca un select con columnas explícitas ni un * anidado en otra tabla', () => {
    expect(detecta(".from('pedido_items').select('id, cantidad')")).toEqual([])
    expect(detecta(".from('pedido_items').select('id, pedido:pedidos(*)')")).toEqual([])
    expect(detecta(".from('pedido_items').select(`${PEDIDO_ITEM_COLUMNAS}, pedido:pedidos(id)`)")).toEqual([])
    expect(detecta(".from('pedido_items').select('id', { count: 'exact', head: true })")).toEqual([])
    expect(detecta(".from('pedidos').select('*, items:pedido_items(id, cantidad)')")).toEqual([])
  })
})

describe('pedido_items: lecturas por REST sin la columna de costo (#1003)', () => {
  it('ninguna consulta del front pide `*` ni costo sobre pedido_items', () => {
    expect(consultasRotas()).toEqual([])
  })

  it('PEDIDO_ITEM_COLUMNAS no incluye la columna de costo ni repite columnas', () => {
    const columnas = PEDIDO_ITEM_COLUMNAS.split(',').map(c => c.trim())
    for (const costo of COLUMNAS_COSTO_PEDIDO_ITEM) expect(columnas).not.toContain(costo)
    expect(new Set(columnas).size).toBe(columnas.length)
  })

  it('PEDIDO_ITEM_COLUMNAS es exactamente lo que la migración le concede a authenticated', () => {
    // El último `GRANT SELECT (...) ON public.pedido_items TO authenticated` de
    // migrations/ (hoy, la mitad 2/2 de #1003) es la lista vigente. Si alguien
    // agrega una columna a pedido_items y la concede en una migración nueva,
    // este test le pide sumarla acá (y al revés).
    const dir = path.join(RAIZ, 'migrations')
    const RE_GRANT = /GRANT SELECT \(([^)]*)\)\s+ON public\.pedido_items TO authenticated/g
    const grants = fs.readdirSync(dir)
      .filter(n => n.endsWith('.sql'))
      .sort()
      .flatMap(n => [...fs.readFileSync(path.join(dir, n), 'utf8').matchAll(RE_GRANT)].map(m => m[1]))
    expect(grants.length).toBeGreaterThan(0)
    const concedidas = grants[grants.length - 1].split(',').map(c => c.trim()).sort()
    const front = PEDIDO_ITEM_COLUMNAS.split(',').map(c => c.trim()).sort()
    expect(front).toEqual(concedidas)
  })
})
