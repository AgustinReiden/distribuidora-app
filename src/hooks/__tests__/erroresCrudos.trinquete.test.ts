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
 * Este test falla si en `src/hooks/`, `src/components/`, `src/utils/` o `src/services/`
 * aparece un `throw <variable>`, un `throw new Error(error.message)` o un
 * `throw new Error(`...${error.message}`)` que no esté en la lista de abajo. La
 * lista es EXACTA, por archivo: sólo hay relanzamientos de un error que ya viene
 * normalizado (un `catch (err) { ...; throw err }`) o que ya es un `Error` propio.
 * Si agregás código nuevo, lanzá `errorDeSupabase(...)`; si de verdad relanzás un
 * Error ya normalizado, sumalo a PERMITIDOS con el motivo.
 *
 * #1011 amplió el alcance: el mismo `if (error) throw error` vivía en los containers
 * (PedidosContainer), en `paginacion.ts` y en una pantalla de ruta, fuera de la capa
 * de datos que vigilaba el #760. Para conservar una etiqueta ("Error cargando X: ...")
 * se normaliza con `errorDeSupabase` y se le antepone el prefijo al mensaje; no se
 * arma un `new Error` con `${error.message}`.
 */
const AQUI = path.dirname(fileURLToPath(import.meta.url))
const SRC = path.resolve(AQUI, '..', '..')
// Capa de datos y todo lo que le habla a supabase: hooks, containers/vistas/modales,
// utils (paginacion) y services (exports). #1011 amplió el alcance más allá de hooks.
const RAICES = ['hooks', 'components', 'utils', 'services']

// `throw error` / `throw err` / `throw delError` ...: una variable, no `new` ni la llamada.
const RE_THROW_VARIABLE = /\bthrow\s+(?!new\b)(?!errorDeSupabase\b)[A-Za-z_][\w.]*\s*;?\s*(?:\}|$)/
// `throw new Error(error.message)` (con o sin `;` final): pierde el code y no traduce la red.
const RE_THROW_MENSAJE = /\bthrow\s+new\s+Error\(\s*\w*[eE]rr\w*\??\.message\s*\)/
// `throw new Error(\`Error cargando ${etiqueta}: ${error.message}\`)`: la misma pérdida, escondida
// en una plantilla (paginacion.ts, usePedidoStatsQuery.ts). `${otraCosa}` sin `.message` de un error no cuenta.
const RE_THROW_PLANTILLA = /\bthrow\s+new\s+Error\(\s*`[^`]*\$\{\s*\w*[eE]rr\w*\??\.message\s*\}/

/** Relanzamientos legítimos, contados por archivo (ruta relativa a src/). */
const PERMITIDOS: Record<string, number> = {
  // catch (err) { ...; throw err }: relanza lo que ya normalizaron las mutaciones de adentro.
  'hooks/queries/useAsegurarCatalogo.ts': 3,
  // dentro de un try/catch sin binding: el error se descarta y no llega a la UI.
  'hooks/queries/useCargosCatalogoQuery.ts': 1,
  // dentro de un try/catch que sólo hace console.warn: no llega a la UI.
  'hooks/queries/usePedidosQuery.ts': 1,
  // catch de traerTodo, que ya arma su propio Error con el mensaje del servidor.
  'hooks/queries/usePromocionesQuery.ts': 1,
  // catch (err) { ...; throw err }: relanza lo que ya salió normalizado de adentro.
  'hooks/supabase/usePagos.ts': 5,
  // el catch devuelve un valor vacío: el error nunca sale.
  'hooks/supabase/useRecorridos.ts': 1,
  // AuthError de supabase-js SÍ es un Error (a diferencia de PostgrestError).
  'hooks/supabase/useAuth.tsx': 2,
  // ya es un Error (se arma con err instanceof Error ? err : new Error(...)).
  'hooks/useAsync.ts': 1,
  // el rethrow del catch de un reintento de sesión: el error ya viene de crearPedidoFn.
  'hooks/useOfflineSync.ts': 1,
  // FunctionsError de supabase.functions.invoke es un Error; otro dominio (edge function).
  'hooks/useNavTramo.ts': 1,
  // `error.code === '22023'`: respondió el servidor, y el mensaje que se muestra ES el
  // suyo (con prefijo). No hay red que traducir; sólo se pierde el code, que nadie lee.
  'hooks/queries/useImpuestosInternosQuery.ts': 1,

  // ---- components / utils (#1011) ----
  // catch (err) { notify.error(...); throw err }: el modal necesita el rechazo para quedar
  // abierto. Lo que llega de mutateAsync ya salió normalizado de la capa de datos.
  'components/containers/ClientesContainer.tsx': 3,
  'components/containers/ComprasContainer.tsx': 5,
  'components/containers/ProductosContainer.tsx': 4,
  'components/containers/UsuariosContainer.tsx': 1,
  'components/containers/VistaBotTelegramContainer.tsx': 3,
  // 7 de 8 son el mismo catch (e) { notify.error(...); throw e } que relanza lo ya normalizado
  // (mutateAsync, usePagos y los handlers de arriba, que ahora lanzan errorDeSupabase). El 8º
  // es el de handleSaveSalvedades: `new Error(response.error.message)` a propósito CRUDO para
  // que retryWithBackoff lo reconozca como transitorio; el catch de abajo lo traduce a
  // "Sin conexion estable" y nunca llega a la UI.
  'components/containers/PedidosContainer.tsx': 8,
  // catch (err) { if (esErrorDeChunk(err) ...) ...; throw err }: no es un error de supabase, es
  // el import() dinámico de un chunk. El otro `throw err` es el mismo caso.
  'utils/lazyWithReload.ts': 2,
  // retryWithBackoff es genérico: relanza lo que lanzó `fn`, sea lo que sea. Quien lo llama
  // decide cómo mostrarlo (ver el 8º de PedidosContainer).
  'utils/retryWithBackoff.ts': 2,
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
    .filter((l) => RE_THROW_VARIABLE.test(l) || RE_THROW_MENSAJE.test(l) || RE_THROW_PLANTILLA.test(l))
}

