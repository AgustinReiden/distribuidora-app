import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { evaluarFechasUtc, hayFallas, seccionesFaltantes } from '../../scripts/lib/fechasUtc.mjs'

/**
 * El comparador del gate `scripts/check-fechas-utc.mjs` (#1250, #1298). La
 * detección la hace `auditoria_fechas_utc()` en la base (su ensayo es
 * scripts/test-fechas-utc-1298.sql); acá se fija qué hace el gate con lo que
 * devuelve, y la forma de la lista permitida.
 */

type Funcion = { nombre: string; firma: string; patrones: string[] }
type Default = { columna: string; default: string }
type Objeto = { nombre: string; patrones: string[] }
type Seccion<T> = { nuevas: T[]; sobrantes: string[] }
type Resultado = {
  funciones: Seccion<Funcion>
  defaults: Seccion<Default>
  vistas: Seccion<Objeto>
  policies: Seccion<Objeto>
  checks: Seccion<Objeto>
}

const auditoria = (
  funciones: Funcion[],
  defaults: Default[] = [],
  otros: { vistas?: Objeto[]; policies?: Objeto[]; checks?: Objeto[] } = {},
) => ({
  generado_at: '2026-10-29T20:00:00Z',
  total_funciones: 500,
  funciones,
  defaults,
  vistas: otros.vistas ?? [],
  policies: otros.policies ?? [],
  checks: otros.checks ?? [],
})
const fn = (nombre: string, firma = `${nombre}()`): Funcion => ({ nombre, firma, patrones: ['CURRENT_DATE'] })
const vacia = { funciones: {}, defaults: {} }
const evaluar = (...args: Parameters<typeof evaluarFechasUtc>): Resultado => evaluarFechasUtc(...args)

describe('evaluarFechasUtc', () => {
  it('todo lo que aparece está permitido y todo lo permitido aparece: verde', () => {
    const r = evaluar(
      auditoria([fn('crear_recorrido', 'crear_recorrido(uuid)')], [{ columna: 'compras.fecha_compra', default: 'CURRENT_DATE' }]),
      { funciones: { 'crear_recorrido(uuid)': '#1277' }, defaults: { 'compras.fecha_compra': '#1277' } },
    )
    expect(hayFallas(r)).toBe(false)
  })

  it('una función nueva con el día UTC pone el gate en rojo', () => {
    const r = evaluar(auditoria([fn('reporte_nuevo', 'reporte_nuevo(date)')]), vacia)
    expect(r.funciones.nuevas.map((f) => f.firma)).toEqual(['reporte_nuevo(date)'])
    expect(hayFallas(r)).toBe(true)
  })

  it('un default nuevo con el día UTC pone el gate en rojo', () => {
    const r = evaluar(auditoria([], [{ columna: 'pedidos.fecha', default: 'CURRENT_DATE' }]), vacia)
    expect(r.defaults.nuevas.map((d) => d.columna)).toEqual(['pedidos.fecha'])
    expect(hayFallas(r)).toBe(true)
  })

  it('una vista, una policy o un CHECK nuevos también ponen el gate en rojo (#1298)', () => {
    const o = (nombre: string): Objeto => ({ nombre, patrones: ['ahora::date'] })
    const r = evaluar(
      auditoria([], [], { vistas: [o('v_hoy')], policies: [o('pagos.mt_pagos_hoy')], checks: [o('pagos.fecha_check')] }),
      vacia,
    )
    expect(r.vistas.nuevas.map((x) => x.nombre)).toEqual(['v_hoy'])
    expect(r.policies.nuevas.map((x) => x.nombre)).toEqual(['pagos.mt_pagos_hoy'])
    expect(r.checks.nuevas.map((x) => x.nombre)).toEqual(['pagos.fecha_check'])
    expect(hayFallas(r)).toBe(true)
  })

  it('una entrada permitida que ya no usa el día UTC también es rojo: la lista sólo se achica', () => {
    const r = evaluar(auditoria([]), {
      funciones: { 'registrar_compra_completa(bigint)': '#1277' },
      defaults: { 'rendiciones.fecha': '#1277' },
      checks: { 'pagos.fecha_check': '#1277' },
    })
    expect(r.funciones.sobrantes).toEqual(['registrar_compra_completa(bigint)'])
    expect(r.defaults.sobrantes).toEqual(['rendiciones.fecha'])
    expect(r.checks.sobrantes).toEqual(['pagos.fecha_check'])
    expect(hayFallas(r)).toBe(true)
  })

  it('compara por firma (#1298): una sobrecarga nueva de una permitida no pasa por el nombre', () => {
    const r = evaluar(
      auditoria([fn('crear_recorrido', 'crear_recorrido(uuid)'), fn('crear_recorrido', 'crear_recorrido(text)')]),
      { funciones: { 'crear_recorrido(uuid)': '#1277' }, defaults: {} },
    )
    expect(r.funciones.nuevas.map((f) => f.firma)).toEqual(['crear_recorrido(text)'])
    expect(hayFallas(r)).toBe(true)
  })

  it('cambiarle la firma a una permitida obliga a actualizar la lista', () => {
    const r = evaluar(auditoria([fn('crear_recorrido', 'crear_recorrido(uuid,date)')]), {
      funciones: { 'crear_recorrido(uuid)': '#1277' },
      defaults: {},
    })
    expect(r.funciones.nuevas.map((f) => f.firma)).toEqual(['crear_recorrido(uuid,date)'])
    expect(r.funciones.sobrantes).toEqual(['crear_recorrido(uuid)'])
  })

  it('una clave heredada de Object no cuenta como permitida', () => {
    const r = evaluar(auditoria([fn('toString', 'toString')]), vacia)
    expect(r.funciones.nuevas).toHaveLength(1)
  })
})

