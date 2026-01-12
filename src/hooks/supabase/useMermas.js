import { useState, useEffect } from 'react'
import { supabase } from './base'

export function useMermas() {
  const [mermas, setMermas] = useState([])
  const [loading, setLoading] = useState(false)

  const fetchMermas = async () => {
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
      setMermas(data || [])
    } catch {
      setMermas([])
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { fetchMermas() }, [])

  const registrarMerma = async (mermaData) => {
    const { error: stockError } = await supabase
      .from('productos')
      .update({ stock: mermaData.stockNuevo })
      .eq('id', mermaData.productoId)

    if (stockError) throw stockError

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
      if (error.message.includes('does not exist')) {
        return { success: true, merma: null, soloStock: true }
      }
      throw error
    }

    setMermas(prev => [data, ...prev])
    return { success: true, merma: data }
  }

  const getMermasPorProducto = (productoId) => {
    return mermas.filter(m => m.producto_id === productoId)
  }

  const getResumenMermas = (fechaDesde = null, fechaHasta = null) => {
    let mermasFiltradas = [...mermas]

    if (fechaDesde) {
      mermasFiltradas = mermasFiltradas.filter(m => m.created_at >= fechaDesde)
    }
    if (fechaHasta) {
      mermasFiltradas = mermasFiltradas.filter(m => m.created_at <= fechaHasta + 'T23:59:59')
    }

    const porMotivo = {}
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
