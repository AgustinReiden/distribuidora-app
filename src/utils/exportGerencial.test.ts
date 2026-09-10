import { describe, it, expect } from 'vitest'
import {
  hojaMetadatos,
  hojasResumen,
  hojasEvolucion,
  hojasVendedores,
  hojasCategorias,
  hojasTopProductos,
  hojasTopClientes,
  hojasCobranza,
  hojasMermas,
  hojasCompras,
  hojasBonificaciones,
  hojasAlertas,
  hojasTodo,
  nombreArchivo,
  BLOQUES_GERENCIAL,
} from './exportGerencial'
import type { ReporteGerencial } from '../hooks/queries/useReporteGerencialQuery'

/** Payload mínimo pero completo: cada bloque tiene al menos una fila. */
function reporte(over: Partial<ReporteGerencial> = {}): ReporteGerencial {
  return {
    meta: {
      sucursal_id: 1,
      sucursal_nombre: 'Tucumán',
      desde: '2026-08-01',
      hasta: '2026-08-31',
      generado_at: '2026-09-08T12:00:00Z',
      incluye_no_entregados: false,
    },
    kpis: {
      venta: 100000, pedidos: 50, clientes: 20, ticket: 2000, clientes_nuevos: 3,
      cmv: 60000, bonif: 5000, unidades: 500, unidades_bonif: 25,
      margen_comercial: 40000, margen_neto: 35000, base_comision: 95000,
      comision_pct_default: 2, mermas: 1000, compras: 70000, ingreso_sin_costo: 0,
      venta_real: 90000, margen_real: 38000,
    } as ReporteGerencial['kpis'],
    mensual: [{ mes: '2026-08', pedidos: 50, venta: 100000, clientes: 20, ticket: 2000, cmv: 60000, bonif: 5000, mermas: 1000, compras: 70000 }],
    vendedores: [{ nombre: 'Christian', rol: 'preventista', pedidos: 30, venta: 60000, margen_comercial: 24000, bonif: 3000, base_nc: 58000 }],
    categorias: [{ categoria: 'Bebidas', venta: 70000, margen_comercial: 28000, bonif: 3500, sin_costo: false }],
    top_productos: [{ nombre: 'Coca 2L', unidades: 200, venta: 40000, margen: 16000 }],
    top_clientes: [{ cliente: 'Kiosco Luna', pedidos: 12, venta: 25000 }],
    cobranza: { formas: [{ forma_pago: 'efectivo', monto: 80000 }], cobrado: 80000, pendiente: 20000 },
    serie_diaria: [['2026-08-01', 3000], ['2026-08-02', 4500]],
    flags: { ingreso_sin_costo: 0, pct_sin_costo: 0 },
    mermas_motivo: [{ motivo: 'rotura', unidades: 10, costo: 900, clasificacion: 'perdida' }],
    bonif_promos: [
      { promocion: '2x1 Coca', producto: 'Coca 2L', unidades: 20, es_fraccion: false, costo: 2000, valor_venta: 4000 },
      { promocion: '2x1 Coca', producto: 'Coca 1L', unidades: 10, es_fraccion: true, costo: 500, valor_venta: 1000 },
    ],
    alertas: [{ severidad: 'warning', codigo: 'cobranza_vencida', titulo: 'Deuda vencida', detalle: '3 clientes', valor: 15000, seccion: 'sec-cobranza' }],
    ...over,
  } as ReporteGerencial
}

describe('hojaMetadatos', () => {
  it('dice sucursal, rango y criterio: sin eso el archivo no se puede interpretar', () => {
    // Con el export fraccionado quedan varios archivos sueltos en una carpeta.
    const filas = hojaMetadatos(reporte()).data
    const info = Object.fromEntries(filas.map(f => [f.Campo, f.Valor]))

    expect(info['Sucursal']).toBe('Tucumán')
    expect(info['Desde']).toBe('2026-08-01')
    expect(info['Hasta']).toBe('2026-08-31')
    expect(info['Criterio de venta']).toContain('entregad')
  })

  it('distingue la red consolidada de una sucursal', () => {
    const r = reporte()
    r.meta.sucursal_id = null
    r.meta.sucursal_nombre = 'Red'
    const info = Object.fromEntries(hojaMetadatos(r).data.map(f => [f.Campo, f.Valor]))
    expect(info['Sucursal']).toBe('Red (consolidado)')
  })

  it('el criterio cambia con el toggle Entregadas/Todos', () => {
    const r = reporte()
    r.meta.incluye_no_entregados = true
    const info = Object.fromEntries(hojaMetadatos(r).data.map(f => [f.Campo, f.Valor]))
    expect(info['Criterio de venta']).toContain('todos')
  })
})

