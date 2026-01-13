import { useState, useEffect } from 'react'
import { supabase, notifyError } from './base'

export function usePedidos() {
  const [pedidos, setPedidos] = useState([])
  const [loading, setLoading] = useState(true)
  const [filtros, setFiltros] = useState({
    fechaDesde: null,
    fechaHasta: null,
    estado: 'todos',
    estadoPago: 'todos',
    transportistaId: 'todos',
    busqueda: ''
  })

  const fetchPedidos = async () => {
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

      const pedidosCompletos = await Promise.all((data || []).map(async (pedido) => {
        let usuario = null, transportista = null
        if (pedido.usuario_id) {
          const { data: u } = await supabase.from('perfiles').select('id, nombre, email').eq('id', pedido.usuario_id).maybeSingle()
          usuario = u
        }
        if (pedido.transportista_id) {
          const { data: t } = await supabase.from('perfiles').select('id, nombre, email').eq('id', pedido.transportista_id).maybeSingle()
          transportista = t
        }
        return { ...pedido, usuario, transportista }
      }))
      setPedidos(pedidosCompletos)
    } catch (error) {
      notifyError('Error al cargar pedidos: ' + error.message)
      setPedidos([])
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { fetchPedidos() }, [])

  const fetchHistorialPedido = async (pedidoId) => {
    try {
      const { data, error } = await supabase
        .from('pedido_historial')
        .select('*, usuario:perfiles(id, nombre, email)')
        .eq('pedido_id', pedidoId)
        .order('created_at', { ascending: false })
      if (error) throw error
      return data || []
    } catch (error) {
      notifyError('Error al cargar historial del pedido: ' + error.message)
      return []
    }
  }

  const pedidosFiltrados = () => pedidos.filter(p => {
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

  const crearPedido = async (clienteId, items, total, usuarioId, descontarStockFn, notas = '', formaPago = 'efectivo', estadoPago = 'pendiente') => {
    const itemsParaRPC = items.map(item => ({
      producto_id: item.productoId,
      cantidad: item.cantidad,
      precio_unitario: item.precioUnitario
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

    if (!data.success) {
      throw new Error(data.errores?.join(', ') || 'Error al crear pedido')
    }

    await fetchPedidos()
    return { id: data.pedido_id }
  }

  const cambiarEstado = async (id, nuevoEstado) => {
    const updateData = { estado: nuevoEstado }
    if (nuevoEstado === 'entregado') {
      updateData.fecha_entrega = new Date().toISOString()
    } else {
      updateData.fecha_entrega = null
    }
    const { error } = await supabase.from('pedidos').update(updateData).eq('id', id)
    if (error) throw error
    setPedidos(prev => prev.map(p => p.id === id ? { ...p, ...updateData } : p))
  }

  const asignarTransportista = async (pedidoId, transportistaId, cambiarEstadoFlag = false) => {
    const updateData = { transportista_id: transportistaId || null }
    if (cambiarEstadoFlag && transportistaId) {
      updateData.estado = 'asignado'
    }
    const { error } = await supabase.from('pedidos').update(updateData).eq('id', pedidoId)
    if (error) throw error
    await fetchPedidos()
  }

  const eliminarPedido = async (id, restaurarStockFn, usuarioId = null, motivo = null) => {
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
          await eliminarPedidoManual(id, pedido, restaurarStock, usuarioId, motivo)
          setPedidos(prev => prev.filter(p => p.id !== id))
          return
        }
        throw error
      }

      if (!data.success) {
        throw new Error(data.error || 'Error al eliminar pedido')
      }

      setPedidos(prev => prev.filter(p => p.id !== id))
    } catch (rpcError) {
      // Fallback: eliminar manualmente si la función RPC falla
      if (rpcError.message.includes('v_transportista') || rpcError.message.includes('not assigned')) {
        console.warn('Función RPC con error, usando método alternativo')
        await eliminarPedidoManual(id, pedido, restaurarStock, usuarioId, motivo)
        setPedidos(prev => prev.filter(p => p.id !== id))
        return
      }
      throw rpcError
    }
  }

  // Método alternativo para eliminar pedido sin usar RPC
  const eliminarPedidoManual = async (pedidoId, pedido, restaurarStock, usuarioId, motivo) => {
    // Obtener nombre del usuario que elimina
    let eliminadoPorNombre = 'Sistema'
    if (usuarioId) {
      const { data: perfil } = await supabase
        .from('perfiles')
        .select('nombre')
        .eq('id', usuarioId)
        .single()
      if (perfil) eliminadoPorNombre = perfil.nombre
    }

    // 1. Guardar datos para trazabilidad con estructura correcta
    const datosEliminado = {
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
    const operaciones = []

    // 2. Guardar en tabla de eliminados
    operaciones.push(
      supabase.from('pedidos_eliminados').insert(datosEliminado)
        .then(({ error }) => {
          if (error) console.warn('No se pudo guardar en pedidos_eliminados:', error.message)
        })
    )

    // 3. Restaurar stock en paralelo si corresponde
    if (restaurarStock && pedido?.items?.length > 0) {
      // Obtener todos los productos de una vez
      const productIds = pedido.items.map(i => i.producto_id).filter(Boolean)
      if (productIds.length > 0) {
        const { data: productosActuales } = await supabase
          .from('productos')
          .select('id, stock')
          .in('id', productIds)

        if (productosActuales) {
          const actualizaciones = pedido.items.map(item => {
            const prod = productosActuales.find(p => p.id === item.producto_id)
            if (prod && item.cantidad) {
              return supabase
                .from('productos')
                .update({ stock: (prod.stock || 0) + item.cantidad })
                .eq('id', item.producto_id)
            }
            return Promise.resolve()
          })
          operaciones.push(...actualizaciones)
        }
      }
    }

    // 4. Eliminar items del pedido
    operaciones.push(
      supabase.from('pedido_items').delete().eq('pedido_id', pedidoId)
    )

    // 5. Eliminar historial del pedido
    operaciones.push(
      supabase.from('pedido_historial').delete().eq('pedido_id', pedidoId)
        .then(() => {})
        .catch(() => {}) // Ignorar errores si no existe historial
    )

    // Ejecutar todas las operaciones en paralelo
    await Promise.all(operaciones)

    // 6. Finalmente eliminar el pedido
    const { error } = await supabase.from('pedidos').delete().eq('id', pedidoId)
    if (error) throw error
  }

  const fetchPedidosEliminados = async () => {
    const { data, error } = await supabase
      .from('pedidos_eliminados')
      .select('*')
      .order('eliminado_at', { ascending: false })

    if (error) {
      throw error
    }

    return data || []
  }

  const actualizarNotasPedido = async (pedidoId, notas) => {
    const { error } = await supabase.from('pedidos').update({ notas }).eq('id', pedidoId)
    if (error) throw error
    setPedidos(prev => prev.map(p => p.id === pedidoId ? { ...p, notas } : p))
  }

  const actualizarEstadoPago = async (pedidoId, estadoPago, montoPagado = null) => {
    const updateData = { estado_pago: estadoPago }
    if (montoPagado !== null) {
      updateData.monto_pagado = montoPagado
    }
    const { error } = await supabase.from('pedidos').update(updateData).eq('id', pedidoId)
    if (error) throw error
    setPedidos(prev => prev.map(p => p.id === pedidoId ? {
      ...p,
      estado_pago: estadoPago,
      ...(montoPagado !== null && { monto_pagado: montoPagado })
    } : p))
  }

  const actualizarFormaPago = async (pedidoId, formaPago) => {
    const { error } = await supabase.from('pedidos').update({ forma_pago: formaPago }).eq('id', pedidoId)
    if (error) throw error
    setPedidos(prev => prev.map(p => p.id === pedidoId ? { ...p, forma_pago: formaPago } : p))
  }

  const actualizarOrdenEntrega = async (ordenOptimizado) => {
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

  const limpiarOrdenEntrega = async (transportistaId) => {
    const { error } = await supabase
      .from('pedidos')
      .update({ orden_entrega: null })
      .eq('transportista_id', transportistaId)
    if (error) throw error

    setPedidos(prev => prev.map(p =>
      p.transportista_id === transportistaId ? { ...p, orden_entrega: null } : p
    ))
  }

  const actualizarItemsPedido = async (pedidoId, items, usuarioId = null) => {
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

    if (!data.success) {
      throw new Error(data.errores?.join(', ') || 'Error al actualizar items del pedido')
    }

    // Refrescar pedidos para obtener los cambios
    await fetchPedidos()

    return data
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
