/**
 * useMermas - Hook para gestión de mermas de stock
 *
 * @deprecated Este hook usa useState/useEffect. Para nuevos componentes,
 * usar TanStack Query hooks de `src/hooks/queries/useMermasQuery.ts`:
 * - useMermasQuery() para obtener mermas
 * - useRegistrarMermaMutation() para registrar
 * - useMermasResumen() para resúmenes
 *
 * Migración: Reemplazar `const { mermas } = useMermas()`
 * con `const { data: mermas } = useMermasQuery()`
 */

import { useState, useEffect } from 'react'
import { supabase } from './base'
import { useSucursal } from '../../contexts/SucursalContext'
import type {
  MermaDBExtended,
  MermaFormInputExtended,
  MermaRegistroResult,
  ResumenMermas,
  ResumenMermasPorMotivo,
  UseMermasReturnExtended
} from '../../types'

/**
 * @deprecated Usar useMermasQuery de src/hooks/queries en su lugar
 */
export function useMermas(): UseMermasReturnExtended {
  const { currentSucursalId } = useSucursal()
  const [mermas, setMermas] = useState<MermaDBExtended[]>([])
  const [loading, setLoading] = useState<boolean>(false)

  const fetchMermas = async (): Promise<void> => {
    setLoading(true)
    try {
      const { data, error } = await supabase
        .from('mermas_stock')
        .select('*')
        .order('created_at', { ascending: false })
      if (error) {
        if (error.message.includes('does not exist')) {
          setMermas([])
          return
        }
        throw error
      }
      setMermas((data || []) as MermaDBExtended[])
    } catch {
      setMermas([])
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { fetchMermas() }, [])

  /**
   * La MISMA RPC que useMermasQuery (mig 232), no una copia del INSERT + UPDATE.
   *
   * Esta es la que está cableada al replay offline (App.tsx → useSyncManager →
   * sincronizarMermas), donde el valor absoluto era todavía peor: el payload
   * encolado podía tener horas de viejo. Ahora viaja la cantidad y el stock lo
   * resuelve el servidor contra el saldo del momento del replay.
   */
  const registrarMerma = async (mermaData: MermaFormInputExtended): Promise<MermaRegistroResult> => {
    if (currentSucursalId == null) {
      throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
    }

    const { data, error } = await supabase.rpc('registrar_merma_manual', {
      p_producto_id: mermaData.productoId,
      p_cantidad: mermaData.cantidad,
      p_motivo: mermaData.motivo,
      p_observaciones: mermaData.observaciones || null,
      p_sucursal_id: currentSucursalId
    })

    if (error) throw error

    const resultado = data as { ok: boolean; merma: MermaDBExtended } | null
    const mermaCreada = resultado?.merma ?? null

    if (mermaCreada) setMermas(prev => [mermaCreada, ...prev])
    return { success: true, merma: mermaCreada }
  }

  const getMermasPorProducto = (productoId: string): MermaDBExtended[] => {
    return mermas.filter(m => m.producto_id === productoId)
  }

  const getResumenMermas = (
    fechaDesde: string | null = null,
    fechaHasta: string | null = null
  ): ResumenMermas => {
    let mermasFiltradas = [...mermas]

    if (fechaDesde) {
      // Normalizar fecha desde (inicio del día)
      const desde = fechaDesde.includes('T') ? fechaDesde.split('T')[0] : fechaDesde
      mermasFiltradas = mermasFiltradas.filter(m => (m.created_at || '') >= desde)
    }
    if (fechaHasta) {
      // Normalizar fecha hasta (fin del día)
      const hasta = fechaHasta.includes('T') ? fechaHasta.split('T')[0] : fechaHasta
      mermasFiltradas = mermasFiltradas.filter(m => (m.created_at || '') <= hasta + 'T23:59:59')
    }

    const porMotivo: Record<string, ResumenMermasPorMotivo> = {}
    mermasFiltradas.forEach(m => {
      if (!porMotivo[m.motivo]) {
        porMotivo[m.motivo] = { cantidad: 0, registros: 0 }
      }
      porMotivo[m.motivo].cantidad += m.cantidad
      porMotivo[m.motivo].registros += 1
    })

    return {
      totalUnidades: mermasFiltradas.reduce((sum, m) => sum + m.cantidad, 0),
      totalRegistros: mermasFiltradas.length,
      porMotivo
    }
  }

  return {
    mermas,
    loading,
    registrarMerma,
    getMermasPorProducto,
    getResumenMermas,
    refetch: fetchMermas
  }
}
