import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { MOTIVOS_ADMINISTRATIVOS, MOTIVOS_CANCELACION_TODOS } from '../constants/desenlacePedido'
import { MOTIVOS_SALVEDAD_LABELS } from '../lib/schemas'
import { LABEL_MOTIVO } from '../constants/motivosNoEntrega'
import {
  esRechazoTotal,
  tasaRechazo,
  tasaRechazoTotal,
  tasaConSalvedad,
  formatTasa,
  labelMotivoRechazo,
  filtrarDetalleRechazos,
  resumirRechazos,
  claveMotivo,
  FILTROS_DETALLE_VACIOS,
  SIN_ASIGNAR,
  type FilaRechazo,
} from './rechazos'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const DIR_MIGRACIONES = path.resolve(__dirname, '../../migrations')

/** La migración que crea `reporte_rechazos` (la última, si hubiera varias). */
function sqlReporteRechazos(): string {
  const archivos = fs.readdirSync(DIR_MIGRACIONES)
    .filter((a) => a.endsWith('.sql'))
    .sort()
    .filter((a) => /CREATE (OR REPLACE )?FUNCTION public\.reporte_rechazos\(/.test(
      fs.readFileSync(path.join(DIR_MIGRACIONES, a), 'utf8')))
  expect(archivos.length, 'no hay migración que cree reporte_rechazos').toBeGreaterThan(0)
  return fs.readFileSync(path.join(DIR_MIGRACIONES, archivos[archivos.length - 1]), 'utf8')
}

describe('esRechazoTotal: espejo del filtro de reporte_rechazos', () => {
  it('la lista administrativa del SQL es MOTIVOS_ADMINISTRATIVOS', () => {
    const m = /v_motivos_admin\s+text\[\]\s*:=\s*ARRAY\[([^\]]*)\]/.exec(sqlReporteRechazos())
    expect(m, 'no se encontró v_motivos_admin en la migración').not.toBeNull()
    const delSql = m![1].split(',').map((s) => s.trim().replace(/^'|'$/g, ''))
    expect([...delSql].sort()).toEqual([...MOTIVOS_ADMINISTRATIVOS].sort())
  })

  it('clasifica cada motivo del CHECK: administrativo o rechazo, ninguno queda afuera', () => {
    for (const m of MOTIVOS_CANCELACION_TODOS) {
      expect(esRechazoTotal(m)).toBe(!(MOTIVOS_ADMINISTRATIVOS as readonly string[]).includes(m))
    }
  })

  it('el cancelado sin motivo cuenta como rechazo', () => {
    expect(esRechazoTotal(null)).toBe(true)
    expect(esRechazoTotal(undefined)).toBe(true)
    expect(esRechazoTotal('')).toBe(true)
  })

  it('cliente_cancelo es rechazo; falta_stock y error_de_carga no', () => {
    expect(esRechazoTotal('cliente_cancelo')).toBe(true)
    expect(esRechazoTotal('cerrado')).toBe(true)
    expect(esRechazoTotal('falta_stock')).toBe(false)
    expect(esRechazoTotal('error_de_carga')).toBe(false)
  })
})

describe('tasa de rechazo: espejo del RPC', () => {
  it('Tucumán en septiembre de 2026 (ensayo contra prod): 34 + 49 sobre 897', () => {
    const c = { pedidos_salieron: 897, rechazos_totales: 34, pedidos_con_salvedad: 49 }
    expect(tasaRechazo(c)).toBe(0.0925)
    expect(tasaRechazoTotal(c)).toBe(0.0379)
    expect(tasaConSalvedad(c)).toBe(0.0546)
  })

  it('el caso armado de la migración: 1 entero + 1 con salvedad sobre 3', () => {
    const c = { pedidos_salieron: 3, rechazos_totales: 1, pedidos_con_salvedad: 1 }
    expect(tasaRechazo(c)).toBe(0.6667)
    expect(tasaRechazoTotal(c)).toBe(0.3333)
  })

  it('sin pedidos que salieron no hay tasa', () => {
    expect(tasaRechazo({ pedidos_salieron: 0, rechazos_totales: 0, pedidos_con_salvedad: 0 })).toBeNull()
    expect(formatTasa(null)).toBe('—')
  })

  it('la fórmula del SQL es la misma', () => {
    const sql = sqlReporteRechazos()
    expect(sql).toContain("'tasa_rechazo', round((t.rechazos_totales + t.pedidos_con_salvedad)::numeric / NULLIF(t.pedidos_salieron, 0), 4)")
  })

  it('formatea en porcentaje', () => {
    expect(formatTasa(0.0925)).toBe('9,3 %')
    expect(formatTasa(0)).toBe('0 %')
  })
})

