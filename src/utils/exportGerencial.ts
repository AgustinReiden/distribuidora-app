/**
 * Armado de las hojas de Excel del dashboard gerencial.
 *
 * FRACCIONADO A PROPÓSITO
 * -----------------------
 * Cada bloque se baja por separado —un botón por sección— en vez de un único
 * archivo monolítico: el dashboard tiene diez bloques y casi nunca se necesitan
 * todos juntos. `hojasTodo` existe igual para el caso en que sí.
 *
 * POR ESO LA HOJA DE METADATOS ES OBLIGATORIA EN CADA ARCHIVO
 * ----------------------------------------------------------
 * El mismo reporte puede ser de UNA sucursal o de la red consolidada, con un
 * rango custom y con el toggle "Entregadas/Todos" en cualquiera de sus dos
 * posiciones. Un Excel que no dice cuál de todas esas cosas es, es un archivo
 * que nadie puede interpretar tres semanas después — y con el export
 * fraccionado quedan varios archivos sueltos en la misma carpeta, así que pesa
 * el doble. El RPC ya devuelve `meta` con todo eso.
 *
 * ESTO SE ROMPE SI CAMBIA EL PAYLOAD DEL RPC
 * ------------------------------------------
 * Las claves de cada fila salen directo de los campos de `reporte_gerencial`.
 * Una tarea que le cambie la forma al RPC —renombrar un campo, sacar uno— deja
 * columnas vacías acá y NO lo detecta ni `tsc` (varios campos son opcionales
 * por compat) ni el build. Si tocás el RPC, mirá este archivo.
 *
 * SÓLO DATOS, NO IMÁGENES. Los gráficos son chart.js: meterlos en el Excel
 * obliga a pasar por `canvas.toDataURL`, que es bastante más caro. Se exportan
 * los datos con los que están hechos.
 */
import type { SheetConfig } from './excel'
import type {
  ReporteGerencial,
  ReporteKpis,
  BonifPromo,
} from '../hooks/queries/useReporteGerencialQuery'

type Fila = Record<string, unknown>

const n = (v: unknown): number => {
  const x = Number(v)
  return Number.isFinite(x) ? x : 0
}

/** Excel no admite nombres de hoja de más de 31 caracteres. */
const hoja = (name: string, data: Fila[], columnWidths?: number[]): SheetConfig =>
  ({ name: name.slice(0, 31), data, columnWidths } as SheetConfig)

// ---------------------------------------------------------------------------
// Metadatos
// ---------------------------------------------------------------------------

export function hojaMetadatos(r: ReporteGerencial): SheetConfig {
  const esRed = r.meta.sucursal_id === null
  return hoja('Info', [
    { Campo: 'Sucursal', Valor: esRed ? 'Red (consolidado)' : r.meta.sucursal_nombre },
    { Campo: 'Desde', Valor: r.meta.desde },
    { Campo: 'Hasta', Valor: r.meta.hasta },
    {
      Campo: 'Criterio de venta',
      Valor: r.meta.incluye_no_entregados
        ? 'Incluye todos los pedidos no cancelados (entregados y no entregados)'
        : 'Sólo pedidos entregados',
    },
    { Campo: 'Generado', Valor: r.meta.generado_at },
    {
      Campo: 'Nota',
      Valor: 'Los gráficos del dashboard salen de estas mismas tablas. '
           + 'Este archivo es un bloque del reporte: puede haber otros del mismo período.',
    },
  ], [22, 62])
}

// ---------------------------------------------------------------------------
// Resumen (KPIs)
// ---------------------------------------------------------------------------

/**
 * Los KPIs son un objeto de ~30 escalares: van TRANSPUESTOS a filas
 * indicador/valor. Como una sola fila de 30 columnas el archivo es ilegible.
 *
 * Los `??` replican exactamente los que usa la pantalla: varios campos son
 * opcionales por compatibilidad con respuestas cacheadas de versiones viejas
 * del RPC, y sin fallback se escribiría `undefined` en la celda.
 */
