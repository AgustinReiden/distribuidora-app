/**
 * TanStack Query hook para el reporte de mermas (mig 226).
 *
 * RPC `reporte_mermas(p_desde, p_hasta, p_sucursal_id, p_motivo, p_limite_detalle,
 * p_offset, p_busqueda)`.
 *
 * Dos cosas que lo distinguen del camino viejo (`useMermasQuery`, que bajaba las
 * filas crudas por PostgREST):
 *
 *  1. `p_sucursal_id NULL` consolida la RED. Por PostgREST no se podía: la
 *     policy `mt_mermas_stock_select` ata el SELECT a `current_sucursal_id()`.
 *  2. `totales` y `por_motivo` se calculan en la base sobre el período COMPLETO;
 *     sólo `detalle` está acotado. Truncar acorta la lista, nunca mueve un
 *     total — que era justo el defecto del modal.
 *  3. El detalle se pagina y se busca EN EL SERVIDOR (#1146): la pantalla pide
 *     una página de `MERMAS_PAGE_SIZE`, y la búsqueda (producto, código u
 *     observaciones) también la aplica la base, sólo a la lista. Antes el RPC
 *     devolvía como mucho 500 filas y el resto sólo salía por Excel.
 *
 * `totales.costo` cierra EXACTO contra `reporte_gerencial.kpis.mermas`, y desde
 * la mig 238 por construcción: los dos consumen `mermas_valorizadas()`, la única
 * implementación del criterio. Antes eran dos copias verbatim del mismo SQL.
 */
import { useQuery, type QueryKey } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import type { ClasificacionMerma, OrigenCostoMerma, ProcedenciaMerma } from '../../utils/mermasMotivo'

/** Tope del RPC: el servidor clampea a este valor aunque se le pida más. Es el
 *  tamaño de página con que el Excel recorre el período completo. */
export const LIMITE_DETALLE_MERMAS = 2000

/** Filas por página del historial en pantalla. */
export const MERMAS_PAGE_SIZE = 20

export interface MermaMotivoReporte {
  motivo: string
  clasificacion: ClasificacionMerma
  registros: number
  unidades: number
  costo: number
  precio: number
  filas_costo_estimado: number
  filas_sin_costo: number
}

/** Corte por procedencia y motivo (mig 301, #847). Suma lo mismo que
 *  `por_motivo`: es otra forma de partir las mismas filas. */
export interface MermaProcedenciaReporte {
  procedencia: ProcedenciaMerma
  motivo: string
  clasificacion: ClasificacionMerma
  registros: number
  unidades: number
  costo: number
  precio: number
}

export interface MermaDetalle {
  /** bigint en la base: llega como number, se tipa string para no comparar por identidad. */
  id: string
  created_at: string
  /** Día argentino de carga: el que usa el corte del período (mig 238). */
  fecha_local: string
  cantidad: number
  motivo: string
  clasificacion: ClasificacionMerma
  costo_unitario: number | null
  costo_total: number | null
  precio_unitario: number | null
  precio_total: number | null
  origen_costo: OrigenCostoMerma
  /** Opcional: un RPC anterior a la mig 301 no la manda. */
  procedencia?: ProcedenciaMerma
  producto_id: string
  producto_nombre: string
  producto_codigo: string | null
  producto_categoria: string | null
  stock_anterior: number
  stock_nuevo: number
  usuario_id: string | null
  usuario_nombre: string | null
  sucursal_id: string
  sucursal_nombre: string | null
  observaciones: string | null
}

export interface TotalesMermasReporte {
  registros: number
  unidades: number
  costo: number
  precio: number
  costo_perdida: number
  costo_ajuste: number
  costo_muestra: number
  /** Los ajustes de promoción quedan FUERA de `costo`: se informan aparte. */
  registros_ajuste_promocion: number
  unidades_ajuste_promocion: number
  costo_ajuste_promocion: number
  filas_costo_estimado: number
  filas_sin_costo: number
}

export interface ReporteMermas {
  meta: {
    sucursal_id: number | null
    sucursal_nombre: string
    desde: string
    hasta: string
    generado_at: string
    filtro_motivo: string | null
    criterio: string
  }
  totales: TotalesMermasReporte
  por_motivo: MermaMotivoReporte[]
  /** Opcional: un RPC anterior a la mig 301 no lo manda. */
  por_procedencia?: MermaProcedenciaReporte[]
  /** La página pedida (`detalle_offset`, hasta `detalle_limite` filas). */
  detalle: MermaDetalle[]
  /** Filas del período y del motivo, promociones incluidas; no mira la búsqueda. */
  detalle_total: number
  /** Filas que pasan la búsqueda: la base de la paginación (#1146). */
  detalle_filtrado: number
  detalle_limite: number
  detalle_offset: number
  /** Hay más filas después de esta página (desde #1146; con offset 0 y sin
   *  búsqueda es lo mismo que antes: el período no entró entero). */
  detalle_truncado: boolean
}