describe('labelMotivoRechazo', () => {
  it('el pedido entero usa la etiqueta de cancelación; la línea, la de salvedad', () => {
    expect(labelMotivoRechazo('total', 'cerrado')).toBe(LABEL_MOTIVO.cerrado)
    expect(labelMotivoRechazo('total', 'sin_motivo')).toBe('Sin motivo')
    expect(labelMotivoRechazo('parcial', 'producto_danado')).toBe(MOTIVOS_SALVEDAD_LABELS.producto_danado)
  })

  it('un motivo desconocido se muestra tal cual en vez de desaparecer', () => {
    expect(labelMotivoRechazo('parcial', 'motivo_nuevo')).toBe('motivo_nuevo')
    expect(labelMotivoRechazo('total', 'motivo_nuevo')).toBe('motivo_nuevo')
  })
})

function fila(p: Partial<FilaRechazo>): FilaRechazo {
  return {
    tipo: 'parcial', pedido_id: 1, salvedad_id: 1, fecha: '2026-09-10', sucursal_id: 1, sucursal_nombre: 'Tucuman',
    cliente_id: 1, cliente_nombre: 'Kiosco Ana', cliente_activo: true, usuario_id: 'u1', preventista_nombre: 'Marcelo',
    transportista_id: 't1', chofer_nombre: 'Marcos', motivo: 'cliente_rechaza', descripcion: null,
    producto_id: 10, producto_nombre: 'Coca 2L', producto_codigo: 'C2', lineas: 1, unidades: 2, monto: 200,
    venta_perdida: 200, perdida_real: 0, mermas_sin_costo: 0, destino: 'devuelto', estado_resolucion: 'pendiente',
    ...p,
  }
}

describe('filtrarDetalleRechazos y resumirRechazos', () => {
  const filas: FilaRechazo[] = [
    fila({ pedido_id: 1, salvedad_id: 1 }),
    fila({ pedido_id: 2, salvedad_id: 2, motivo: 'producto_danado', destino: 'mermado', venta_perdida: 0, perdida_real: 60, monto: 100, producto_nombre: 'Pepsi' }),
    fila({ tipo: 'total', pedido_id: 3, salvedad_id: null, motivo: 'cliente_rechaza', transportista_id: null, chofer_nombre: null, producto_id: null, producto_nombre: null, monto: 300, venta_perdida: 300, lineas: 2, unidades: 3 }),
    fila({ tipo: 'total', pedido_id: 4, salvedad_id: null, motivo: 'cerrado', usuario_id: 'u2', preventista_nombre: 'Osvaldo', monto: 50, venta_perdida: 50, cliente_nombre: 'Almacén Inactivo', cliente_activo: false }),
  ]

  it('sin filtros devuelve todo', () => {
    expect(filtrarDetalleRechazos(filas, FILTROS_DETALLE_VACIOS)).toHaveLength(4)
  })

  it('el motivo distingue el pedido entero de la línea con el mismo valor', () => {
    const r = filtrarDetalleRechazos(filas, { ...FILTROS_DETALLE_VACIOS, motivo: claveMotivo('total', 'cliente_rechaza') })
    expect(r.map((x) => x.pedido_id)).toEqual([3])
  })

  it('"sin chofer" trae sólo los que no tienen transportista', () => {
    const r = filtrarDetalleRechazos(filas, { ...FILTROS_DETALLE_VACIOS, chofer: SIN_ASIGNAR })
    expect(r.map((x) => x.pedido_id)).toEqual([3])
  })

  it('por preventista y por tipo', () => {
    expect(filtrarDetalleRechazos(filas, { ...FILTROS_DETALLE_VACIOS, preventista: 'u2' }).map((x) => x.pedido_id)).toEqual([4])
    expect(filtrarDetalleRechazos(filas, { ...FILTROS_DETALLE_VACIOS, tipo: 'parcial' })).toHaveLength(2)
  })

  it('la búsqueda mira cliente, producto y número de pedido, y encuentra al cliente inactivo', () => {
    expect(filtrarDetalleRechazos(filas, { ...FILTROS_DETALLE_VACIOS, busqueda: 'pepsi' }).map((x) => x.pedido_id)).toEqual([2])
    expect(filtrarDetalleRechazos(filas, { ...FILTROS_DETALLE_VACIOS, busqueda: 'inactivo' }).map((x) => x.pedido_id)).toEqual([4])
    expect(filtrarDetalleRechazos(filas, { ...FILTROS_DETALLE_VACIOS, busqueda: '3' }).map((x) => x.pedido_id)).toEqual([3])
  })

  it('el resumen separa venta perdida de pérdida real', () => {
    expect(resumirRechazos(filas)).toEqual({
      casos: 4, pedidos_enteros: 2, lineas: 2, monto: 650, venta_perdida: 550, perdida_real: 60,
    })
  })
})
