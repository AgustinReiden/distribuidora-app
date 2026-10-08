/**
 * Lo que ve depósito en /pedidos (#782): las hojas de ruta armadas de una fecha
 * y, aparte, los pedidos que todavía no están en ninguna. Viene de la RPC
 * `hojas_de_ruta_deposito` (mig 306), que arma a mano sólo columnas sin plata.
 *
 * La normalización copia campo por campo, nunca `...raw`: si un día la RPC
 * devolviera un monto, la pantalla igual no lo recibe.
 */
import type { ItemParaCarga, PedidoParaCarga, ProductoCatalogoManifiesto } from './manifiestoCarga'

/** Claves que no pueden aparecer en lo que recibe depósito (lo verifica el test). */
export const CLAVES_DE_PLATA = [
  'total', 'total_neto', 'total_iva', 'total_real', 'monto_pagado', 'estado_pago', 'forma_pago',
  'precio_unitario', 'subtotal', 'neto_unitario', 'iva_unitario', 'ingreso_real_unitario',
  'costo_unitario_al_crear', 'precio', 'total_facturado', 'total_cobrado', 'saldo_cuenta',
  'limite_credito', 'deuda_previa', 'pagos',
] as const

export interface ClienteDeposito {
  id: string
  nombre_fantasia: string | null
  razon_social: string | null
  direccion: string | null
  aclaracion_direccion: string | null
  telefono: string | null
  zona: string | null
  horarios_atencion: string | null
}

export interface ItemDeposito extends ItemParaCarga {
  id: string
  producto_id: string | null
  cantidad: number
  es_bonificacion: boolean
  descripcion_regalo: string | null
  unidades_por_bloque_al_crear: number | null
  producto: {
    id: string | null
    nombre: string | null
    codigo: string | null
    categoria: string | null
    subcategoria_id: string | null
    unidades_de_venta_por_fardo: number | null
    etiqueta_bulto: string | null
  } | null
  promocion: { unidades_por_bloque: number | null; regalo_mueve_stock: boolean | null } | null
}

export interface CambioDeposito {
  producto_devuelto_nombre: string | null
  cantidad_devuelta: number | null
  producto_entregado_id: string | null
  producto_entregado_nombre: string | null
  /** Rubro del producto que se entrega, para agruparlo en el manifiesto. */
  producto_entregado_categoria: string | null
  producto_entregado_subcategoria_id: string | null
  cantidad_entregada: number | null
  observaciones: string | null
  motivo: string | null
}

export interface PedidoDeposito extends PedidoParaCarga {
  id: string
  estado: string
  canal: string | null
  fecha: string | null
  fecha_entrega_programada: string | null
  created_at: string | null
  notas: string | null
  orden_entrega: number | null
  /** De la parada (recorrido_pedidos): 'pendiente' | 'entregado' | 'no_entregado'. */
  estado_entrega: string | null
  cliente: ClienteDeposito | null
  items: ItemDeposito[]
  cambio: CambioDeposito | null
}

export interface RutaDeposito {
  recorridoId: string
  estado: string | null
  transportista: { id: string | null; nombre: string }
  paradas: PedidoDeposito[]
}

export interface HojasDeRutaDeposito {
  /** Fecha que resolvió el servidor (la pedida, o la próxima ruta armada). */
  fecha: string | null
  rutas: RutaDeposito[]
  sinRuta: PedidoDeposito[]
  /** subcategoria_id → nombre, para agrupar la carga por rubro -> subrubro. */
  subrubros: Record<string, string>
}

type Crudo = Record<string, unknown>