export interface OpcionesReporteMermas {
  limite?: number
  offset?: number
  busqueda?: string
}

export const mermasReporteKeys = {
  all: ['reporte-mermas'] as const,
  range: (
    sucursalId: number | null,
    desde: string,
    hasta: string,
    motivo: string | null,
    busqueda: string,
    pagina: number,
  ) => ['reporte-mermas', sucursalId, desde, hasta, motivo, busqueda, pagina] as const,
}

export async function fetchReporteMermas(
  sucursalId: number | null,
  desde: string,
  hasta: string,
  motivo: string | null = null,
  opciones: OpcionesReporteMermas = {},
): Promise<ReporteMermas> {
  const busqueda = opciones.busqueda?.trim() || null
  const { data, error } = await supabase.rpc('reporte_mermas', {
    p_desde: desde,
    p_hasta: hasta,
    p_sucursal_id: sucursalId,
    p_motivo: motivo,
    ...(opciones.limite != null ? { p_limite_detalle: opciones.limite } : {}),
    ...(opciones.offset != null ? { p_offset: opciones.offset } : {}),
    ...(busqueda != null ? { p_busqueda: busqueda } : {}),
  })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar el reporte de mermas. Revisá la señal e intentá de nuevo.')
  return data as ReporteMermas
}

/**
 * El período completo para el Excel: recorre el detalle en páginas del tope del
 * servidor hasta juntar `detalle_total` filas. Sin búsqueda (el Excel baja el
 * período, como siempre). Deduplica por id: entre dos páginas puede entrar una
 * merma nueva y correr una fila a la página siguiente.
 */
export async function fetchReporteMermasCompleto(
  sucursalId: number | null,
  desde: string,
  hasta: string,
  motivo: string | null = null,
): Promise<ReporteMermas> {
  const primera = await fetchReporteMermas(sucursalId, desde, hasta, motivo, {
    limite: LIMITE_DETALLE_MERMAS,
    offset: 0,
  })
  const vistos = new Set<string>()
  const detalle: MermaDetalle[] = []
  const sumar = (filas: MermaDetalle[]) => {
    for (const f of filas) {
      const id = String(f.id)
      if (vistos.has(id)) continue
      vistos.add(id)
      detalle.push(f)
    }
  }
  sumar(primera.detalle)
  let offset = 0
  let ultima = primera.detalle.length
  while (ultima > 0 && detalle.length < primera.detalle_total) {
    offset += LIMITE_DETALLE_MERMAS
    const pagina = await fetchReporteMermas(sucursalId, desde, hasta, motivo, {
      limite: LIMITE_DETALLE_MERMAS,
      offset,
    })
    ultima = pagina.detalle.length
    sumar(pagina.detalle)
  }
  return { ...primera, detalle, detalle_truncado: false }
}

/**
 * ¿Es la misma lista (sucursal, período y motivo) en otra página o con otra
 * búsqueda? Sólo entonces se muestra la respuesta anterior mientras llega la
 * nueva: los totales no dependen de la página ni de la búsqueda, así que siguen
 * siendo los correctos. Con otro período o motivo serían de otro reporte.
 */
function esLaMismaListaEnOtraPagina(previa: QueryKey | undefined, actual: QueryKey): boolean {
  if (!previa || previa[0] !== 'reporte-mermas' || actual[0] !== 'reporte-mermas') return false
  return [1, 2, 3, 4].every((i) => previa[i] === actual[i])
}

export function useMermasReporteQuery(
  sucursalId: number | null,
  desde: string,
  hasta: string,
  motivo: string | null = null,
  enabled = true,
  { pagina = 1, busqueda = '' }: { pagina?: number; busqueda?: string } = {},
) {
  const queryKey = mermasReporteKeys.range(sucursalId, desde, hasta, motivo, busqueda, pagina)
  return useQuery({
    queryKey,
    queryFn: () =>
      fetchReporteMermas(sucursalId, desde, hasta, motivo, {
        limite: MERMAS_PAGE_SIZE,
        offset: (pagina - 1) * MERMAS_PAGE_SIZE,
        busqueda,
      }),
    enabled: enabled && Boolean(desde) && Boolean(hasta),
    staleTime: 5 * 60 * 1000,
    placeholderData: (previa, consultaPrevia) =>
      esLaMismaListaEnOtraPagina(consultaPrevia?.queryKey, queryKey) ? previa : undefined,
  })
}
