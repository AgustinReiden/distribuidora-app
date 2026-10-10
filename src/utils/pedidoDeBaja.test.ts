/**
 * `anulado` es una baja igual que `cancelado` (#1080). La primera parte fija el
 * predicado; la segunda es un trinquete sobre el código: toda consulta
 * PostgREST que excluye `cancelado` tiene que excluir también `anulado`, porque
 * esa consulta no puede llamar a `esPedidoDeBaja`.
 */
import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { ESTADOS_DE_BAJA, esPedidoDeBaja } from './pedidoDeBaja'

describe('esPedidoDeBaja', () => {
  it.each(['cancelado', 'anulado'])('%s es una baja', (estado) => {
    expect(esPedidoDeBaja(estado)).toBe(true)
  })

  it.each(['pendiente', 'en_preparacion', 'asignado', 'entregado', '', null, undefined])(
    '%s no es una baja',
    (estado) => {
      expect(esPedidoDeBaja(estado)).toBe(false)
    },
  )

  it('la lista y el predicado dicen lo mismo', () => {
    expect([...ESTADOS_DE_BAJA].sort()).toEqual(['anulado', 'cancelado'])
    for (const e of ESTADOS_DE_BAJA) expect(esPedidoDeBaja(e)).toBe(true)
  })
})

// =============================================================================
// TRINQUETE: ninguna consulta excluye 'cancelado' y deja pasar 'anulado'
// =============================================================================

const SRC = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')

/**
 * Archivos donde `.neq('estado', 'cancelado')` NO es sobre `pedidos`: la
 * columna es `recorridos.estado`, cuyo dominio es en_curso / completado /
 * cancelado (sin CHECK, y en prod no hay otro valor). Ahí `anulado` no existe.
 */
const NO_SON_PEDIDOS: Record<string, string> = {
  'hooks/supabase/useRecorridos.ts': 'recorridos.estado',
  'hooks/queries/useRecorridosHojaRutaQuery.ts': 'recorridos.estado',
}

function archivosFuente(dir: string): string[] {
  const out: string[] = []
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name)
    if (ent.isDirectory()) {
      if (ent.name === '__tests__' || ent.name === 'test') continue
      out.push(...archivosFuente(p))
    } else if (/\.(ts|tsx)$/.test(ent.name) && !/\.test\.(ts|tsx)$/.test(ent.name)) {
      out.push(p)
    }
  }
  return out
}

/** Las consultas que excluyen `cancelado` y no `anulado`, como `archivo:línea`. */
function consultasQueDejanPasarAnulados(): string[] {
  const faltan: string[] = []
  for (const archivo of archivosFuente(SRC)) {
    const rel = path.relative(SRC, archivo).split(path.sep).join('/')
    if (rel in NO_SON_PEDIDOS) continue
    const texto = fs.readFileSync(archivo, 'utf8')
    const linea = (i: number) => texto.slice(0, i).split('\n').length

    // .neq('estado', 'cancelado') / .neq('pedidos.estado', 'cancelado') ...
    // El par tiene que estar en la misma cadena, unas líneas más abajo.
    const neq = /\.neq\(\s*'([\w.]*estado)'\s*,\s*'cancelado'\s*\)/g
    for (const m of texto.matchAll(neq)) {
      const col = m[1].replace(/\./g, '\\.')
      const resto = texto.slice(m.index! + m[0].length, m.index! + m[0].length + 400)
      const par = new RegExp(`\\.neq\\(\\s*'${col}'\\s*,\\s*'anulado'\\s*\\)`)
      if (!par.test(resto)) faltan.push(`${rel}:${linea(m.index!)}`)
    }

    // .not('estado', 'in', '("entregado","cancelado")')
    const notIn = /\.not\(\s*'[\w.]*estado'\s*,\s*'in'\s*,\s*'([^']*)'\s*\)/g
    for (const m of texto.matchAll(notIn)) {
      if (m[1].includes('cancelado') && !m[1].includes('anulado')) faltan.push(`${rel}:${linea(m.index!)}`)
    }
  }
  return faltan.sort()
}

describe('trinquete: las consultas que excluyen cancelados excluyen también anulados', () => {
  it('ningún `.neq(estado, cancelado)` ni `not in (...cancelado...)` sin su anulado', () => {
    expect(consultasQueDejanPasarAnulados()).toEqual([])
  })

  it('las excepciones siguen existiendo y siguen siendo sobre recorridos', () => {
    // Si alguno de estos archivos pasa a consultar `pedidos`, la excepción deja
    // de valer: este test obliga a mirarla de nuevo.
    for (const rel of Object.keys(NO_SON_PEDIDOS)) {
      const texto = fs.readFileSync(path.join(SRC, rel), 'utf8')
      expect(texto).toMatch(/\.from\('recorridos'\)/)
      expect(texto).not.toMatch(/\.from\('pedidos'\)/)
    }
  })
})

// =============================================================================
// TRINQUETE: ninguna comparación en JS decide "dado de baja" mirando sólo 'cancelado'
// =============================================================================

/**
 * `estado === 'cancelado'` / `!== 'cancelado'` sin `anulado` en la misma línea,
 * contadas por archivo (ruta relativa a src/). La lista es EXACTA: cada entrada
 * es una comparación que de verdad es sólo sobre `cancelado`. Para decidir si un
 * pedido está dado de baja se usa `esPedidoDeBaja`. Así se coló el
 * `soloAnulacion={pedidoPago.estado === 'cancelado'}` de PedidosContainer (#1080).
 */
const COMPARACIONES_SOLO_CANCELADO: Record<string, number> = {
  // el motivo de cancelación: un anulado no lo lleva.
  'components/pedidos/PedidoCard.tsx': 2,
  // el valor del filtro de estado elegido por el usuario (la opción se llama 'cancelado'
  // y ya trae los anulados, ver construirFiltrosPedidos).
  'utils/construirFiltrosPedidos.ts': 2,
  'utils/kpiFiltroPedidos.ts': 2,
  // la etiqueta de cada estado.
  'utils/formatters.ts': 1,
}

function comparacionesSoloCancelado(): Record<string, number> {
  const out: Record<string, number> = {}
  const re = /[!=]==?\s*'cancelado'|'cancelado'\s*[!=]==?/
  for (const archivo of archivosFuente(SRC)) {
    const rel = path.relative(SRC, archivo).split(path.sep).join('/')
    if (rel === 'utils/pedidoDeBaja.ts') continue
    const n = fs
      .readFileSync(archivo, 'utf8')
      .split(/\r?\n/)
      .filter((l) => !/^\s*(\/\/|\*|\/\*)/.test(l))
      .filter((l) => re.test(l) && !l.includes('anulado')).length
    if (n > 0) out[rel] = n
  }
  return out
}

describe('trinquete: las comparaciones en JS no miran sólo cancelado', () => {
  it('cada `=== \'cancelado\'` sin anulado está en la lista: para "dado de baja" usá esPedidoDeBaja', () => {
    expect(comparacionesSoloCancelado()).toEqual(COMPARACIONES_SOLO_CANCELADO)
  })
})
