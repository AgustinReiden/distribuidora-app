import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * Test-TRINQUETE de errores crudos de supabase en la capa de datos (#760).
 *
 * supabase-js NO lanza `Error`: devuelve un objeto plano. Un hook que hace
 * `if (error) throw error` le entrega ese objeto a la UI, y el
 * `err instanceof Error ? err.message : '<generico>'` de cada pantalla descarta
 * el mensaje real del servidor. La capa de datos tiene que lanzar
 * `errorDeSupabase(error, '<mensaje sin conexión>')` (src/utils/errorDeSupabase.ts).
 *
 * Este test falla si en `src/hooks/` aparece un `throw <variable>` o un
 * `throw new Error(error.message)` que no esté en la lista de abajo. La lista es
 * EXACTA, por archivo: sólo hay relanzamientos de un error que ya viene
 * normalizado (un `catch (err) { ...; throw err }`) o que ya es un `Error` propio.
 * Si agregás un hook nuevo, lanzá `errorDeSupabase(...)`; si de verdad relanzás un
 * Error ya normalizado, sumalo a PERMITIDOS con el motivo.
 */
const AQUI = path.dirname(fileURLToPath(import.meta.url))
const HOOKS = path.resolve(AQUI, '..')

// `throw error` / `throw err` / `throw delError` ...: una variable, no `new` ni la llamada.
const RE_THROW_VARIABLE = /\bthrow\s+(?!new\b)(?!errorDeSupabase\b)[A-Za-z_][\w.]*\s*;?\s*(?:\}|$)/
// `throw new Error(error.message)`: pierde el code y no traduce la red.
const RE_THROW_MENSAJE = /\bthrow\s+new\s+Error\(\s*\w*[eE]rr\w*\.message\s*\)/

/** Relanzamientos legítimos, contados por archivo (ruta relativa a src/hooks). */
const PERMITIDOS: Record<string, number> = {
  // catch (err) { ...; throw err }: relanza lo que ya normalizaron las mutaciones de adentro.
  'queries/useAsegurarCatalogo.ts': 3,
  // dentro de un try/catch sin binding: el error se descarta y no llega a la UI.
  'queries/useCargosCatalogoQuery.ts': 1,
  // dentro de un try/catch que sólo hace console.warn: no llega a la UI.
  'queries/usePedidosQuery.ts': 1,
  // catch de traerTodo, que ya arma su propio Error con el mensaje del servidor.
  'queries/usePromocionesQuery.ts': 1,
  // catch (err) { ...; throw err }: relanza lo que ya salió normalizado de adentro.
  'supabase/usePagos.ts': 5,
  // el catch devuelve un valor vacío: el error nunca sale.
  'supabase/useRecorridos.ts': 1,
  // AuthError de supabase-js SÍ es un Error (a diferencia de PostgrestError).
  'supabase/useAuth.tsx': 2,
  // ya es un Error (se arma con err instanceof Error ? err : new Error(...)).
  'useAsync.ts': 1,
  // el rethrow del catch de un reintento de sesión: el error ya viene de crearPedidoFn.
  'useOfflineSync.ts': 1,
  // FunctionsError de supabase.functions.invoke es un Error; otro dominio (edge function).
  'useNavTramo.ts': 1,
}

function listar(dir: string, acc: string[] = []): string[] {
  for (const nombre of fs.readdirSync(dir)) {
    const ruta = path.join(dir, nombre)
    if (fs.statSync(ruta).isDirectory()) {
      if (nombre === 'node_modules' || nombre === '__tests__') continue
      listar(ruta, acc)
    } else if (/\.(ts|tsx)$/.test(nombre) && !/\.(test|spec)\./.test(nombre)) {
      acc.push(ruta)
    }
  }
  return acc
}

export function lineasCrudas(codigo: string): string[] {
  return codigo
    .split(/\r?\n/)
    .filter((l) => !/^\s*(\/\/|\*|\/\*)/.test(l))
    .filter((l) => RE_THROW_VARIABLE.test(l) || RE_THROW_MENSAJE.test(l))
}

function contar(): Record<string, string[]> {
  const out: Record<string, string[]> = {}
  for (const archivo of listar(HOOKS)) {
    const lineas = lineasCrudas(fs.readFileSync(archivo, 'utf8'))
    if (lineas.length > 0) out[path.relative(HOOKS, archivo).split(path.sep).join('/')] = lineas.map((l) => l.trim())
  }
  return out
}

describe('trinquete: hooks que lanzan el error crudo de supabase (#760)', () => {
  it('el detector reconoce las formas que escondían el mensaje', () => {
    expect(lineasCrudas('if (error) throw error')).toHaveLength(1)
    expect(lineasCrudas('  if (delError) throw delError')).toHaveLength(1)
    expect(lineasCrudas('throw new Error(error.message)')).toHaveLength(1)
    expect(lineasCrudas('if (error) throw new Error(updateErr.message)')).toHaveLength(1)
  })

  it('no marca lo que ya está normalizado ni los errores propios', () => {
    expect(lineasCrudas("if (error) throw errorDeSupabase(error, 'Sin conexión')")).toHaveLength(0)
    expect(lineasCrudas("throw new Error('No hay sucursal activa')")).toHaveLength(0)
    expect(lineasCrudas('// if (error) throw error')).toHaveLength(0)
  })

  it('ningún hook nuevo lanza el error crudo: usá errorDeSupabase(error, <sin conexión>)', () => {
    const encontrados = contar()
    const detalle = Object.entries(encontrados)
      .map(([f, ls]) => `${f}\n    ${ls.join('\n    ')}`)
      .join('\n')
    const cuenta = Object.fromEntries(Object.entries(encontrados).map(([f, ls]) => [f, ls.length]))
    expect(cuenta, `Throws crudos:\n${detalle}`).toEqual(PERMITIDOS)
  })
})
