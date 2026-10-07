import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { COLUMNAS_COSTO_PRODUCTO, PRODUCTO_COLUMNAS } from './productoColumnas'

/**
 * #974 · `authenticated` ya no tiene SELECT sobre las columnas de costo de
 * `productos`: la tabla se concede columna por columna y los costos salen sólo
 * por la RPC `costos_productos()` (admin y encargado).
 *
 * En PostgREST un `*` sobre una tabla con una columna sin permiso hace fallar
 * la consulta ENTERA, y no sólo para el preventista: también para el admin. Un
 * `select('*')`, un `.select()` pelado después de un insert/update o un embed
 * `producto:productos(*)` nuevo rompe la pantalla en runtime, y no lo ven ni
 * `tsc` ni eslint ni los tests que mockean supabase. Este test es esa guarda.
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
 * Las consultas que sí o sí fallarían con el permiso por columnas:
 *  - `.from('productos')` seguido —antes del próximo `.from(`— de un
 *    `.select('*')` o de un `.select()` sin argumentos (que PostgREST pide
 *    como `*`);
 *  - un embed de productos con `*` (`productos(*)`, `producto:productos(*)`,
 *    `productos!fk(*)`);
 *  - un embed de productos que nombra una columna de costo.
 */
function consultasRotas(): string[] {
  const hallazgos: string[] = []
  // El cierre del embed se busca balanceando paréntesis: un `[^()]*` no ve una
  // lista armada con `${X.join(', ')}` adentro.
  function* embeds(texto: string): Generator<{ index: number; columnas: string }> {
    for (const m of texto.matchAll(/productos(?:!\w+)?\s*\(/g)) {
      let prof = 1
      let i = m.index! + m[0].length
      for (; i < texto.length && prof > 0; i++) {
        if (texto[i] === '(') prof++
        else if (texto[i] === ')') prof--
      }
      yield { index: m.index!, columnas: texto.slice(m.index! + m[0].length, i - 1) }
    }
  }
  for (const archivo of listarArchivos(SRC)) {
    const texto = fs.readFileSync(archivo, 'utf8')

    for (const m of texto.matchAll(/\.from\(\s*['"`]productos['"`]\s*\)/g)) {
      const desde = m.index! + m[0].length
      const siguiente = texto.indexOf('.from(', desde)
      const tramo = texto.slice(desde, siguiente === -1 ? undefined : siguiente)
      const sel = tramo.match(/\.select\(\s*(?:\)|['"`]\s*\*\s*['"`])/)
      if (sel) hallazgos.push(`${relativo(archivo)}:${linea(texto, desde + sel.index!)} · select * sobre productos`)
    }

    // Una tabla que llega por variable (`from(tabla)`, como el conteo del
    // backup) puede ser productos: con `*` falla igual, aunque sea un HEAD.
    for (const m of texto.matchAll(/\.from\(\s*[A-Za-z_$][\w$]*\s*\)\s*\.select\(\s*['"`]\s*\*\s*['"`]/g)) {
      hallazgos.push(`${relativo(archivo)}:${linea(texto, m.index!)} · select * sobre una tabla variable (puede ser productos)`)
    }

    for (const m of embeds(texto)) {
      const columnas = m.columnas
      if (/(^|,)\s*\*\s*(,|$)/.test(columnas)) {
        hallazgos.push(`${relativo(archivo)}:${linea(texto, m.index)} · embed productos(*)`)
      } else if (
        COLUMNAS_COSTO_PRODUCTO.some(c => new RegExp(`\\b${c}\\b`).test(columnas)) ||
        // La lista armada con la constante de la cascada (analyticsExport).
        /COLUMNAS_COSTO/.test(columnas)
      ) {
        hallazgos.push(`${relativo(archivo)}:${linea(texto, m.index)} · embed de productos con columna de costo`)
      }
    }
  }
  return hallazgos
}

describe('productos: lecturas por REST sin columnas de costo (#974)', () => {
  it('ninguna consulta del front pide `*` ni costos sobre productos', () => {
    expect(consultasRotas()).toEqual([])
  })

  it('PRODUCTO_COLUMNAS no incluye ninguna columna de costo', () => {
    const columnas = PRODUCTO_COLUMNAS.split(',').map(c => c.trim())
    for (const costo of COLUMNAS_COSTO_PRODUCTO) expect(columnas).not.toContain(costo)
    expect(new Set(columnas).size).toBe(columnas.length)
  })
})
