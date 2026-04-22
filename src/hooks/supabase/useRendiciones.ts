/**
 * Hook para gestión de rendiciones (resumen auto-calculado + control diario)
 * @module hooks/supabase/useRendiciones
 */
import { useState, useCallback } from 'react'
import { supabase, notifyError } from './base'
import { fechaLocalISO } from '../../utils/formatters'
import type {
  ResumenRendicionDiaria,
  ControlRendicionInfo,
  UseRendicionesReturn,
  EstadoRendicion,
  RendicionGastoInput
} from '../../types'

export function useRendiciones(): UseRendicionesReturn {
  const [resumenes, setResumenes] = useState<ResumenRendicionDiaria[]>([])
  const [loading, setLoading] = useState<boolean>(false)
  const [ultimoRango, setUltimoRango] = useState<{
    desde: string
    hasta: string
    transportistaId: string | null
  } | null>(null)

  const fetchResumen = useCallback(async (
    fechaDesde: string,
    fechaHasta: string,
    transportistaId?: string | null
  ): Promise<ResumenRendicionDiaria[]> => {
    setLoading(true)
    try {
      const { data, error } = await supabase.rpc('obtener_resumen_rendiciones', {
        p_fecha_desde: fechaDesde,
        p_fecha_hasta: fechaHasta,
        p_transportista_id: transportistaId || null
      })

      if (error) throw error

      const resumen = (data || []).map((r: Record<string, unknown>) => ({
        fecha: r.fecha as string,
        transportista_id: r.transportista_id as string,
        transportista_nombre: (r.transportista_nombre as string) || 'Sin asignar',
        total_efectivo: Number(r.total_efectivo) || 0,
        total_transferencia: Number(r.total_transferencia) || 0,
        total_cheque: Number(r.total_cheque) || 0,
        total_cuenta_corriente: Number(r.total_cuenta_corriente) || 0,
        total_tarjeta: Number(r.total_tarjeta) || 0,
        total_otros: Number(r.total_otros) || 0,
        total_general: Number(r.total_general) || 0,
        cantidad_pedidos: Number(r.cantidad_pedidos) || 0,
        total_entregado: Number(r.total_entregado) || 0,
        total_gastos: Number(r.total_gastos) || 0,
        cantidad_gastos: Number(r.cantidad_gastos) || 0,
        estado: ((r.estado as string) || 'pendiente') as EstadoRendicion,
        observaciones: (r.observaciones as string) || null,
        controlada: Boolean(r.controlada),
        controlada_at: (r.controlada_at as string) || null,
        controlada_por_nombre: (r.controlada_por_nombre as string) || null,
        resuelta_at: (r.resuelta_at as string) || null,
        resuelta_por_nombre: (r.resuelta_por_nombre as string) || null
      })) as ResumenRendicionDiaria[]

      setResumenes(resumen)
      setUltimoRango({
        desde: fechaDesde,
        hasta: fechaHasta,
        transportistaId: transportistaId || null
      })
      return resumen
    } catch (error) {
      notifyError('Error al cargar rendiciones: ' + (error as Error).message)
      setResumenes([])
      return []
    } finally {
      setLoading(false)
    }
  }, [])

  const marcarControlada = useCallback(async (
    fecha: string,
    transportistaId: string
  ): Promise<void> => {
    const { error } = await supabase.rpc('marcar_rendicion_controlada', {
      p_fecha: fecha,
      p_transportista_id: transportistaId
    })

    if (error) {
      notifyError('Error al marcar como controlada: ' + error.message)
      throw error
    }

    if (ultimoRango) {
      await fetchResumen(ultimoRango.desde, ultimoRango.hasta, ultimoRango.transportistaId)
    }
  }, [ultimoRango, fetchResumen])

  const desmarcarControlada = useCallback(async (
    fecha: string,
    transportistaId: string
  ): Promise<void> => {
    const { error } = await supabase.rpc('desmarcar_rendicion_controlada', {
      p_fecha: fecha,
      p_transportista_id: transportistaId
    })

    if (error) {
      notifyError('Error al desmarcar control: ' + error.message)
      throw error
    }

    if (ultimoRango) {
      await fetchResumen(ultimoRango.desde, ultimoRango.hasta, ultimoRango.transportistaId)
    }
  }, [ultimoRango, fetchResumen])

  const confirmarRendicion = useCallback(async (
    fecha: string,
    transportistaId: string,
    estado: 'confirmada' | 'disconformidad',
    observaciones?: string | null,
    gastos?: RendicionGastoInput[]
  ): Promise<void> => {
    const { error } = await supabase.rpc('confirmar_rendicion', {
      p_fecha: fecha,
      p_transportista_id: transportistaId,
      p_estado: estado,
      p_observaciones: observaciones ?? null,
      p_gastos: (gastos || []) as unknown
    })

    if (error) {
      notifyError('Error al cerrar rendición: ' + error.message)
      throw error
    }

    if (ultimoRango) {
      await fetchResumen(ultimoRango.desde, ultimoRango.hasta, ultimoRango.transportistaId)
    }
  }, [ultimoRango, fetchResumen])

  const resolverRendicion = useCallback(async (
    fecha: string,
    transportistaId: string,
    observaciones: string
  ): Promise<void> => {
    const { error } = await supabase.rpc('resolver_rendicion', {
      p_fecha: fecha,
      p_transportista_id: transportistaId,
      p_observaciones: observaciones
    })

    if (error) {
      notifyError('Error al resolver rendición: ' + error.message)
      throw error
    }

    if (ultimoRango) {
      await fetchResumen(ultimoRango.desde, ultimoRango.hasta, ultimoRango.transportistaId)
    }
  }, [ultimoRango, fetchResumen])

  const consultarControl = useCallback(async (
    transportistaId: string,
    fecha: string
  ): Promise<ControlRendicionInfo> => {
    const { data, error } = await supabase.rpc('consultar_control_rendicion', {
      p_transportista_id: transportistaId,
      p_fecha: fecha
    })

    if (error) {
      notifyError('Error al consultar control: ' + error.message)
      throw error
    }

    const row = Array.isArray(data) ? data[0] : data
    return {
      controlada: Boolean(row?.controlada),
      controlada_at: (row?.controlada_at as string) || null,
      controlada_por_nombre: (row?.controlada_por_nombre as string) || null
    }
  }, [])

  const refetch = useCallback(async () => {
    if (ultimoRango) {
      await fetchResumen(ultimoRango.desde, ultimoRango.hasta, ultimoRango.transportistaId)
    } else {
      const hoy = fechaLocalISO()
      await fetchResumen(hoy, hoy)
    }
  }, [ultimoRango, fetchResumen])

  return {
    resumenes,
    loading,
    fetchResumen,
    marcarControlada,
    desmarcarControlada,
    confirmarRendicion,
    resolverRendicion,
    consultarControl,
    refetch
  }
}