function filasKpis(k: ReporteKpis): Fila[] {
  const ventaReal = k.venta_real ?? k.venta
  const margenReal = k.margen_real ?? k.margen_comercial
  return [
    { Indicador: 'Venta', Valor: n(k.venta) },
    { Indicador: 'Venta real', Valor: n(ventaReal) },
    { Indicador: 'Venta neta (sin IVA)', Valor: n(k.venta_neta ?? 0) },
    { Indicador: 'IVA débito', Valor: n(k.iva_debito ?? 0) },
    { Indicador: 'Pedidos', Valor: n(k.pedidos) },
    { Indicador: 'Clientes', Valor: n(k.clientes) },
    { Indicador: 'Clientes nuevos', Valor: n(k.clientes_nuevos) },
    { Indicador: 'Ticket promedio', Valor: n(k.ticket) },
    { Indicador: 'Unidades', Valor: n(k.unidades) },
    { Indicador: 'Unidades bonificadas', Valor: n(k.unidades_bonif) },
    { Indicador: 'CMV', Valor: n(k.cmv) },
    { Indicador: 'Margen real', Valor: n(margenReal) },
    { Indicador: 'Margen comercial', Valor: n(k.margen_comercial) },
    { Indicador: 'Margen neto', Valor: n(k.margen_neto) },
    { Indicador: 'Bonificaciones', Valor: n(k.bonif) },
    { Indicador: 'Mermas (total)', Valor: n(k.mermas) },
    { Indicador: 'Mermas — pérdida', Valor: n(k.mermas_perdida ?? 0) },
    { Indicador: 'Mermas — ajustes', Valor: n(k.mermas_ajuste ?? 0) },
    { Indicador: 'Mermas — muestras', Valor: n(k.mermas_muestra ?? 0) },
    { Indicador: 'Compras', Valor: n(k.compras) },
    { Indicador: 'Base de comisión', Valor: n(k.base_comision) },
    { Indicador: 'Ingreso sin costo cargado', Valor: n(k.ingreso_sin_costo) },
    { Indicador: 'Venta FC', Valor: n(k.fc_venta ?? 0) },
    { Indicador: 'Pedidos FC', Valor: n(k.fc_pedidos ?? 0) },
    { Indicador: 'Venta ZZ', Valor: n(k.zz_venta ?? 0) },
    { Indicador: 'Pedidos ZZ', Valor: n(k.zz_pedidos ?? 0) },
  ]
}

export function hojasResumen(r: ReporteGerencial): SheetConfig[] {
  const hojas = [
    hojaMetadatos(r),
    hoja('Resumen', filasKpis(r.kpis), [30, 18]),
  ]
  if (r.comparativo) {
    hojas.push(hoja('Período anterior', [
      { Indicador: 'Desde', Valor: r.comparativo.desde },
      { Indicador: 'Hasta', Valor: r.comparativo.hasta },
      ...filasKpis(r.comparativo),
    ], [30, 18]))
  }
  return hojas
}

// ---------------------------------------------------------------------------
// Evolución mensual + serie diaria
// ---------------------------------------------------------------------------

export function hojasEvolucion(r: ReporteGerencial): SheetConfig[] {
  const mensual = (r.mensual ?? []).map(m => ({
    Mes: m.mes,
    Pedidos: n(m.pedidos),
    Venta: n(m.venta),
    Clientes: n(m.clientes),
    'Ticket promedio': n(m.ticket),
    CMV: n(m.cmv),
    Bonificaciones: n(m.bonif),
    Mermas: n(m.mermas),
    Compras: n(m.compras),
  }))

  // `serie_diaria` viene como TUPLAS [fecha, venta][], no como objetos. Los
  // headers del Excel salen de Object.keys(data[0]): pasarle las tuplas crudas
  // produce dos columnas llamadas '0' y '1'.
  const serie = (r.serie_diaria ?? []).map(([fecha, venta]) => ({
    Fecha: fecha,
    Venta: n(venta),
  }))

  return [
    hoja('Evolución mensual', mensual, [10, 10, 16, 10, 16, 16, 16, 14, 16]),
    hoja('Serie diaria', serie, [13, 16]),
  ]
}

// ---------------------------------------------------------------------------
// Tablas simples
// ---------------------------------------------------------------------------

const ROLES: Record<string, string> = {
  preventista: 'Preventista',
  encargado: 'Encargado',
  admin: 'Admin',
}