describe('seccionesFaltantes', () => {
  it('la salida de la 410, sin vistas, policies ni checks, no alcanza: falta la migración de #1298', () => {
    const vieja = { generado_at: 'x', total_funciones: 500, funciones: [], defaults: [] }
    expect(seccionesFaltantes(vieja)).toEqual(['vistas', 'policies', 'checks'])
    expect(seccionesFaltantes(auditoria([]))).toEqual([])
  })
})

describe('scripts/fechas-utc-permitidas.json', () => {
  const ruta = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../scripts/fechas-utc-permitidas.json')
  const lista = JSON.parse(fs.readFileSync(ruta, 'utf8')) as Record<
    'funciones' | 'defaults' | 'vistas' | 'policies' | 'checks',
    Record<string, string>
  >
  const todas = () => [
    ...Object.entries(lista.funciones),
    ...Object.entries(lista.defaults),
    ...Object.entries(lista.vistas),
    ...Object.entries(lista.policies),
    ...Object.entries(lista.checks),
  ]
  const permitida = (nombre: string) => Object.keys(lista.funciones).some((firma) => firma.startsWith(`${nombre}(`))

  it('tiene las cinco secciones del gate', () => {
    for (const s of ['funciones', 'defaults', 'vistas', 'policies', 'checks'] as const) {
      expect(typeof lista[s], s).toBe('object')
    }
  })

  it('cada entrada dice en qué issue se arregla', () => {
    for (const [nombre, motivo] of todas()) {
      expect(motivo, nombre).toMatch(/#\d+/)
    }
  })

  it('las funciones van por firma y los defaults como tabla.columna', () => {
    for (const firma of Object.keys(lista.funciones)) {
      expect(firma).toMatch(/^[a-z_][a-z0-9_]*\(.*\)$/)
    }
    for (const columna of Object.keys(lista.defaults)) {
      expect(columna).toMatch(/^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$/)
    }
  })

  it('ninguna función de la tarjeta 7 de #1268 vuelve a la lista', () => {
    const arregladas = [
      'reporte_gerencial', 'reporte_alerta_detalle', 'reporte_cuentas_por_cobrar',
      'avance_metas_preventista', 'rendimiento_preventistas', 'obtener_deudores_mora',
      'bot_metricas_admin_dia',
    ]
    for (const nombre of arregladas) {
      expect(permitida(nombre), nombre).toBe(false)
    }
    expect(Object.prototype.hasOwnProperty.call(lista.defaults, 'pedidos.fecha')).toBe(false)
  })

  it('ninguna función de la rendición de #1298 vuelve a la lista', () => {
    for (const nombre of [
      '_rendicion_pagos', '_rendicion_entregas', '_rendicion_tomar_foto', 'resolver_rendicion',
      'crear_rendicion_por_fecha', 'cambiar_tipo_factura_pedido',
    ]) {
      expect(permitida(nombre), nombre).toBe(false)
    }
  })
})
