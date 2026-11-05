import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * #1336 · `clientes.zona` (texto) y `clientes.preventista_id` (uuid) se dropean.
 * La zona sale de `zonas` por `zona_id`, y el preventista de `cliente_preventistas`.
 *
 * Una columna que no existe hace fallar la consulta ENTERA en PostgREST, y un
 * PATCH que la manda en el body da PGRST204: no lo ven ni `tsc` (los selects son
 * strings y los payloads se arman sueltos) ni los tests que mockean supabase.
 * Antes de la limpieza, la lista de Pedidos pedía `zona` en el embed del cliente.
 * Este test es esa guarda: falla si un select del front vuelve a pedir esas
 * columnas a clientes, o si el alta o la edición vuelve a escribirlas.
 */

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SRC = path.resolve(__dirname, '..')
const RAIZ = path.resolve(SRC, '..')
const VIEJAS = ['zona', 'preventista_id']

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

/** Las columnas de primer nivel de una lista de select: sin embeds anidados ni alias. */
function columnasDePrimerNivel(lista: string): string[] {
  let plano = ''
  let prof = 0
  for (const ch of lista) {
    if (ch === '(') prof++
    else if (ch === ')') prof--
    else if (prof === 0) plano += ch
  }
  return plano.split(',')
    .map(c => c.trim().replace(/^[\w$]+:/, '').replace(/!\w+$/, '').trim())
    .filter(Boolean)
}

function consultasConColumnasViejas(): string[] {
  const hallazgos: string[] = []
  for (const archivo of listarArchivos(SRC)) {
    const texto = fs.readFileSync(archivo, 'utf8')

    // Embeds de clientes: `clientes(...)`, `cliente:clientes(...)`, `clientes!inner(...)`.
    // No `cliente_preventistas(...)`: el \b no corta en el guion bajo.
    for (const m of texto.matchAll(/\bclientes(?:!\w+)?\s*\(/g)) {
      let prof = 1
      let i = m.index! + m[0].length
      for (; i < texto.length && prof > 0; i++) {
        if (texto[i] === '(') prof++
        else if (texto[i] === ')') prof--
      }
      const columnas = columnasDePrimerNivel(texto.slice(m.index! + m[0].length, i - 1))
      for (const vieja of VIEJAS) {
        if (columnas.includes(vieja)) hallazgos.push(`${relativo(archivo)}:${linea(texto, m.index!)} · embed de clientes con ${vieja}`)
      }
    }

    // `.from('clientes')` seguido, antes del próximo `.from(`, de un select literal.
    for (const m of texto.matchAll(/\.from\(\s*['"`]clientes['"`]\s*\)/g)) {
      const desde = m.index! + m[0].length
      const siguiente = texto.indexOf('.from(', desde)
      const tramo = texto.slice(desde, siguiente === -1 ? undefined : siguiente)
      const sel = tramo.match(/\.select\(\s*['"`]([^'"`]*)['"`]/)
      if (!sel) continue
      const columnas = columnasDePrimerNivel(sel[1])
      for (const vieja of VIEJAS) {
        if (columnas.includes(vieja)) hallazgos.push(`${relativo(archivo)}:${linea(texto, desde + sel.index!)} · select de clientes con ${vieja}`)
      }
    }
  }
  return hallazgos
}

/** Las listas de columnas de clientes que viven en constantes y entran a un select por `${...}`. */
const CONSTANTES = [
  { archivo: 'src/hooks/queries/usePedidosQuery.ts', nombre: 'PEDIDO_CLIENT_COLS' },
  { archivo: 'src/hooks/queries/useClientesQuery.ts', nombre: 'CLIENTE_SELECT' },
]

/**
 * Los caminos que escriben clientes por REST y el objeto que mandan. Una clave
 * `zona:` o `preventista_id:` ahí la escribe. La excepción es la fila de
 * `cliente_preventistas` (`{ cliente_id, preventista_id }`), que es otra tabla.
 */
const ESCRITORES = [
  'src/hooks/queries/useClientesQuery.ts',
  'src/components/containers/ClientesContainer.tsx',
  'src/components/containers/PedidosContainer.tsx',
]

describe('clientes: nada pide ni escribe zona ni preventista_id (#1336)', () => {
  it('ningún select ni embed del front pide esas columnas a clientes', () => {
    expect(consultasConColumnasViejas()).toEqual([])
  })

  it.each(CONSTANTES)('$nombre no las incluye', ({ archivo, nombre }) => {
    const texto = fs.readFileSync(path.join(RAIZ, archivo), 'utf8')
    const m = texto.match(new RegExp(`\\b${nombre}\\s*=\\s*['"\`]([^'"\`]*)['"\`]`))
    expect(m, `${nombre} en ${archivo}`).not.toBeNull()
    const columnas = columnasDePrimerNivel(m![1])
    for (const vieja of VIEJAS) expect(columnas, nombre).not.toContain(vieja)
  })

  it.each(ESCRITORES)('%s no escribe esas columnas', archivo => {
    const texto = fs.readFileSync(path.join(RAIZ, archivo), 'utf8')
    const hallazgos = texto.split('\n')
      .map((l, i) => ({ l, n: i + 1 }))
      .filter(({ l }) => /^\s*(\/\/|\*)/.test(l) === false)
      .filter(({ l }) => /(^|[\s{,])(zona|preventista_id)\s*:/.test(l))
      .filter(({ l }) => !/\bcliente_id\b/.test(l))
      // El tipo de la fila de cliente_preventistas (`{ preventista_id: string }`).
      .filter(({ l }) => !/\bpreventista_id\s*:\s*string\b/.test(l))
      .map(({ l, n }) => `${archivo}:${n} · ${l.trim()}`)
    expect(hallazgos).toEqual([])
  })
})
