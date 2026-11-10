/**
 * La baja de un pedido es `cancelado`, y nada más (#1520, mig 487). La primera
 * parte fija el predicado; la segunda es un trinquete sobre el código: ningún
 * archivo de src/ vuelve a nombrar el estado `anulado`, que la base ya no admite.
 */
import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { esPedidoDeBaja } from './pedidoDeBaja'

describe('esPedidoDeBaja', () => {
  it('cancelado es una baja', () => {
    expect(esPedidoDeBaja('cancelado')).toBe(true)
  })

  it.each(['pendiente', 'en_preparacion', 'asignado', 'entregado', '', null, undefined])(
    '%s no es una baja',
    (estado) => {
      expect(esPedidoDeBaja(estado)).toBe(false)
    },
  )
})

// =============================================================================
// TRINQUETE: nadie vuelve a nombrar el estado 'anulado'
// =============================================================================

const SRC = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const ESTE_ARCHIVO = 'utils/pedidoDeBaja.test.ts'

/**
 * Archivos donde `anulado` aparece y NO es un estado de pedido, con cuántas
 * veces. La lista es EXACTA y sólo se achica.
 */
const NO_SON_PEDIDOS: Record<string, number> = {
  // `estado_resolucion` de una salvedad, que es `anulada`: el masculino es una
  // defensa de esa otra entidad.
  'utils/valeBlanco.ts': 1,
}

function archivosFuente(dir: string): string[] {
  const out: string[] = []
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name)
    if (ent.isDirectory()) out.push(...archivosFuente(p))
    else if (/\.(ts|tsx|js|jsx)$/.test(ent.name)) out.push(p)
  }
  return out
}

/**
 * El literal `'anulado'` o `"anulado"`; pegado a un punto o a dos puntos, como
 * en PostgREST (`neq.anulado`) o en un mock (`estado:anulado`); y como clave de
 * un objeto (`{ anulado: ... }`, como el mapa de etiquetas de un modal). No toca
 * `anulado_at` ni `anulados`.
 */
function menciones(): Record<string, number> {
  const re = /['"]anulado['"]|[.:]anulado\b|(?:^|[{,])\s*anulado\s*:/gm
  const out: Record<string, number> = {}
  for (const archivo of archivosFuente(SRC)) {
    const rel = path.relative(SRC, archivo).split(path.sep).join('/')
    if (rel === ESTE_ARCHIVO) continue
    const n = fs.readFileSync(archivo, 'utf8').match(re)?.length ?? 0
    if (n > 0) out[rel] = n
  }
  return out
}

describe('trinquete: el estado anulado no existe', () => {
  it('ningún archivo de src/ nombra anulado, salvo las excepciones de otras entidades', () => {
    expect(menciones()).toEqual(NO_SON_PEDIDOS)
  })
})
