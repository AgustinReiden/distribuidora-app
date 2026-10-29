import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
// @ts-expect-error -- módulo .mjs de scripts/, sin tipos
import { evaluarFechasUtc, hayFallas } from '../../scripts/lib/fechasUtc.mjs'

/**
 * El comparador del gate `scripts/check-fechas-utc.mjs` (#1250). La detección
 * la hace `auditoria_fechas_utc()` en la base; acá se fija qué hace el gate con
 * lo que devuelve, y la forma de la lista permitida.
 */

type Funcion = { nombre: string; firma: string; patrones: string[] }
type Default = { columna: string; default: string }
const auditoria = (funciones: Funcion[], defaults: Default[] = []) => ({
  generado_at: '2026-10-28T20:00:00Z',
  total_funciones: 500,
  funciones,
  defaults,
})
const fn = (nombre: string, firma = `${nombre}()`): Funcion => ({ nombre, firma, patrones: ['CURRENT_DATE'] })

describe('evaluarFechasUtc', () => {
  it('todo lo que aparece está permitido y todo lo permitido aparece: verde', () => {
    const r = evaluarFechasUtc(
      auditoria([fn('crear_recorrido')], [{ columna: 'compras.fecha_compra', default: 'CURRENT_DATE' }]),
      { funciones: { crear_recorrido: '#1277' }, defaults: { 'compras.fecha_compra': '#1277' } },
    )
    expect(hayFallas(r)).toBe(false)
  })

  it('una función nueva con el día UTC pone el gate en rojo', () => {
    const r = evaluarFechasUtc(auditoria([fn('reporte_nuevo', 'reporte_nuevo(date)')]), {
      funciones: {},
      defaults: {},
    })
    expect(r.funcionesNuevas.map((f: Funcion) => f.firma)).toEqual(['reporte_nuevo(date)'])
    expect(hayFallas(r)).toBe(true)
  })

  it('un default nuevo con el día UTC pone el gate en rojo', () => {
    const r = evaluarFechasUtc(
      auditoria([], [{ columna: 'pedidos.fecha', default: 'CURRENT_DATE' }]),
      { funciones: {}, defaults: {} },
    )
    expect(r.defaultsNuevos.map((d: Default) => d.columna)).toEqual(['pedidos.fecha'])
    expect(hayFallas(r)).toBe(true)
  })

  it('una entrada permitida que ya no usa el día UTC también es rojo: la lista sólo se achica', () => {
    const r = evaluarFechasUtc(auditoria([]), {
      funciones: { registrar_compra_completa: '#1277' },
      defaults: { 'rendiciones.fecha': '#1277' },
    })
    expect(r.funcionesSobrantes).toEqual(['registrar_compra_completa'])
    expect(r.defaultsSobrantes).toEqual(['rendiciones.fecha'])
    expect(hayFallas(r)).toBe(true)
  })

  it('compara por nombre: cambiar la firma de una permitida no la vuelve nueva', () => {
    const r = evaluarFechasUtc(auditoria([fn('crear_recorrido', 'crear_recorrido(uuid,jsonb,numeric,integer,date)')]), {
      funciones: { crear_recorrido: '#1277' },
      defaults: {},
    })
    expect(hayFallas(r)).toBe(false)
  })

  it('una clave heredada de Object no cuenta como permitida', () => {
    const r = evaluarFechasUtc(auditoria([fn('toString')]), { funciones: {}, defaults: {} })
    expect(r.funcionesNuevas).toHaveLength(1)
  })
})

describe('scripts/fechas-utc-permitidas.json', () => {
  const ruta = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../scripts/fechas-utc-permitidas.json')
  const lista = JSON.parse(fs.readFileSync(ruta, 'utf8')) as {
    funciones: Record<string, string>
    defaults: Record<string, string>
  }

  it('cada entrada dice en qué issue se arregla', () => {
    for (const [nombre, motivo] of [...Object.entries(lista.funciones), ...Object.entries(lista.defaults)]) {
      expect(motivo, nombre).toMatch(/#\d+/)
    }
  })

  it('los defaults van como tabla.columna', () => {
    for (const columna of Object.keys(lista.defaults)) {
      expect(columna).toMatch(/^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$/)
    }
  })

  it('ninguna función de la tarjeta 7 vuelve a la lista', () => {
    const arregladas = [
      'reporte_gerencial', 'reporte_alerta_detalle', 'reporte_cuentas_por_cobrar',
      'avance_metas_preventista', 'rendimiento_preventistas', 'obtener_deudores_mora',
      'bot_metricas_admin_dia',
    ]
    for (const nombre of arregladas) {
      expect(Object.prototype.hasOwnProperty.call(lista.funciones, nombre), nombre).toBe(false)
    }
    expect(Object.prototype.hasOwnProperty.call(lista.defaults, 'pedidos.fecha')).toBe(false)
  })
})