function contar(): Record<string, string[]> {
  const out: Record<string, string[]> = {}
  for (const raiz of RAICES) {
    for (const archivo of listar(path.join(SRC, raiz))) {
      const lineas = lineasCrudas(fs.readFileSync(archivo, 'utf8'))
      if (lineas.length > 0) out[path.relative(SRC, archivo).split(path.sep).join('/')] = lineas.map((l) => l.trim())
    }
  }
  return out
}

describe('trinquete: código que lanza el error crudo de supabase (#760, #1011)', () => {
  it('el detector reconoce las formas que escondían el mensaje', () => {
    expect(lineasCrudas('if (error) throw error')).toHaveLength(1)
    expect(lineasCrudas('  if (delError) throw delError')).toHaveLength(1)
    expect(lineasCrudas('throw new Error(error.message)')).toHaveLength(1)
    expect(lineasCrudas('if (error) throw new Error(updateErr.message)')).toHaveLength(1)
  })

  it('el detector reconoce la plantilla que interpola el message de un error y la forma con ";"', () => {
    expect(lineasCrudas('if (error) throw new Error(`Error cargando ${etiqueta}: ${error.message}`)')).toHaveLength(1)
    expect(lineasCrudas('    if (error) throw new Error(`No se pudo contar ${etiqueta}: ${error.message}`)')).toHaveLength(1)
    expect(lineasCrudas('throw new Error(`falló: ${err.message}`)')).toHaveLength(1)
    expect(lineasCrudas('throw new Error(`falló: ${updateErr?.message}`)')).toHaveLength(1)
    expect(lineasCrudas('if (error) throw new Error(error.message);')).toHaveLength(1)
    expect(lineasCrudas('if (error) throw error;')).toHaveLength(1)
  })

  it('no marca lo que ya está normalizado ni los errores propios', () => {
    expect(lineasCrudas("if (error) throw errorDeSupabase(error, 'Sin conexión')")).toHaveLength(0)
    expect(lineasCrudas("throw new Error('No hay sucursal activa')")).toHaveLength(0)
    expect(lineasCrudas('// if (error) throw error')).toHaveLength(0)
  })

  it('no marca throws que no son el message crudo de un error', () => {
    expect(lineasCrudas("if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar X.');")).toHaveLength(0)
    expect(lineasCrudas('throw errorEtiquetado(error, sinConexion, prefijo)')).toHaveLength(0)
    expect(lineasCrudas("throw new Error('texto fijo');")).toHaveLength(0)
    expect(lineasCrudas('throw new Error(`Se superó el tope de ${tope} filas trayendo ${etiqueta}.`)')).toHaveLength(0)
    expect(lineasCrudas('throw new Error(`falló ${otraCosa}`)')).toHaveLength(0)
    expect(lineasCrudas('throw new Error(`falló ${respuesta.message}`)')).toHaveLength(0)
  })

  it('nada nuevo lanza el error crudo: usá errorDeSupabase(error, <sin conexión>)', () => {
    const encontrados = contar()
    const detalle = Object.entries(encontrados)
      .map(([f, ls]) => `${f}\n    ${ls.join('\n    ')}`)
      .join('\n')
    const cuenta = Object.fromEntries(Object.entries(encontrados).map(([f, ls]) => [f, ls.length]))
    expect(cuenta, `Throws crudos:\n${detalle}`).toEqual(PERMITIDOS)
  })
})
