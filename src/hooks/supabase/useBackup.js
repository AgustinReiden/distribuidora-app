import { useState } from 'react'
import { createMultiSheetExcel } from '../../utils/excel'
import { supabase } from './base'

export function useBackup() {
  const [exportando, setExportando] = useState(false)

  const exportarDatos = async (tipo = 'completo') => {
    setExportando(true)
    try {
      const backup = { fecha: new Date().toISOString(), tipo }
      if (tipo === 'completo' || tipo === 'clientes') {
        const { data } = await supabase.from('clientes').select('*')
        backup.clientes = data
      }
      if (tipo === 'completo' || tipo === 'productos') {
        const { data } = await supabase.from('productos').select('*')
        backup.productos = data
      }
      if (tipo === 'completo' || tipo === 'pedidos') {
        const { data } = await supabase.from('pedidos').select(`*, cliente:clientes(*), items:pedido_items(*, producto:productos(*))`)
        backup.pedidos = data
      }
      return backup
    } finally {
      setExportando(false)
    }
  }

  const descargarJSON = async (tipo = 'completo') => {
    const datos = await exportarDatos(tipo)
    const blob = new Blob([JSON.stringify(datos, null, 2)], { type: 'application/json' })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `backup_${tipo}_${new Date().toISOString().split('T')[0]}.json`
    a.click()
    URL.revokeObjectURL(url)
  }

  const exportarPedidosExcel = async (pedidos, filtrosActivos = {}, transportistas = []) => {
    setExportando(true)
    try {
      const estadoLabels = {
        pendiente: 'Pendiente',
        en_preparacion: 'En Preparación',
        asignado: 'En Camino',
        entregado: 'Entregado'
      }
      const estadoPagoLabels = {
        pendiente: 'Pendiente',
        parcial: 'Parcial',
        pagado: 'Pagado'
      }
      const formaPagoLabels = {
        efectivo: 'Efectivo',
        transferencia: 'Transferencia',
        cheque: 'Cheque',
        cuenta_corriente: 'Cuenta Corriente',
        tarjeta: 'Tarjeta'
      }

      const getTransportistaNombre = (id) => {
        if (!id || id === 'todos') return null
        if (id === 'sin_asignar') return 'Sin asignar'
        const t = transportistas.find(tr => tr.id === id)
        return t?.nombre || id
      }

      const infoFiltros = []
      infoFiltros.push({ 'Campo': 'Fecha de Exportación', 'Valor': new Date().toLocaleString('es-AR') })
      infoFiltros.push({ 'Campo': 'Total de Registros', 'Valor': pedidos.length })
      infoFiltros.push({ 'Campo': '', 'Valor': '' })
      infoFiltros.push({ 'Campo': '--- FILTROS APLICADOS ---', 'Valor': '' })

      if (filtrosActivos.estado && filtrosActivos.estado !== 'todos') {
        infoFiltros.push({ 'Campo': 'Estado del Pedido', 'Valor': estadoLabels[filtrosActivos.estado] || filtrosActivos.estado })
      }
      if (filtrosActivos.estadoPago && filtrosActivos.estadoPago !== 'todos') {
        infoFiltros.push({ 'Campo': 'Estado de Pago', 'Valor': estadoPagoLabels[filtrosActivos.estadoPago] || filtrosActivos.estadoPago })
      }
      if (filtrosActivos.transportistaId && filtrosActivos.transportistaId !== 'todos') {
        infoFiltros.push({ 'Campo': 'Transportista', 'Valor': getTransportistaNombre(filtrosActivos.transportistaId) })
      }
      if (filtrosActivos.fechaDesde) {
        infoFiltros.push({ 'Campo': 'Fecha Desde', 'Valor': filtrosActivos.fechaDesde })
      }
      if (filtrosActivos.fechaHasta) {
        infoFiltros.push({ 'Campo': 'Fecha Hasta', 'Valor': filtrosActivos.fechaHasta })
      }
      if (filtrosActivos.busqueda) {
        infoFiltros.push({ 'Campo': 'Búsqueda', 'Valor': filtrosActivos.busqueda })
      }

      const hayFiltrosActivos = (filtrosActivos.estado && filtrosActivos.estado !== 'todos') ||
        (filtrosActivos.estadoPago && filtrosActivos.estadoPago !== 'todos') ||
        (filtrosActivos.transportistaId && filtrosActivos.transportistaId !== 'todos') ||
        filtrosActivos.fechaDesde || filtrosActivos.fechaHasta || filtrosActivos.busqueda

      if (!hayFiltrosActivos) {
        infoFiltros.push({ 'Campo': '(Sin filtros - Todos los pedidos)', 'Valor': '' })
      }

      const datosPedidos = pedidos.map(p => ({
        'ID Pedido': p.id,
        'Fecha': new Date(p.created_at).toLocaleDateString('es-AR'),
        'Hora': new Date(p.created_at).toLocaleTimeString('es-AR', { hour: '2-digit', minute: '2-digit' }),
        'Cliente': p.cliente?.nombre_fantasia || 'Sin cliente',
        'Teléfono': p.cliente?.telefono || '-',
        'Dirección': p.cliente?.direccion || '-',
        'Zona': p.cliente?.zona || '-',
        'Estado Pedido': estadoLabels[p.estado] || p.estado,
        'Estado Pago': estadoPagoLabels[p.estado_pago] || p.estado_pago || 'Pendiente',
        'Forma de Pago': formaPagoLabels[p.forma_pago] || p.forma_pago || 'Efectivo',
        'Transportista': p.transportista?.nombre || 'Sin asignar',
        'Preventista': p.usuario?.nombre || '-',
        'Productos': p.items?.map(i => `${i.producto?.nombre || 'Producto'} x${i.cantidad}`).join(', ') || '-',
        'Cantidad Items': p.items?.reduce((sum, i) => sum + i.cantidad, 0) || 0,
        'Total': p.total || 0,
        'Notas': p.notas || '-',
        'Fecha Entrega': p.fecha_entrega ? new Date(p.fecha_entrega).toLocaleDateString('es-AR') : '-'
      }))

      const datosItems = []
      pedidos.forEach(p => {
        p.items?.forEach(item => {
          datosItems.push({
            'ID Pedido': p.id,
            'Fecha Pedido': new Date(p.created_at).toLocaleDateString('es-AR'),
            'Cliente': p.cliente?.nombre_fantasia || 'Sin cliente',
            'Producto': item.producto?.nombre || 'Producto sin nombre',
            'Código': item.producto?.codigo || '-',
            'Categoría': item.producto?.categoria || '-',
            'Cantidad': item.cantidad,
            'Precio Unitario': item.precio_unitario || 0,
            'Subtotal': item.subtotal || (item.cantidad * item.precio_unitario) || 0
          })
        })
      })

      const resumenEstados = [
        { 'Estado': 'Pendiente', 'Cantidad': pedidos.filter(p => p.estado === 'pendiente').length, 'Total': pedidos.filter(p => p.estado === 'pendiente').reduce((s, p) => s + (p.total || 0), 0) },
        { 'Estado': 'En Preparación', 'Cantidad': pedidos.filter(p => p.estado === 'en_preparacion').length, 'Total': pedidos.filter(p => p.estado === 'en_preparacion').reduce((s, p) => s + (p.total || 0), 0) },
        { 'Estado': 'En Camino', 'Cantidad': pedidos.filter(p => p.estado === 'asignado').length, 'Total': pedidos.filter(p => p.estado === 'asignado').reduce((s, p) => s + (p.total || 0), 0) },
        { 'Estado': 'Entregado', 'Cantidad': pedidos.filter(p => p.estado === 'entregado').length, 'Total': pedidos.filter(p => p.estado === 'entregado').reduce((s, p) => s + (p.total || 0), 0) },
        { 'Estado': 'TOTAL', 'Cantidad': pedidos.length, 'Total': pedidos.reduce((s, p) => s + (p.total || 0), 0) }
      ]

      const resumenPagos = [
        { 'Estado Pago': 'Pendiente', 'Cantidad': pedidos.filter(p => p.estado_pago === 'pendiente' || !p.estado_pago).length, 'Total': pedidos.filter(p => p.estado_pago === 'pendiente' || !p.estado_pago).reduce((s, p) => s + (p.total || 0), 0) },
        { 'Estado Pago': 'Parcial', 'Cantidad': pedidos.filter(p => p.estado_pago === 'parcial').length, 'Total': pedidos.filter(p => p.estado_pago === 'parcial').reduce((s, p) => s + (p.total || 0), 0) },
        { 'Estado Pago': 'Pagado', 'Cantidad': pedidos.filter(p => p.estado_pago === 'pagado').length, 'Total': pedidos.filter(p => p.estado_pago === 'pagado').reduce((s, p) => s + (p.total || 0), 0) }
      ]

      const fecha = new Date().toISOString().split('T')[0]

      await createMultiSheetExcel([
        {
          name: 'Info Exportación',
          data: infoFiltros,
          columnWidths: [25, 40]
        },
        {
          name: 'Pedidos',
          data: datosPedidos,
          columnWidths: [10, 12, 8, 25, 15, 35, 12, 14, 12, 16, 20, 20, 50, 12, 12, 30, 14]
        },
        {
          name: 'Detalle Items',
          data: datosItems
        },
        {
          name: 'Resumen Estados',
          data: resumenEstados
        },
        {
          name: 'Resumen Pagos',
          data: resumenPagos
        }
      ], `pedidos_${fecha}`)
    } finally {
      setExportando(false)
    }
  }

  return { exportando, exportarDatos, descargarJSON, exportarPedidosExcel }
}
