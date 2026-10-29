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
  pedido_bundle_para_promo: 'mig 314',
  puede_leer_pedido: 'mig 314',
  // mig 314: sólo CI, con service_role (scripts/check-*.mjs).
  auditoria_permisos_execute: 'mig 314',
  auditoria_funciones_costo_sin_valuacion: 'mig 314',
  auditoria_funciones_stock_sin_origen: 'mig 314',
  auditoria_definer_sin_rol: 'mig 314',
  // #1020: sólo CI.
  auditoria_predicado_pedidos: '#1020',
  // #1048: dejaban suplantar a un admin / guard que no se ejecutaba; sin caller.
  registrar_ingreso_sucursal: '#1048',
  registrar_transferencia: '#1048, borrada en #1108',
  cerrar_recorridos_vencidos: '#1048',
  // #1048: helper de las RPCs de comisiones, sólo lo llaman DEFINER.
  comision_regla_alcanzable: '#1048',
  // #1056: un transportista borraba el orden de otro; sin caller.
  limpiar_orden_entrega: '#1056',
  // #1076: borrada (DROP), bajaba stock sin app.stock_origen; sin caller.
  descontar_stock_atomico: '#1076',
  // #1097: helpers de servidor de la huella lote -> linea; solo los llaman
  // actualizar_pedido_items, sustituir_regalo_pedido y dividir_regalo_pedido.
  _foto_huella_lineas: '#1097',
  _rehacer_huella_lineas: '#1097',
  // #1090: pura de servidor de la cantidad de corte; solo la llaman
  // actualizar_pedido_items, dividir_regalo_pedido y el gate de paridad
  // (scripts/espejo-cadena-regalo.mjs, con service_role).
  regalo_cantidad_base: '#1090',
  // #1135: sólo CI, con service_role (scripts/check-grants-tablas.mjs).
  auditoria_grants_tablas: '#1135',
  // cargo_1_base (#1220): puras del cargo de envío, sólo las llaman las RPCs
  // DEFINER y el gate de paridad (scripts/espejo-cargo-envio.mjs, con
  // service_role); el front tiene su espejo en src/utils/montoMinimo.ts. Y el
  // estado con que nace un pedido, que sólo lo llaman las RPCs de alta.
  cargo_envio_pedido_puro: 'cargo_1_base',
  cargo_envio_desglose: 'cargo_1_base',
  cargo_tras_edicion: 'cargo_1_base',
  _cargo_envio_estado_alta: 'cargo_1_base',
  // #1262: la Red de los reportes; sólo la llaman los reportes DEFINER.
  _sucursales_red: '#1262',
  // #1250: sólo CI, con service_role (scripts/check-fechas-utc.mjs).
  auditoria_fechas_utc: '#1250',
  // cobros_1 y cobros_2 (#1249, #1246): helpers de las RPCs de pago, sólo los
  // llaman las DEFINER. El front cobra por registrar_pagos_pedido, el wrapper.
  _forma_pago_de_cobro: 'cobros_1',
  registrar_pagos_pedido_impl: 'cobros_2',
  // cobros_3 (#1248): el excedente al cambiar el cliente y la foto de la
  // rendición; los llaman cambiar_cliente_pedido y las RPCs de rendición.
  _pagos_excedente_a_favor: 'cobros_3',
  _rendicion_pagos: 'cobros_3',
  _rendicion_entregas: 'cobros_3',
  _rendicion_tomar_foto: 'cobros_3',
  // gastos_1 (gastos 1/5): la expansión por mes la consume el estado de
  // resultados desde el server; la cuota es su pura (el front tiene
  // cuotaDeGasto en src/utils/gastos.ts); y el chequeo de "todas las
  // sucursales" sólo lo llaman guardar_gasto y anular_gasto.
  gastos_por_mes: 'mig 411_gastos_1',
  _gasto_cuota: 'mig 411_gastos_1',
  _tiene_todas_las_sucursales: 'mig 411_gastos_1',
  // gastos_3 (gastos 2/5): el cuerpo de guardar_gasto y anular_gasto, que
  // también llama confirmar_rendicion desde el cierre, y la clave y el lock de
  // una rendición.
  _guardar_gasto: 'NNN_gastos_3',
  _anular_gasto: 'NNN_gastos_3',
  _rendicion_clave: 'NNN_gastos_3',
  _rendicion_bloquear: 'NNN_gastos_3',
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
