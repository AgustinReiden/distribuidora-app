import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * El front no llama RPCs que `authenticated` no puede ejecutar.
 *
 * Una función de `public` sin EXECUTE para `authenticated` es de servidor
 * (bot, cron, CI con service_role) o no la llama nadie. Si el front la llama,
 * falla en runtime con 42501 para TODOS los roles, y nada lo ve antes: el
 * nombre de la RPC es un string, `tsc` no lo mira y los tests mockean
 * `supabase.rpc`. Pasó con `useRecorridos.crearRecorrido`, que siguió
 * apuntando a `crear_recorrido` después de que la mig 314 (#1009) la revocara
 * (#1019).
 *
 * La lista son las funciones que una migración le revocó a `authenticated`. Al
 * revocar otra, sumala acá en el mismo PR; al devolverle el GRANT (con un guard
 * de rol, si es DEFINER), sacala.
 */
const RPCS_SIN_EXECUTE_PARA_AUTHENTICATED: Record<string, string> = {
  // mig 314 (#1009): sin caller en la app.
  crear_recorrido: 'mig 314',
  crear_rendicion_por_fecha: 'mig 314',
  obtener_estadisticas_rendiciones: 'mig 314',
  obtener_estadisticas_pedidos: 'mig 314',
  pedido_bundle_para_promo: 'mig 314',
  puede_leer_pedido: 'mig 314',
  // mig 314: sólo CI, con service_role (scripts/check-*.mjs).
  auditoria_permisos_execute: 'mig 314',
  auditoria_funciones_costo_sin_valuacion: 'mig 314',
  auditoria_funciones_stock_sin_origen: 'mig 314',
  auditoria_definer_sin_rol: 'mig 314',
  // #1020: sólo CI.
  auditoria_predicado_pedidos: '#1020',
}

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SRC = path.resolve(__dirname, '..')

function listarArchivos(dir: string, acc: string[] = []): string[] {
  for (const nombre of fs.readdirSync(dir)) {
    const ruta = path.join(dir, nombre)
    if (fs.statSync(ruta).isDirectory()) {
      if (nombre === 'node_modules' || nombre === '__tests__' || nombre === 'test') continue
      listarArchivos(ruta, acc)
    } else if (/\.(ts|tsx|js|jsx)$/.test(nombre) && !/\.(test|spec)\./.test(nombre)) {
      acc.push(ruta)
    }
  }
  return acc
}

describe('src/: RPCs sin EXECUTE para authenticated', () => {
  it('ningún archivo del front las llama por supabase.rpc', () => {
    const llamadas: string[] = []
    for (const archivo of listarArchivos(SRC)) {
      const texto = fs.readFileSync(archivo, 'utf8')
      for (const m of texto.matchAll(/\.rpc\(\s*['"`]([a-z0-9_]+)['"`]/g)) {
        const rpc = m[1]
        if (rpc in RPCS_SIN_EXECUTE_PARA_AUTHENTICATED) {
          llamadas.push(`${path.relative(SRC, archivo)} → ${rpc} (${RPCS_SIN_EXECUTE_PARA_AUTHENTICATED[rpc]})`)
        }
      }
    }
    expect(
      llamadas,
      'El front llama una RPC que authenticated no puede ejecutar: falla con 42501 para todos los roles',
    ).toEqual([])
  })
})
