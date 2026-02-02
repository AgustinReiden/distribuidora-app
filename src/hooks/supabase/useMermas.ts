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

  const registrarMerma = async (mermaData: MermaFormInputExtended): Promise<MermaRegistroResult> => {
    // Primero intentar insertar la merma (para fallar antes de modificar stock)
    const { data, error } = await supabase
      .from('mermas_stock')
      .insert([{
        producto_id: mermaData.productoId,
        cantidad: mermaData.cantidad,
        motivo: mermaData.motivo,
        observaciones: mermaData.observaciones || null,
        stock_anterior: mermaData.stockAnterior,
        stock_nuevo: mermaData.stockNuevo,
        usuario_id: mermaData.usuarioId || null
      }])
      .select()
      .single()

    if (error) {
      // Si la tabla no existe, solo actualizar stock (modo fallback)
      if (error.message.includes('does not exist')) {
        const { error: stockError } = await supabase
          .from('productos')
          .update({ stock: mermaData.stockNuevo })
          .eq('id', mermaData.productoId)
        if (stockError) throw stockError
        return { success: true, merma: null, soloStock: true }
      }
      throw error
    }

    const mermaCreada = data as MermaDBExtended

    // La merma se insertó correctamente, ahora actualizar stock
    const { error: stockError } = await supabase
      .from('productos')
      .update({ stock: mermaData.stockNuevo })
      .eq('id', mermaData.productoId)

    if (stockError) {
      // Revertir: eliminar la merma si el stock falla
      await supabase.from('mermas_stock').delete().eq('id', mermaCreada.id)
      throw stockError
    }

    setMermas(prev => [mermaCreada, ...prev])
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
