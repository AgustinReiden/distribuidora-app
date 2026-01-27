import { useState, useEffect, type Dispatch, type SetStateAction } from 'react'
import { supabase, notifyError } from './base'
import type {
  PedidoDB,
  PedidoItemDB,
  PerfilDB,
  FiltrosPedidosState
} from '../../types'

// Types for RPC responses
interface CrearPedidoRPCResponse {
  success: boolean;
  pedido_id?: string;
  errores?: string[];
}

interface EliminarPedidoRPCResponse {
  success: boolean;
  error?: string;
}

interface ActualizarItemsRPCResponse {
  success: boolean;
  errores?: string[];
}

// Types for input items
interface PedidoItemInput {
  productoId?: string;
  producto_id?: string;
  cantidad: number;
  precioUnitario?: number;
  precio_unitario?: number;
}

interface OrdenEntregaItem {
  pedido_id: string;
  orden: number;
}

// Type for pedido eliminado (extended version stored in pedidos_eliminados)
interface PedidoEliminadoDB {
  pedido_id: string;
  cliente_id?: string;
  cliente_nombre?: string;
  cliente_direccion?: string;
  total: number;
  estado?: string;
  estado_pago?: string;
  forma_pago?: string;
  monto_pagado?: number;
  notas?: string | null;
  items?: Array<{
    producto_id: string;
    producto_nombre?: string;
    cantidad: number;
    precio_unitario: number;
    subtotal?: number;
  }>;
  usuario_creador_id?: string | null;
  usuario_creador_nombre?: string | null;
  transportista_id?: string | null;
  transportista_nombre?: string | null;
  fecha_pedido?: string | null;
  fecha_entrega?: string | null;
  eliminado_por_id?: string | null;
  eliminado_por_nombre?: string;
  motivo_eliminacion?: string;
  stock_restaurado?: boolean;
  eliminado_at?: string;
}

// Type for historial entries
interface PedidoHistorialDB {
  id: string;
  pedido_id: string;
  usuario_id?: string;
  usuario?: PerfilDB;
  accion?: string;
  detalles?: string;
  created_at?: string;
}

// Return type for the hook
export interface UsePedidosHookReturn {
  pedidos: PedidoDB[];
  pedidosFiltrados: () => PedidoDB[];
  loading: boolean;
  crearPedido: (
    clienteId: string,
    items: PedidoItemInput[],
    total: number,
    usuarioId: string | null,
    descontarStockFn: ((items: PedidoItemInput[]) => Promise<void>) | null,
    notas?: string,
    formaPago?: string,
    estadoPago?: string
  ) => Promise<{ id: string }>;
  cambiarEstado: (id: string, nuevoEstado: string) => Promise<void>;
  asignarTransportista: (pedidoId: string, transportistaId: string | null, cambiarEstadoFlag?: boolean) => Promise<void>;
  eliminarPedido: (
    id: string,
    restaurarStockFn: ((items: PedidoItemDB[]) => Promise<void>) | null,
    usuarioId?: string | null,
    motivo?: string | null
  ) => Promise<void>;
  actualizarNotasPedido: (pedidoId: string, notas: string) => Promise<void>;
  actualizarEstadoPago: (pedidoId: string, estadoPago: string, montoPagado?: number | null) => Promise<void>;
  actualizarFormaPago: (pedidoId: string, formaPago: string) => Promise<void>;
  actualizarOrdenEntrega: (ordenOptimizado: OrdenEntregaItem[]) => Promise<void>;
  limpiarOrdenEntrega: (transportistaId: string) => Promise<void>;
  actualizarItemsPedido: (pedidoId: string, items: PedidoItemInput[], usuarioId?: string | null) => Promise<ActualizarItemsRPCResponse>;
  fetchHistorialPedido: (pedidoId: string) => Promise<PedidoHistorialDB[]>;
  fetchPedidosEliminados: () => Promise<PedidoEliminadoDB[]>;
  filtros: FiltrosPedidosState;
  setFiltros: Dispatch<SetStateAction<FiltrosPedidosState>>;
  refetch: () => Promise<void>;
}