const obj = (v: unknown): Crudo | null => (v && typeof v === 'object' && !Array.isArray(v) ? v as Crudo : null)
const lista = (v: unknown): unknown[] => (Array.isArray(v) ? v : [])
const texto = (v: unknown): string | null => (v == null || v === '' ? null : String(v))
const numero = (v: unknown): number | null => {
  if (v == null || v === '') return null
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

function normalizarItem(raw: unknown): ItemDeposito {
  const i = obj(raw) ?? {}
  const p = obj(i.producto)
  const pm = obj(i.promocion)
  return {
    id: String(i.id ?? ''),
    producto_id: texto(i.producto_id),
    cantidad: numero(i.cantidad) ?? 0,
    es_bonificacion: Boolean(i.es_bonificacion),
    descripcion_regalo: texto(i.descripcion_regalo),
    unidades_por_bloque_al_crear: numero(i.unidades_por_bloque_al_crear),
    producto: p ? {
      id: texto(p.id),
      nombre: texto(p.nombre),
      codigo: texto(p.codigo),
      categoria: texto(p.categoria),
      subcategoria_id: texto(p.subcategoria_id),
      unidades_de_venta_por_fardo: numero(p.unidades_de_venta_por_fardo),
      etiqueta_bulto: texto(p.etiqueta_bulto),
    } : null,
    promocion: pm ? {
      unidades_por_bloque: numero(pm.unidades_por_bloque),
      regalo_mueve_stock: pm.regalo_mueve_stock == null ? null : Boolean(pm.regalo_mueve_stock),
    } : null,
  }
}

function normalizarPedido(raw: unknown): PedidoDeposito {
  const p = obj(raw) ?? {}
  const c = obj(p.cliente)
  const cb = obj(p.cambio)
  return {
    id: String(p.id ?? ''),
    estado: String(p.estado ?? ''),
    canal: texto(p.canal),
    fecha: texto(p.fecha),
    fecha_entrega_programada: texto(p.fecha_entrega_programada),
    created_at: texto(p.created_at),
    notas: texto(p.notas),
    orden_entrega: numero(p.orden_entrega),
    estado_entrega: texto(p.estado_entrega),
    cliente: c ? {
      id: String(c.id ?? ''),
      nombre_fantasia: texto(c.nombre_fantasia),
      razon_social: texto(c.razon_social),
      direccion: texto(c.direccion),
      aclaracion_direccion: texto(c.aclaracion_direccion),
      telefono: texto(c.telefono),
      zona: texto(c.zona),
      horarios_atencion: texto(c.horarios_atencion),
    } : null,
    items: lista(p.items).map(normalizarItem),
    cambio: cb ? {
      producto_devuelto_nombre: texto(cb.producto_devuelto_nombre),
      cantidad_devuelta: numero(cb.cantidad_devuelta),
      producto_entregado_id: texto(cb.producto_entregado_id),
      producto_entregado_nombre: texto(cb.producto_entregado_nombre),
      producto_entregado_categoria: texto(cb.producto_entregado_categoria),
      producto_entregado_subcategoria_id: texto(cb.producto_entregado_subcategoria_id),
      cantidad_entregada: numero(cb.cantidad_entregada),
      observaciones: texto(cb.observaciones),
      motivo: texto(cb.motivo),
    } : null,
  }
}

export function normalizarHojasDeRuta(raw: unknown): HojasDeRutaDeposito {
  const r = obj(raw)
  if (!r) return { fecha: null, rutas: [], sinRuta: [], subrubros: {} }
  const subrubros: Record<string, string> = {}
  Object.entries(obj(r.subrubros) ?? {}).forEach(([id, nombre]) => {
    if (typeof nombre === 'string') subrubros[id] = nombre
  })
  return {
    fecha: texto(r.fecha),
    rutas: lista(r.rutas).map((x) => {
      const ruta = obj(x) ?? {}
      const t = obj(ruta.transportista)
      return {
        recorridoId: String(ruta.recorrido_id ?? ''),
        estado: texto(ruta.estado),
        transportista: { id: texto(t?.id), nombre: texto(t?.nombre) ?? 'Sin chofer' },
        paradas: lista(ruta.paradas).map(normalizarPedido),
      }
    }),
    sinRuta: lista(r.sin_ruta).map(normalizarPedido),
    subrubros,
  }
}

/**
 * El catálogo que `consolidarCarga` usa para ubicar en su rubro lo que no trae
 * producto embebido: el producto que se ENTREGA en una parada de cambio. El
 * admin lo saca de la tabla de productos; depósito, de la propia RPC.
 */
export function catalogoDeCambios(datos: HojasDeRutaDeposito): ProductoCatalogoManifiesto[] {
  const vistos = new Map<string, ProductoCatalogoManifiesto>()
  for (const p of [...datos.rutas.flatMap(r => r.paradas), ...datos.sinRuta]) {
    const c = p.cambio
    if (c?.producto_entregado_id && !vistos.has(c.producto_entregado_id)) {
      vistos.set(c.producto_entregado_id, {
        id: c.producto_entregado_id,
        categoria: c.producto_entregado_categoria,
        subcategoria_id: c.producto_entregado_subcategoria_id,
      })
    }
  }
  return [...vistos.values()]
}

/** Lo cancelado o anulado se sigue viendo como parada, pero no sube al camión. */
export function pedidosACargar(ruta: RutaDeposito): PedidoDeposito[] {
  return ruta.paradas.filter((p) => p.estado !== 'cancelado' && p.estado !== 'anulado')
}

/** YYYY-MM-DD ± n días, en UTC para que la zona horaria no corra la fecha. */
export function sumarDias(ymd: string, dias: number): string {
  const [a, m, d] = ymd.split('-').map(Number)
  const fecha = new Date(Date.UTC(a, m - 1, d + dias))
  return fecha.toISOString().slice(0, 10)
}
