import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * #1124 · La familia compras (`compras`, `compra_items`, `compra_cargos` y
 * `compra_cargo_repartos`) se escribe sólo por sus RPC DEFINER
 * (registrar_compra_completa, actualizar_compra_items, anular_compra_atomica y
 * cambiar_proveedor_compra). Desde la migración que cerró #1124,
 * `authenticated` y `anon` no tienen INSERT/UPDATE/DELETE sobre esas tablas ni
 * hay policies de escritura: un `.insert`/`.update`/`.upsert`/`.delete` por
 * PostgREST falla en runtime con 42501, y no lo ven ni `tsc` ni eslint ni los
 * tests que mockean supabase. Este test es esa guarda.
 *
 * Mira la CADENA de métodos que sigue a cada `.from(...)`:
 *  - con una de las cuatro tablas como literal, una escritura en la cadena falla;
 *  - con una tabla que llega por variable (backup, sync offline, un helper
 *    genérico), una escritura también falla salvo que el archivo esté en la
 *    lista blanca de abajo, que hoy está vacía: el único `.from(tabla)` de src/
 *    es el conteo de useBackup, y es un select.
 */

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SRC = path.resolve(__dirname, '..')
const RAIZ = path.resolve(SRC, '..')

const TABLAS_COMPRAS = ['compras', 'compra_items', 'compra_cargos', 'compra_cargo_repartos']
const ESCRITURAS = new Set(['insert', 'update', 'upsert', 'delete'])
// `.from(` que no son de supabase-js.
const RECEPTORES_AJENOS = new Set(['Array', 'Buffer', 'storage', 'Object', 'Uint8Array'])
// Archivos con `.from(<variable>)` seguido de una escritura que se revisaron a
// mano y no pueden recibir una tabla de compras. Hoy, ninguno.
const LISTA_BLANCA_TABLA_VARIABLE: string[] = []

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

/** Índice justo después del paréntesis que cierra el que abre en `abre`. */
function cerrarParentesis(texto: string, abre: number): number {
  let prof = 0
  for (let i = abre; i < texto.length; i++) {
    if (texto[i] === '(') prof++
    else if (texto[i] === ')') {
      prof--
      if (prof === 0) return i + 1
    }
  }
  return texto.length
}

/** Los métodos encadenados a partir de `desde`: `.a(…)\n  .b(…)?.c(…)` → [a, b, c]. */
function cadena(texto: string, desde: number): string[] {
  const metodos: string[] = []
  let i = desde
  for (;;) {
    const m = /^\s*\??\.\s*([A-Za-z_$][\w$]*)\s*/.exec(texto.slice(i, i + 200))
    if (!m) break
    metodos.push(m[1])
    i += m[0].length
    if (texto[i] === '(') i = cerrarParentesis(texto, i)
  }
  return metodos
}

interface Escritura {
  index: number
  tabla: string | null // null: la tabla llega por variable
  metodo: string
}

/** Toda escritura PostgREST de `texto` sobre una tabla de compras o sobre una tabla variable. */
function escriturasDeCompras(texto: string): Escritura[] {
  const hallazgos: Escritura[] = []
  for (const m of texto.matchAll(/([A-Za-z_$][\w$]*)?\s*\.from\(/g)) {
    if (m[1] && RECEPTORES_AJENOS.has(m[1])) continue
    const abre = m.index! + m[0].length - 1
    const cierra = cerrarParentesis(texto, abre)
    const argumento = texto.slice(abre + 1, cierra - 1).trim()
    const literal = /^(['"`])([\w]+)\1$/.exec(argumento)
    if (literal && !TABLAS_COMPRAS.includes(literal[2])) continue
    const metodo = cadena(texto, cierra).find((x) => ESCRITURAS.has(x))
    if (metodo) hallazgos.push({ index: m.index!, tabla: literal ? literal[2] : null, metodo })
  }
  return hallazgos
}

describe('compras sólo se lee por REST (#1124)', () => {
  it('el detector muerde: escrituras literales y por variable', () => {
    const casos: Array<[string, Array<Pick<Escritura, 'tabla' | 'metodo'>>]> = [
      ["await supabase.from('compras').update({ estado: 'cancelada' }).eq('id', 1)", [{ tabla: 'compras', metodo: 'update' }]],
      ["supabase\n  .from('compra_items')\n  .select('id')\n  .delete()", [{ tabla: 'compra_items', metodo: 'delete' }]],
      ['supabase.from("compra_cargos").insert([{ monto: 1 }]).select()', [{ tabla: 'compra_cargos', metodo: 'insert' }]],
      ['supabase.from(`compra_cargo_repartos`).upsert(filas)', [{ tabla: 'compra_cargo_repartos', metodo: 'upsert' }]],
      ['supabase.from(tabla).delete().neq("id", 0)', [{ tabla: null, metodo: 'delete' }]],
      ["supabase.from(TABLAS[i])?.insert(fila)", [{ tabla: null, metodo: 'insert' }]],
      // no son escrituras de compras
      ["supabase.from('compras').select('*, proveedor:proveedores(nombre)').eq('id', 1)", []],
      ["supabase.from('pedidos').update({ estado: 'x' })", []],
      ["supabase.from(tabla).select('id', { count: 'exact', head: true })", []],
      ['Array.from(ids).map((x) => x).filter(Boolean)', []],
      ["supabase.storage.from('fotos').remove([ruta])", []],
    ]
    for (const [codigo, esperado] of casos) {
      expect(escriturasDeCompras(codigo).map(({ tabla, metodo }) => ({ tabla, metodo })), codigo).toEqual(esperado)
    }
  })

  it('src/ no escribe compras, compra_items, compra_cargos ni compra_cargo_repartos por PostgREST', () => {
    const hallazgos: string[] = []
    for (const archivo of listarArchivos(SRC)) {
      const texto = fs.readFileSync(archivo, 'utf8')
      for (const e of escriturasDeCompras(texto)) {
        if (e.tabla === null && LISTA_BLANCA_TABLA_VARIABLE.includes(relativo(archivo))) continue
        hallazgos.push(
          `${relativo(archivo)}:${linea(texto, e.index)} · .${e.metodo}() sobre ${e.tabla ?? 'una tabla variable (puede ser de compras)'}`,
        )
      }
    }
    expect(hallazgos, 'escribir por la RPC (registrar_compra_completa, actualizar_compra_items, anular_compra_atomica, cambiar_proveedor_compra)').toEqual([])
  })

  it('la lista blanca de tablas variables no tiene archivos que ya no existen', () => {
    for (const archivo of LISTA_BLANCA_TABLA_VARIABLE) {
      expect(fs.existsSync(path.join(RAIZ, archivo)), archivo).toBe(true)
    }
  })
})
