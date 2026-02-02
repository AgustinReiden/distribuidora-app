/**
 * useCompras - Hook para gestión de compras y proveedores
 *
 * @deprecated Este hook usa useState/useEffect. Para nuevos componentes,
 * usar TanStack Query hooks de `src/hooks/queries/`:
 * - useComprasQuery() para obtener compras
 * - useRegistrarCompraMutation() para registrar
 * - useProveedoresQuery() para obtener proveedores
 * - useCrearProveedorMutation() para crear proveedor
 *
 * Migración: Reemplazar `const { compras, proveedores } = useCompras()`
 * con hooks individuales de TanStack Query
 */

import { useState, useEffect } from 'react'
import { supabase, notifyError } from './base'
import type {
  CompraDBExtended,
  CompraItemDBExtended,
  ProveedorDBExtended,
  CompraFormInputExtended,
  ProveedorFormInputExtended,
  RegistrarCompraResult,
  ResumenCompras,
  ResumenComprasPorProveedor,
  UseComprasReturnExtended,
  ProductoDB
} from '../../types'

interface CompraItemRPC {
  producto_id: string;
  cantidad: number;
  costo_unitario: number;
  subtotal: number;
}

interface RPCResult {
  success: boolean;
  compra_id: string;
  error?: string;
}

export function useCompras(): UseComprasReturnExtended {
  const [compras, setCompras] = useState<CompraDBExtended[]>([])
  const [proveedores, setProveedores] = useState<ProveedorDBExtended[]>([])
  const [loading, setLoading] = useState<boolean>(false)

  const fetchCompras = async (): Promise<void> => {
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
      setCompras((data || []) as CompraDBExtended[])
    } catch (error) {
      notifyError('Error al cargar compras: ' + (error as Error).message)
      setCompras([])
    } finally {
      setLoading(false)
    }
  }

  const fetchProveedores = async (): Promise<void> => {
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
      setProveedores((data || []) as ProveedorDBExtended[])
    } catch {
      setProveedores([])
    }
  }

  useEffect(() => {
    fetchCompras()
    fetchProveedores()
  }, [])

  const registrarCompra = async (compraData: CompraFormInputExtended): Promise<RegistrarCompraResult> => {
    const itemsParaRPC: CompraItemRPC[] = compraData.items.map(item => ({
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

    const result = data as RPCResult
    if (!result.success) {
      throw new Error(result.error || 'Error al registrar compra')
    }

    await fetchCompras()
    return { success: true, compraId: result.compra_id }
  }

  const agregarProveedor = async (proveedor: ProveedorFormInputExtended): Promise<ProveedorDBExtended> => {
    const { data, error } = await supabase
      .from('proveedores')
      .insert([{
        nombre: proveedor.nombre,
        cuit: proveedor.cuit || null,
        direccion: proveedor.direccion || null,
        latitud: proveedor.latitud || null,
        longitud: proveedor.longitud || null,
        telefono: proveedor.telefono || null,
        email: proveedor.email || null,
        contacto: proveedor.contacto || null,
        notas: proveedor.notas || null
      }])
      .select()
      .single()

    if (error) throw error
    const proveedorCreado = data as ProveedorDBExtended
    setProveedores(prev => [...prev, proveedorCreado].sort((a, b) => a.nombre.localeCompare(b.nombre)))
    return proveedorCreado
  }

  const actualizarProveedor = async (
    id: string,
    proveedor: ProveedorFormInputExtended
  ): Promise<ProveedorDBExtended> => {
    const { data, error } = await supabase
      .from('proveedores')
      .update({
        nombre: proveedor.nombre,
        cuit: proveedor.cuit || null,
        direccion: proveedor.direccion || null,
        latitud: proveedor.latitud || null,
        longitud: proveedor.longitud || null,
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
    const proveedorActualizado = data as ProveedorDBExtended
    setProveedores(prev => prev.map(p => p.id === id ? proveedorActualizado : p))
    return proveedorActualizado
  }

  const getComprasPorProducto = (productoId: string): CompraDBExtended[] => {
    const comprasConProducto: CompraDBExtended[] = []
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

  const getResumenCompras = (
    fechaDesde: string | null = null,
    fechaHasta: string | null = null
  ): ResumenCompras => {
    let comprasFiltradas = [...compras]

    if (fechaDesde) {
      comprasFiltradas = comprasFiltradas.filter(c => (c.fecha_compra || '') >= fechaDesde)
    }
    if (fechaHasta) {
      comprasFiltradas = comprasFiltradas.filter(c => (c.fecha_compra || '') <= fechaHasta)
    }

    const porProveedor: Record<string, ResumenComprasPorProveedor> = {}
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

  const anularCompra = async (compraId: string): Promise<void> => {
    const compra = compras.find(c => c.id === compraId)
    if (!compra) throw new Error('Compra no encontrada')

    // Obtener stock ACTUAL de todos los productos afectados
    const productIds = (compra.items || []).map(i => i.producto_id).filter(Boolean)
    if (productIds.length > 0) {
      const { data: productosActuales } = await supabase
        .from('productos')
        .select('id, stock')
        .in('id', productIds)

      const stockMap: Record<string, number> = Object.fromEntries(
        ((productosActuales || []) as Array<{ id: string; stock: number }>).map(p => [p.id, p.stock || 0])
      )

      // Revertir stock de cada item (restar del stock ACTUAL, no del guardado)
      for (const item of (compra.items || [])) {
        const stockActual = stockMap[item.producto_id] || 0
        const nuevoStock = stockActual - item.cantidad
        await supabase
          .from('productos')
          .update({ stock: Math.max(0, nuevoStock) })
          .eq('id', item.producto_id)
      }
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