export function usePedidos(): UsePedidosHookReturn {
  const [pedidos, setPedidos] = useState<PedidoDB[]>([])
  const [loading, setLoading] = useState<boolean>(true)
  const [filtros, setFiltros] = useState<FiltrosPedidosState>({
    fechaDesde: null,
    fechaHasta: null,
    estado: 'todos',
    estadoPago: 'todos',
    transportistaId: 'todos',
    busqueda: ''
  })

  const fetchPedidos = async (): Promise<void> => {
    setLoading(true)
    try {
      const { data, error } = await supabase
        .from('pedidos')
        .select(`*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))`)
        .order('created_at', { ascending: false })

      if (error) {
        setPedidos([])
        setLoading(false)
        return
      }

      // Obtener IDs únicos de usuarios y transportistas para hacer UNA sola query
      const perfilIds = new Set<string>()
      for (const pedido of (data || [])) {
        if (pedido.usuario_id) perfilIds.add(pedido.usuario_id as string)
        if (pedido.transportista_id) perfilIds.add(pedido.transportista_id as string)
      }

      // Obtener todos los perfiles necesarios en una sola query
      let perfilesMap: Record<string, PerfilDB> = {}
      if (perfilIds.size > 0) {
        const { data: perfiles } = await supabase
          .from('perfiles')
          .select('id, nombre, email')
          .in('id', Array.from(perfilIds))

        if (perfiles) {
          perfilesMap = Object.fromEntries(
            (perfiles as PerfilDB[]).map(p => [p.id, p])
          )
        }
      }

      // Obtener salvedades de pedidos entregados
      const pedidosEntregadosIds = (data || [])
        .filter(p => p.estado === 'entregado')
        .map(p => p.id)

      let salvedadesMap: Record<string, Array<{
        id: string;
        motivo: string;
        cantidad_afectada: number;
        monto_afectado: number;
        estado_resolucion: string;
        producto_id: string;
      }>> = {}

      if (pedidosEntregadosIds.length > 0) {
        const { data: salvedades } = await supabase
          .from('salvedades_items')
          .select('id, pedido_id, motivo, cantidad_afectada, monto_afectado, estado_resolucion, producto_id')
          .in('pedido_id', pedidosEntregadosIds)

        if (salvedades) {
          for (const s of salvedades) {
            const pedidoId = String(s.pedido_id)
            if (!salvedadesMap[pedidoId]) {
              salvedadesMap[pedidoId] = []
            }
            salvedadesMap[pedidoId].push({
              id: String(s.id),
              motivo: s.motivo,
              cantidad_afectada: s.cantidad_afectada,
              monto_afectado: Number(s.monto_afectado),
              estado_resolucion: s.estado_resolucion,
              producto_id: String(s.producto_id)
            })
          }
        }
      }

      // Mapear perfiles y salvedades a pedidos
      const pedidosCompletos: PedidoDB[] = (data || []).map(pedido => ({
        ...pedido,
        usuario: pedido.usuario_id ? perfilesMap[pedido.usuario_id as string] || null : null,
        transportista: pedido.transportista_id ? perfilesMap[pedido.transportista_id as string] || null : null,
        salvedades: salvedadesMap[String(pedido.id)] || []
      })) as PedidoDB[]

      setPedidos(pedidosCompletos)
    } catch (error) {
      const err = error as Error
      notifyError('Error al cargar pedidos: ' + err.message)
      setPedidos([])
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { fetchPedidos() }, [])

  const fetchHistorialPedido = async (pedidoId: string): Promise<PedidoHistorialDB[]> => {
    try {
      const { data, error } = await supabase
        .from('pedido_historial')
        .select('*, usuario:perfiles(id, nombre, email)')
        .eq('pedido_id', pedidoId)
        .order('created_at', { ascending: false })
      if (error) throw error
      return (data || []) as PedidoHistorialDB[]
    } catch (error) {
      const err = error as Error
      notifyError('Error al cargar historial del pedido: ' + err.message)
      return []
    }
  }

  const pedidosFiltrados = (): PedidoDB[] => pedidos.filter(p => {
    if (filtros.estado !== 'todos' && p.estado !== filtros.estado) return false
    if (filtros.estadoPago && filtros.estadoPago !== 'todos') {
      const estadoPagoActual = p.estado_pago || 'pendiente'
      if (estadoPagoActual !== filtros.estadoPago) return false
    }
    if (filtros.transportistaId && filtros.transportistaId !== 'todos') {
      if (filtros.transportistaId === 'sin_asignar') {
        if (p.transportista_id) return false
      } else {
        if (p.transportista_id !== filtros.transportistaId) return false
      }
    }
    const fechaPedido = p.created_at ? p.created_at.split('T')[0] : null
    if (filtros.fechaDesde && fechaPedido && fechaPedido < filtros.fechaDesde) return false
    if (filtros.fechaHasta && fechaPedido && fechaPedido > filtros.fechaHasta) return false
    return true
  })

  const crearPedido = async (
    clienteId: string,
    items: PedidoItemInput[],
    total: number,
    usuarioId: string | null,
    descontarStockFn: ((items: PedidoItemInput[]) => Promise<void>) | null,
    notas: string = '',
    formaPago: string = 'efectivo',
    estadoPago: string = 'pendiente'
  ): Promise<{ id: string }> => {
    const itemsParaRPC = items.map(item => ({
      producto_id: item.productoId || item.producto_id,
      cantidad: item.cantidad,
      precio_unitario: item.precioUnitario || item.precio_unitario
    }))

    const { data, error } = await supabase.rpc('crear_pedido_completo', {
      p_cliente_id: clienteId,
      p_total: total,
      p_usuario_id: usuarioId,
      p_items: itemsParaRPC,
      p_notas: notas || null,
      p_forma_pago: formaPago || 'efectivo',
      p_estado_pago: estadoPago || 'pendiente'
    })

    if (error) {
      throw error
    }

    const response = data as CrearPedidoRPCResponse
    if (!response.success) {
      throw new Error(response.errores?.join(', ') || 'Error al crear pedido')
    }

    await fetchPedidos()
    return { id: response.pedido_id! }
  }

  const cambiarEstado = async (id: string, nuevoEstado: string): Promise<void> => {
    const updateData: { estado: PedidoDB['estado']; fecha_entrega: string | null } = {
      estado: nuevoEstado as PedidoDB['estado'],
      fecha_entrega: null
    }
    if (nuevoEstado === 'entregado') {
      updateData.fecha_entrega = new Date().toISOString()
    }
    const { error } = await supabase.from('pedidos').update(updateData).eq('id', id)
    if (error) throw error
    setPedidos(prev => prev.map(p => p.id === id ? { ...p, ...updateData } as PedidoDB : p))
  }

  const asignarTransportista = async (
    pedidoId: string,
    transportistaId: string | null,
    cambiarEstadoFlag: boolean = false
  ): Promise<void> => {
    const updateData: { transportista_id: string | null; estado?: string } = {
      transportista_id: transportistaId || null
    }
    if (cambiarEstadoFlag && transportistaId) {
      updateData.estado = 'asignado'
    }
    const { error } = await supabase.from('pedidos').update(updateData).eq('id', pedidoId)
    if (error) throw error
    await fetchPedidos()
  }

  const eliminarPedido = async (
    id: string,
    restaurarStockFn: ((items: PedidoItemDB[]) => Promise<void>) | null,
    usuarioId: string | null = null,
    motivo: string | null = null
  ): Promise<void> => {
    const pedido = pedidos.find(p => p.id === id)
    const restaurarStock = pedido?.stock_descontado ?? true

    // Intentar usar la función RPC primero
    try {
      const { data, error } = await supabase.rpc('eliminar_pedido_completo', {
        p_pedido_id: id,
        p_restaurar_stock: restaurarStock,
        p_usuario_id: usuarioId,
        p_motivo: motivo
      })

      if (error) {
        // Si hay error en la función RPC, usar método alternativo
        if (error.message.includes('v_transportista') || error.message.includes('not assigned')) {
          console.warn('Función RPC con error, usando método alternativo')
          await eliminarPedidoManual(id, pedido || null, restaurarStock, usuarioId, motivo)
          setPedidos(prev => prev.filter(p => p.id !== id))
          return
        }
        throw error
      }

      const response = data as EliminarPedidoRPCResponse
      if (!response.success) {
        throw new Error(response.error || 'Error al eliminar pedido')
      }

      setPedidos(prev => prev.filter(p => p.id !== id))
    } catch (rpcError) {
      const err = rpcError as Error
      // Fallback: eliminar manualmente si la función RPC falla
      if (err.message.includes('v_transportista') || err.message.includes('not assigned')) {
        console.warn('Función RPC con error, usando método alternativo')
        await eliminarPedidoManual(id, pedido || null, restaurarStock, usuarioId, motivo)
        setPedidos(prev => prev.filter(p => p.id !== id))
        return
      }
      throw rpcError
    }
  }

  // Método alternativo para eliminar pedido sin usar RPC
  const eliminarPedidoManual = async (
    pedidoId: string,
    pedido: PedidoDB | null,
    restaurarStock: boolean,
    usuarioId: string | null,
    motivo: string | null
  ): Promise<void> => {
    // Obtener nombre del usuario que elimina
    let eliminadoPorNombre = 'Sistema'
    if (usuarioId) {
      const { data: perfil } = await supabase
        .from('perfiles')
        .select('nombre')
        .eq('id', usuarioId)
        .single()
      if (perfil) eliminadoPorNombre = (perfil as { nombre: string }).nombre
    }

    // 1. Guardar datos para trazabilidad con estructura correcta
    const datosEliminado: PedidoEliminadoDB = {
      pedido_id: pedidoId,
      cliente_id: pedido?.cliente_id,
      cliente_nombre: pedido?.cliente?.nombre_fantasia || 'Desconocido',
      cliente_direccion: pedido?.cliente?.direccion || '',
      total: pedido?.total || 0,
      estado: pedido?.estado,
      estado_pago: pedido?.estado_pago,
      forma_pago: pedido?.forma_pago,
      monto_pagado: pedido?.monto_pagado || 0,
      notas: pedido?.notas || null,
      items: pedido?.items?.map(i => ({
        producto_id: i.producto_id,
        producto_nombre: i.producto?.nombre,
        cantidad: i.cantidad,
        precio_unitario: i.precio_unitario,
        subtotal: i.subtotal || (i.cantidad * i.precio_unitario)
      })) || [],
      usuario_creador_id: pedido?.usuario_id || null,
      usuario_creador_nombre: pedido?.usuario?.nombre || null,
      transportista_id: pedido?.transportista_id || null,
      transportista_nombre: pedido?.transportista?.nombre || null,
      fecha_pedido: pedido?.created_at || null,
      fecha_entrega: pedido?.fecha_entrega || null,
      eliminado_por_id: usuarioId,
      eliminado_por_nombre: eliminadoPorNombre,
      motivo_eliminacion: motivo || 'Sin especificar',
      stock_restaurado: restaurarStock
    }

    // Ejecutar operaciones en paralelo para mayor velocidad
    const operaciones: Promise<unknown>[] = []

    // 2. Guardar en tabla de eliminados
    operaciones.push(
      Promise.resolve(supabase.from('pedidos_eliminados').insert(datosEliminado))
        .then(({ error }) => {
          if (error) console.warn('No se pudo guardar en pedidos_eliminados:', error.message)
        })
    )

    // 3. Restaurar stock en paralelo si corresponde
    if (restaurarStock && pedido?.items?.length && pedido.items.length > 0) {
      // Obtener todos los productos de una vez
      const productIds = pedido.items.map(i => i.producto_id).filter(Boolean)
      if (productIds.length > 0) {
        const { data: productosActuales } = await supabase
          .from('productos')
          .select('id, stock')
          .in('id', productIds)

        if (productosActuales) {
          const actualizaciones = pedido.items.map(item => {
            const prod = (productosActuales as Array<{ id: string; stock: number }>).find(p => p.id === item.producto_id)
            if (prod && item.cantidad) {
              return Promise.resolve(
                supabase
                  .from('productos')
                  .update({ stock: (prod.stock || 0) + item.cantidad })
                  .eq('id', item.producto_id)
              )
            }
            return Promise.resolve()
          })
          operaciones.push(...actualizaciones)
        }
      }
    }

    // 4. Eliminar items del pedido
    operaciones.push(
      Promise.resolve(supabase.from('pedido_items').delete().eq('pedido_id', pedidoId))
    )

    // 5. Eliminar historial del pedido
    operaciones.push(
      Promise.resolve(supabase.from('pedido_historial').delete().eq('pedido_id', pedidoId))
        .then(() => {})
        .catch(() => {}) // Ignorar errores si no existe historial
    )

    // Ejecutar todas las operaciones en paralelo
    await Promise.all(operaciones)

    // 6. Finalmente eliminar el pedido
    const { error } = await supabase.from('pedidos').delete().eq('id', pedidoId)
    if (error) throw error
  }

  const fetchPedidosEliminados = async (): Promise<PedidoEliminadoDB[]> => {
    const { data, error } = await supabase
      .from('pedidos_eliminados')
      .select('*')
      .order('eliminado_at', { ascending: false })

    if (error) {
      throw error
    }

    return (data || []) as PedidoEliminadoDB[]
  }

  const actualizarNotasPedido = async (pedidoId: string, notas: string): Promise<void> => {
    const { error } = await supabase.from('pedidos').update({ notas }).eq('id', pedidoId)
    if (error) throw error
    setPedidos(prev => prev.map(p => p.id === pedidoId ? { ...p, notas } : p))
  }

  const actualizarEstadoPago = async (
    pedidoId: string,
    estadoPago: string,
    montoPagado: number | null = null
  ): Promise<void> => {
    const updateData: { estado_pago: string; monto_pagado?: number } = { estado_pago: estadoPago }
    if (montoPagado !== null) {
      updateData.monto_pagado = montoPagado
    }
    const { error } = await supabase.from('pedidos').update(updateData).eq('id', pedidoId)
    if (error) throw error
    setPedidos(prev => prev.map(p => p.id === pedidoId ? {
      ...p,
      estado_pago: estadoPago as PedidoDB['estado_pago'],
      ...(montoPagado !== null && { monto_pagado: montoPagado })
    } : p))
  }

  const actualizarFormaPago = async (pedidoId: string, formaPago: string): Promise<void> => {
    const { error } = await supabase.from('pedidos').update({ forma_pago: formaPago }).eq('id', pedidoId)
    if (error) throw error
    setPedidos(prev => prev.map(p => p.id === pedidoId ? { ...p, forma_pago: formaPago } : p))
  }

  const actualizarOrdenEntrega = async (ordenOptimizado: OrdenEntregaItem[]): Promise<void> => {
    if (!ordenOptimizado || ordenOptimizado.length === 0) return

    const { error: rpcError } = await supabase.rpc('actualizar_orden_entrega_batch', {
      ordenes: ordenOptimizado.map(item => ({
        pedido_id: item.pedido_id,
        orden: item.orden
      }))
    })

    if (rpcError) {
      for (const item of ordenOptimizado) {
        const { error } = await supabase
          .from('pedidos')
          .update({ orden_entrega: item.orden })
          .eq('id', item.pedido_id)

        if (error) {
          if (error.message.includes('schema cache') || error.message.includes('orden_entrega')) {
            throw new Error('La columna orden_entrega no existe en la base de datos. Contacte al administrador para ejecutar la migracion pendiente.')
          }
          throw error
        }
      }
    }

    setPedidos(prev => prev.map(p => {
      const ordenItem = ordenOptimizado.find(o => o.pedido_id === p.id)
      if (ordenItem) {
        return { ...p, orden_entrega: ordenItem.orden }
      }
      return p
    }))
  }

  const limpiarOrdenEntrega = async (transportistaId: string): Promise<void> => {
    const { error } = await supabase
      .from('pedidos')
      .update({ orden_entrega: null })
      .eq('transportista_id', transportistaId)
    if (error) throw error

    setPedidos(prev => prev.map(p =>
      p.transportista_id === transportistaId ? { ...p, orden_entrega: null } : p
    ))
  }

  const actualizarItemsPedido = async (
    pedidoId: string,
    items: PedidoItemInput[],
    usuarioId: string | null = null
  ): Promise<ActualizarItemsRPCResponse> => {
    const itemsParaRPC = items.map(item => ({
      producto_id: item.productoId || item.producto_id,
      cantidad: item.cantidad,
      precio_unitario: item.precioUnitario || item.precio_unitario
    }))

    const { data, error } = await supabase.rpc('actualizar_pedido_items', {
      p_pedido_id: pedidoId,
      p_items_nuevos: itemsParaRPC,
      p_usuario_id: usuarioId
    })

    if (error) throw error

    const response = data as ActualizarItemsRPCResponse
    if (!response.success) {
      throw new Error(response.errores?.join(', ') || 'Error al actualizar items del pedido')
    }

    // Refrescar pedidos para obtener los cambios
    await fetchPedidos()

    return response
  }

  return {
    pedidos,
    pedidosFiltrados,
    loading,
    crearPedido,
    cambiarEstado,
    asignarTransportista,
    eliminarPedido,
    actualizarNotasPedido,
    actualizarEstadoPago,
    actualizarFormaPago,
    actualizarOrdenEntrega,
    limpiarOrdenEntrega,
    actualizarItemsPedido,
    fetchHistorialPedido,
    fetchPedidosEliminados,
    filtros,
    setFiltros,
    refetch: fetchPedidos
  }
}