describe('hojasResumen — los KPIs van transpuestos', () => {
  it('una fila por indicador, no una fila de 30 columnas', () => {
    const filas = hojasResumen(reporte())[1].data
    expect(filas.length).toBeGreaterThan(5)
    expect(Object.keys(filas[0])).toEqual(['Indicador', 'Valor'])
  })

  it('usa los MISMOS fallbacks que la pantalla para los KPIs opcionales', () => {
    // `margen_real` y `venta_real` no vienen en respuestas cacheadas viejas.
    const sinOpcionales = reporte()
    delete (sinOpcionales.kpis as Record<string, unknown>).margen_real
    delete (sinOpcionales.kpis as Record<string, unknown>).venta_real

    const info = Object.fromEntries(
      hojasResumen(sinOpcionales)[1].data.map(f => [f.Indicador, f.Valor]),
    )
    expect(info['Margen real']).toBe(40000)  // cae a margen_comercial
    expect(info['Venta real']).toBe(100000)  // cae a venta
  })

  it('nunca escribe undefined en una celda', () => {
    const pelado = reporte()
    pelado.kpis = { venta: 1, pedidos: 1 } as ReporteGerencial['kpis']
    const filas = hojasResumen(pelado)[1].data
    expect(filas.every(f => f.Valor !== undefined && f.Valor !== null)).toBe(true)
  })

  it('con comparativo agrega la hoja del período anterior', () => {
    const r = reporte({
      comparativo: { ...reporte().kpis, desde: '2026-07-01', hasta: '2026-07-31' } as ReporteGerencial['comparativo'],
    })
    expect(hojasResumen(r).map(h => h.name)).toContain('Período anterior')
  })

  it('sin comparativo no inventa una hoja vacía', () => {
    const r = reporte({ comparativo: null })
    expect(hojasResumen(r).map(h => h.name)).not.toContain('Período anterior')
  })
})

describe('hojasEvolucion — la serie diaria viene en TUPLAS', () => {
  it('mapea las tuplas a objetos con encabezados de verdad', () => {
    // Pasarle `[['2026-08-01', 3000]]` a createMultiSheetExcel produce columnas
    // llamadas '0' y '1', porque los headers salen de Object.keys(data[0]).
    const serie = hojasEvolucion(reporte()).find(h => h.name === 'Serie diaria')!
    expect(Object.keys(serie.data[0])).toEqual(['Fecha', 'Venta'])
    expect(serie.data[0]).toEqual({ Fecha: '2026-08-01', Venta: 3000 })
  })

  it('la evolución mensual lleva las columnas de la tabla', () => {
    const mensual = hojasEvolucion(reporte())[0]
    expect(mensual.data[0]).toMatchObject({
      Mes: '2026-08', Pedidos: 50, Venta: 100000, CMV: 60000, Mermas: 1000, Compras: 70000,
    })
  })

  it('sin serie diaria no rompe', () => {
    const r = reporte({ serie_diaria: [] })
    expect(() => hojasEvolucion(r)).not.toThrow()
  })
})

describe('las tablas simples', () => {
  it('vendedores lleva el rol legible, no el crudo', () => {
    expect(hojasVendedores(reporte())[0].data[0]).toMatchObject({
      Vendedor: 'Christian', Pedidos: 30, Venta: 60000,
    })
  })

  it('categorías marca las que no tienen costo cargado', () => {
    const fila = hojasCategorias(reporte())[0].data[0]
    expect(fila).toMatchObject({ Categoría: 'Bebidas', Venta: 70000 })
    expect(fila['Sin costo']).toBe('No')
  })

  it('top productos y top clientes', () => {
    expect(hojasTopProductos(reporte())[0].data[0]).toMatchObject({ Producto: 'Coca 2L', Unidades: 200 })
    expect(hojasTopClientes(reporte())[0].data[0]).toMatchObject({ Cliente: 'Kiosco Luna', Pedidos: 12 })
  })

  it('cobranza lleva las formas y cierra con cobrado y pendiente', () => {
    const filas = hojasCobranza(reporte())[0].data
    expect(filas[0]).toMatchObject({ 'Forma de pago': 'efectivo', Monto: 80000 })
    const totales = filas.map(f => f['Forma de pago'])
    expect(totales).toContain('COBRADO')
    expect(totales).toContain('PENDIENTE')
  })

  it('mermas por motivo lleva la clasificación', () => {
    expect(hojasMermas(reporte())[0].data[0]).toMatchObject({
      Motivo: 'rotura', Unidades: 10, Costo: 900, Clasificación: 'perdida',
    })
  })
})