export function hojasVendedores(r: ReporteGerencial): SheetConfig[] {
  return [hoja('Vendedores', (r.vendedores ?? []).map(v => ({
    Vendedor: v.nombre,
    Rol: ROLES[v.rol] ?? v.rol,
    Pedidos: n(v.pedidos),
    Venta: n(v.venta),
    'Margen comercial': n(v.margen_comercial),
    Bonificaciones: n(v.bonif),
    'Base para comisión': n(v.base_nc),
  })), [26, 14, 10, 16, 18, 16, 18])]
}

export function hojasCategorias(r: ReporteGerencial): SheetConfig[] {
  return [hoja('Categorías', (r.categorias ?? []).map(c => ({
    Categoría: c.categoria,
    Venta: n(c.venta),
    'Margen comercial': n(c.margen_comercial),
    Bonificaciones: n(c.bonif),
    // Se exporta como texto y no como booleano: en Excel un FALSE en una
    // columna de datos se lee peor que un "No".
    'Sin costo': c.sin_costo ? 'Sí' : 'No',
  })), [28, 16, 18, 16, 11])]
}

export function hojasTopProductos(r: ReporteGerencial): SheetConfig[] {
  return [hoja('Top productos', (r.top_productos ?? []).map((p, i) => ({
    '#': i + 1,
    Producto: p.nombre,
    Unidades: n(p.unidades),
    Venta: n(p.venta),
    Margen: n(p.margen),
  })), [5, 40, 12, 16, 16])]
}

export function hojasTopClientes(r: ReporteGerencial): SheetConfig[] {
  return [hoja('Top clientes', (r.top_clientes ?? []).map((c, i) => ({
    '#': i + 1,
    Cliente: c.cliente,
    Pedidos: n(c.pedidos),
    Venta: n(c.venta),
  })), [5, 38, 10, 16])]
}

export function hojasCobranza(r: ReporteGerencial): SheetConfig[] {
  const formas = (r.cobranza?.formas ?? []).map(f => ({
    'Forma de pago': f.forma_pago,
    Monto: n(f.monto),
  }))
  // Los totales van en el mismo archivo: si no, hay que sumarlos a mano para
  // confirmar que es el mismo reporte que la pantalla.
  formas.push(
    { 'Forma de pago': 'COBRADO', Monto: n(r.cobranza?.cobrado) },
    { 'Forma de pago': 'PENDIENTE', Monto: n(r.cobranza?.pendiente) },
  )
  return [hoja('Cobranza', formas, [24, 18])]
}

export function hojasMermas(r: ReporteGerencial): SheetConfig[] {
  const filas = (r.mermas_motivo ?? []).map(m => ({
    Motivo: m.motivo,
    Unidades: n(m.unidades),
    Costo: n(m.costo),
    Clasificación: m.clasificacion,
  }))
  if (filas.length === 0) return []
  return [hoja('Mermas por motivo', filas, [22, 12, 16, 16])]
}

/**
 * Compras del período, mes a mes. Es el desembolso, NO el costo de lo vendido
 * (eso es el CMV, que va en Resumen y en Evolución).
 */
export function hojasCompras(r: ReporteGerencial): SheetConfig[] {
  const filas = (r.mensual ?? []).map(m => ({
    Mes: m.mes,
    Compras: n(m.compras),
  }))
  if (filas.length === 0) return []
  return [hoja('Compras', filas, [12, 18])]
}

// ---------------------------------------------------------------------------
// Bonificaciones
// ---------------------------------------------------------------------------

interface GrupoBonif {
  promocion: string
  costo: number
  valor_venta: number
  items: BonifPromo[]
}

/** Mismo agrupado que muestra la pantalla: subtotal por promo + detalle. */
function agruparBonif(promos: readonly BonifPromo[]): GrupoBonif[] {
  const grupos = new Map<string, GrupoBonif>()
  for (const b of promos) {
    const g = grupos.get(b.promocion) ?? { promocion: b.promocion, costo: 0, valor_venta: 0, items: [] }
    g.costo += n(b.costo)
    g.valor_venta += n(b.valor_venta)
    g.items.push(b)
    grupos.set(b.promocion, g)
  }
  return [...grupos.values()]
    .map(g => ({ ...g, items: [...g.items].sort((a, b) => n(b.valor_venta) - n(a.valor_venta)) }))
    .sort((a, b) => b.valor_venta - a.valor_venta)
}

