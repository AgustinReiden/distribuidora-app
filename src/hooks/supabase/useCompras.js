import { useState, useEffect } from 'react'
import { supabase, notifyError } from './base'

export function useCompras() {
  const [compras, setCompras] = useState([])
  const [proveedores, setProveedores] = useState([])
  const [loading, setLoading] = useState(false)

  const fetchCompras = async () => {
    setLoading(true)
    try {
      const { data, error } = await supabase
        .from('compras')
        .select(`
          *,
          proveedor:proveedores(*),
          items:compra_items(*, producto:productos(*)),
          usuario:perfiles(id, nombre)
        `)
        .order('created_at', { ascending: false })

      if (error) {
        if (error.message.includes('does not exist')) {
          setCompras([])
          return
        }
        throw error
      }
      setCompras(data || [])
    } catch (error) {
      notifyError('Error al cargar compras: ' + error.message)
      setCompras([])
    } finally {
      setLoading(false)
    }
  }

  const fetchProveedores = async () => {
    try {
      const { data, error } = await supabase
        .from('proveedores')
        .select('*')
        .eq('activo', true)
        .order('nombre')

      if (error) {
        if (error.message.includes('does not exist')) {
          setProveedores([])
          return
        }
        throw error
      }
      setProveedores(data || [])
    } catch {
      setProveedores([])
    }
  }

  useEffect(() => {
    fetchCompras()
    fetchProveedores()
  }, [])

  const registrarCompra = async (compraData) => {
    const itemsParaRPC = compraData.items.map(item => ({
      producto_id: item.productoId,
      cantidad: item.cantidad,
      costo_unitario: item.costoUnitario || 0,
      subtotal: item.subtotal || (item.cantidad * (item.costoUnitario || 0))
    }))

    const { data, error } = await supabase.rpc('registrar_compra_completa', {
      p_proveedor_id: compraData.proveedorId || null,
      p_proveedor_nombre: compraData.proveedorNombre || null,
      p_numero_factura: compraData.numeroFactura || null,
      p_fecha_compra: compraData.fechaCompra || new Date().toISOString().split('T')[0],
      p_subtotal: compraData.subtotal || 0,
      p_iva: compraData.iva || 0,
      p_otros_impuestos: compraData.otrosImpuestos || 0,
      p_total: compraData.total || 0,
      p_forma_pago: compraData.formaPago || 'efectivo',
      p_notas: compraData.notas || null,
      p_usuario_id: compraData.usuarioId || null,
      p_items: itemsParaRPC
    })

    if (error) throw error

    if (!data.success) {
      throw new Error(data.error || 'Error al registrar compra')
    }

    await fetchCompras()
    return { success: true, compraId: data.compra_id }
  }

  const agregarProveedor = async (proveedor) => {
    const { data, error } = await supabase
      .from('proveedores')
      .insert([{
        nombre: proveedor.nombre,
        cuit: proveedor.cuit || null,
        direccion: proveedor.direccion || null,
        telefono: proveedor.telefono || null,
        email: proveedor.email || null,
        contacto: proveedor.contacto || null,
        notas: proveedor.notas || null
      }])
      .select()
      .single()

    if (error) throw error
    setProveedores(prev => [...prev, data].sort((a, b) => a.nombre.localeCompare(b.nombre)))
    return data
  }

  const actualizarProveedor = async (id, proveedor) => {
    const { data, error } = await supabase
      .from('proveedores')
      .update({
        nombre: proveedor.nombre,
        cuit: proveedor.cuit || null,
        direccion: proveedor.direccion || null,
        telefono: proveedor.telefono || null,
        email: proveedor.email || null,
        contacto: proveedor.contacto || null,
        notas: proveedor.notas || null,
        activo: proveedor.activo !== undefined ? proveedor.activo : true
      })
      .eq('id', id)
      .select()
      .single()

    if (error) throw error
    setProveedores(prev => prev.map(p => p.id === id ? data : p))
    return data
  }

  const getComprasPorProducto = (productoId) => {
    const comprasConProducto = []
    compras.forEach(compra => {
      const itemsDelProducto = compra.items?.filter(i => i.producto_id === productoId) || []
      if (itemsDelProducto.length > 0) {
        comprasConProducto.push({
          ...compra,
          items: itemsDelProducto
        })
      }
    })
    return comprasConProducto
  }

  const getResumenCompras = (fechaDesde = null, fechaHasta = null) => {
    let comprasFiltradas = [...compras]

    if (fechaDesde) {
      comprasFiltradas = comprasFiltradas.filter(c => c.fecha_compra >= fechaDesde)
    }
    if (fechaHasta) {
      comprasFiltradas = comprasFiltradas.filter(c => c.fecha_compra <= fechaHasta)
    }

    const porProveedor = {}
    comprasFiltradas.forEach(c => {
      const proveedorNombre = c.proveedor?.nombre || c.proveedor_nombre || 'Sin proveedor'
      if (!porProveedor[proveedorNombre]) {
        porProveedor[proveedorNombre] = { total: 0, compras: 0, unidades: 0 }
      }
      porProveedor[proveedorNombre].total += c.total || 0
      porProveedor[proveedorNombre].compras += 1
      porProveedor[proveedorNombre].unidades += (c.items || []).reduce((s, i) => s + i.cantidad, 0)
    })

    return {
      totalMonto: comprasFiltradas.reduce((sum, c) => sum + (c.total || 0), 0),
      totalCompras: comprasFiltradas.length,
      totalUnidades: comprasFiltradas.reduce((sum, c) => sum + (c.items || []).reduce((s, i) => s + i.cantidad, 0), 0),
      porProveedor
    }
  }

  const anularCompra = async (compraId) => {
    const compra = compras.find(c => c.id === compraId)
    if (!compra) throw new Error('Compra no encontrada')

    // Revertir stock de cada item
    for (const item of (compra.items || [])) {
      const nuevoStock = (item.stock_nuevo || 0) - item.cantidad
      await supabase
        .from('productos')
        .update({ stock: Math.max(0, nuevoStock) })
        .eq('id', item.producto_id)
    }

    // Marcar compra como cancelada
    const { error } = await supabase
      .from('compras')
      .update({ estado: 'cancelada' })
      .eq('id', compraId)

    if (error) throw error
    await fetchCompras()
  }

  return {
    compras,
    proveedores,
    loading,
    registrarCompra,
    agregarProveedor,
    actualizarProveedor,
    getComprasPorProducto,
    getResumenCompras,
    anularCompra,
    refetch: fetchCompras,
    refetchProveedores: fetchProveedores
  }
}