describe('hojasCompras', () => {
  it('lleva el desembolso mes a mes, que es lo que muestra la card', () => {
    const hojas = hojasCompras(reporte())
    expect(hojas).toHaveLength(1)
    expect(hojas[0].name).toBe('Compras')
    expect(hojas[0].data[0]).toEqual({ Mes: '2026-08', Compras: 70000 })
  })

  it('sin serie mensual devuelve [] en vez de una hoja en blanco', () => {
    expect(hojasCompras(reporte({ mensual: [] }))).toEqual([])
  })
})

describe('hojasBonificaciones — agrupadas por promoción, como en pantalla', () => {
  it('una hoja de subtotales por promoción y otra con el detalle', () => {
    const hojas = hojasBonificaciones(reporte())
    expect(hojas.map(h => h.name)).toEqual(['Bonif por promo', 'Bonif detalle'])
  })

  it('el subtotal suma los productos de esa promoción', () => {
    expect(hojasBonificaciones(reporte())[0].data[0]).toMatchObject({
      Promoción: '2x1 Coca', Costo: 2500, 'Valor de venta': 5000, Productos: 2,
    })
  })

  it('el detalle distingue botellas de fardos', () => {
    const detalle = hojasBonificaciones(reporte())[1].data
    expect(detalle.find(f => f.Producto === 'Coca 1L')).toMatchObject({ Unidad: 'botellas' })
    expect(detalle.find(f => f.Producto === 'Coca 2L')).toMatchObject({ Unidad: 'fardos' })
  })

  it('sin bonificaciones devuelve lista vacía, no una hoja en blanco', () => {
    expect(hojasBonificaciones(reporte({ bonif_promos: [] }))).toEqual([])
  })

  it('con bonif_promos ausente tampoco rompe', () => {
    const r = reporte()
    delete (r as Record<string, unknown>).bonif_promos
    expect(hojasBonificaciones(r)).toEqual([])
  })
})

describe('hojasAlertas', () => {
  it('exporta las alertas con severidad y valor', () => {
    expect(hojasAlertas(reporte())[0].data[0]).toMatchObject({
      Severidad: 'warning', Título: 'Deuda vencida', Valor: 15000,
    })
  })

  it('sin alertas no genera hoja', () => {
    expect(hojasAlertas(reporte({ alertas: [] }))).toEqual([])
  })
})

describe('hojasTodo', () => {
  it('junta todos los bloques en un solo archivo, con los metadatos primero', () => {
    const hojas = hojasTodo(reporte())
    expect(hojas[0].name).toBe('Info')
    expect(hojas.length).toBeGreaterThan(8)
  })

  it('no repite la hoja de metadatos por cada bloque', () => {
    const nombres = hojasTodo(reporte()).map(h => h.name)
    expect(nombres.filter(n => n === 'Info')).toHaveLength(1)
  })

  it('los nombres de hoja son únicos: Excel no admite dos iguales', () => {
    const nombres = hojasTodo(reporte()).map(h => h.name)
    expect(new Set(nombres).size).toBe(nombres.length)
  })

  it('ningún nombre de hoja pasa los 31 caracteres que permite Excel', () => {
    for (const h of hojasTodo(reporte())) {
      expect(h.name.length).toBeLessThanOrEqual(31)
    }
  })
})

describe('nombreArchivo', () => {
  it('lleva sucursal y rango, sin espacios', () => {
    expect(nombreArchivo(reporte(), 'resumen')).toBe('gerencial-resumen-Tucumán-2026-08-01_2026-08-31')
  })

  it('la red consolidada se llama Red, sin arrastrar el paréntesis al filename', () => {
    const r = reporte()
    r.meta.sucursal_id = null
    r.meta.sucursal_nombre = 'Red (consolidado)'
    expect(nombreArchivo(r, 'todo')).toBe('gerencial-todo-Red-2026-08-01_2026-08-31')
  })
})

describe('BLOQUES_GERENCIAL', () => {
  it('cada bloque sabe armar sus hojas', () => {
    for (const b of BLOQUES_GERENCIAL) {
      expect(typeof b.hojas).toBe('function')
      expect(b.id.length).toBeGreaterThan(0)
      expect(b.label.length).toBeGreaterThan(0)
    }
  })

  it('los ids son únicos', () => {
    const ids = BLOQUES_GERENCIAL.map(b => b.id)
    expect(new Set(ids).size).toBe(ids.length)
  })
})