export function hojasBonificaciones(r: ReporteGerencial): SheetConfig[] {
  const promos = r.bonif_promos ?? []
  if (promos.length === 0) return []

  const grupos = agruparBonif(promos)

  const porPromo = grupos.map(g => ({
    Promoción: g.promocion,
    Productos: g.items.length,
    Costo: g.costo,
    'Valor de venta': g.valor_venta,
  }))

  const detalle = grupos.flatMap(g => g.items.map(i => ({
    Promoción: g.promocion,
    Producto: i.producto,
    Unidades: n(i.unidades),
    // La promo fraccionada regala BOTELLAS, no fardos: sin esta columna los
    // números de dos filas parecen comparables y no lo son.
    Unidad: i.es_fraccion ? 'botellas' : 'fardos',
    Costo: n(i.costo),
    'Valor de venta': n(i.valor_venta),
  })))

  return [
    hoja('Bonif por promo', porPromo, [34, 11, 16, 18]),
    hoja('Bonif detalle', detalle, [30, 32, 12, 12, 16, 18]),
  ]
}

// ---------------------------------------------------------------------------
// Alertas
// ---------------------------------------------------------------------------

export function hojasAlertas(r: ReporteGerencial): SheetConfig[] {
  const filas = (r.alertas ?? []).map(a => ({
    Severidad: a.severidad,
    Código: a.codigo,
    Título: a.titulo,
    Detalle: a.detalle,
    Valor: n(a.valor),
    Sección: a.seccion,
  }))
  if (filas.length === 0) return []
  return [hoja('Alertas', filas, [12, 24, 30, 50, 16, 18])]
}

// ---------------------------------------------------------------------------
// Los bloques que ofrece la pantalla
// ---------------------------------------------------------------------------

export interface BloqueGerencial {
  /** Va en el nombre del archivo. */
  id: string
  label: string
  hojas: (r: ReporteGerencial) => SheetConfig[]
}

/**
 * Un bloque por sección del dashboard. `hojas` NO incluye los metadatos: los
 * agrega `hojasDeBloque`, para que ningún bloque se olvide de ponerlos.
 */
export const BLOQUES_GERENCIAL: BloqueGerencial[] = [
  { id: 'resumen', label: 'Resumen y KPIs', hojas: r => hojasResumen(r).slice(1) },
  { id: 'evolucion', label: 'Evolución', hojas: hojasEvolucion },
  { id: 'vendedores', label: 'Vendedores', hojas: hojasVendedores },
  { id: 'categorias', label: 'Categorías', hojas: hojasCategorias },
  { id: 'top-productos', label: 'Top productos', hojas: hojasTopProductos },
  { id: 'top-clientes', label: 'Top clientes', hojas: hojasTopClientes },
  { id: 'cobranza', label: 'Cobranza', hojas: hojasCobranza },
  { id: 'mermas', label: 'Mermas', hojas: hojasMermas },
  { id: 'compras', label: 'Compras', hojas: hojasCompras },
  { id: 'bonificaciones', label: 'Bonificaciones', hojas: hojasBonificaciones },
  { id: 'alertas', label: 'Alertas', hojas: hojasAlertas },
]

/** Las hojas de un bloque, siempre con los metadatos adelante. */
export function hojasDeBloque(r: ReporteGerencial, bloque: BloqueGerencial): SheetConfig[] {
  return [hojaMetadatos(r), ...bloque.hojas(r)]
}

/** Todo junto en un archivo, con una sola hoja de metadatos. */
export function hojasTodo(r: ReporteGerencial): SheetConfig[] {
  return [hojaMetadatos(r), ...BLOQUES_GERENCIAL.flatMap(b => b.hojas(r))]
}

/**
 * `gerencial-<bloque>-<sucursal>-<desde>_<hasta>`, sin espacios y sin
 * extensión (la agrega el helper de Excel).
 */
export function nombreArchivo(r: ReporteGerencial, bloqueId: string): string {
  const sucursal = r.meta.sucursal_id === null ? 'Red' : r.meta.sucursal_nombre
  return `gerencial-${bloqueId}-${sucursal}-${r.meta.desde}_${r.meta.hasta}`.replace(/\s+/g, '_')
}
