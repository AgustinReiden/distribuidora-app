/**
 * Analytics Export Service
 *
 * Genera datasets denormalizados listos para Power BI.
 * Cada función fetch retorna un array de objetos planos (una fila = un record).
 */
import { supabase } from '../lib/supabase'
import type { SheetConfig } from '../utils/excel'
import { calculateMarketBasket } from '../utils/marketBasket'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatDate(iso: string) {
  const d = new Date(iso)
  return {
    fecha: d.toLocaleDateString('es-AR'),
    año: d.getFullYear(),
    mes: d.getMonth() + 1,
    mes_nombre: d.toLocaleDateString('es-AR', { month: 'long' }),
    dia_semana: d.toLocaleDateString('es-AR', { weekday: 'long' }),
  }
}

function safe(val: unknown, fallback: string | number = ''): string | number {
  return val == null ? fallback : (val as string | number)
}

// ---------------------------------------------------------------------------
// Dataset 1: Ventas Detallado (fact table)
// ---------------------------------------------------------------------------

export async function fetchVentasDetallado(
  desde: string,
  hasta: string
): Promise<Record<string, unknown>[]> {
  const { data: pedidos, error } = await supabase
    .from('pedidos')
    .select(`
      id,
      created_at,
      estado,
      estado_pago,
      forma_pago,
      total,
      usuario_id,
      transportista_id,
      cliente:clientes(id, nombre_fantasia, razon_social, zona, cuit),
      items:pedido_items(
        id,
        cantidad,
        precio_unitario,
        subtotal,
        producto:productos(id, nombre, codigo, categoria, costo_con_iva)
      )
    `)
    .gte('created_at', `${desde}T00:00:00`)
    .lte('created_at', `${hasta}T23:59:59`)
    .order('created_at', { ascending: false })

  if (error) throw new Error(`Error cargando ventas: ${error.message}`)

  // Fetch perfiles separately (FK join pedidos->perfiles doesn't work reliably)
  const perfilIds = new Set<string>()
  for (const p of pedidos || []) {
    if (p.usuario_id) perfilIds.add(p.usuario_id as string)
    if (p.transportista_id) perfilIds.add(p.transportista_id as string)
  }

  let perfilesMap: Record<string, string> = {}
  if (perfilIds.size > 0) {
    const { data: perfiles } = await supabase
      .from('perfiles')
      .select('id, nombre')
      .in('id', Array.from(perfilIds))
    if (perfiles) {
      perfilesMap = Object.fromEntries(perfiles.map(p => [p.id, p.nombre]))
    }
  }

  const rows: Record<string, unknown>[] = []

  for (const p of pedidos || []) {
    const cliente = p.cliente as unknown as Record<string, unknown> | null
    const items = (p.items || []) as Array<Record<string, unknown>>

    for (const item of items) {
      const producto = item.producto as Record<string, unknown> | null
      const costoUnitario = Number(producto?.costo_con_iva || 0)
      const precioUnitario = Number(item.precio_unitario || 0)
      const cantidad = Number(item.cantidad || 0)
      const subtotal = Number(item.subtotal || precioUnitario * cantidad)
      const costoTotal = costoUnitario * cantidad
      const margenTotal = subtotal - costoTotal

      const dt = formatDate(p.created_at)

      rows.push({
        pedido_id: p.id,
        fecha: dt.fecha,
        año: dt.año,
        mes: dt.mes,
        mes_nombre: dt.mes_nombre,
        dia_semana: dt.dia_semana,
        cliente_id: safe(cliente?.id),
        cliente_nombre: safe(cliente?.nombre_fantasia),
        cliente_zona: safe(cliente?.zona),
        cliente_cuit: safe(cliente?.cuit),
        producto_id: safe(producto?.id),
        producto_nombre: safe(producto?.nombre),
        producto_codigo: safe(producto?.codigo),
        producto_categoria: safe(producto?.categoria),
        cantidad,
        precio_unitario: precioUnitario,
        subtotal,
        costo_unitario: costoUnitario,
        costo_total: costoTotal,
        margen_unitario: precioUnitario - costoUnitario,
        margen_total: margenTotal,
        margen_porcentaje: subtotal > 0 ? Number(((margenTotal / subtotal) * 100).toFixed(2)) : 0,
        estado_pedido: p.estado,
        estado_pago: safe(p.estado_pago),
        forma_pago: safe(p.forma_pago),
        preventista: perfilesMap[p.usuario_id as string] || 'N/A',
        transportista: perfilesMap[p.transportista_id as string] || 'Sin asignar',
      })
    }
  }

  return rows
}

// ---------------------------------------------------------------------------
// Dataset 2: Clientes (dimension)
// ---------------------------------------------------------------------------

export async function fetchClientesDimension(
  desde: string,
  hasta: string
): Promise<Record<string, unknown>[]> {
  const [clientesRes, pedidosRes] = await Promise.all([
    supabase.from('clientes').select('*'),
    supabase
      .from('pedidos')
      .select('id, cliente_id, total, created_at')
      .gte('created_at', `${desde}T00:00:00`)
      .lte('created_at', `${hasta}T23:59:59`),
  ])

  if (clientesRes.error) throw new Error(`Error cargando clientes: ${clientesRes.error.message}`)

  const pedidosPorCliente = new Map<string, Array<{ total: number; created_at: string }>>()
  for (const p of pedidosRes.data || []) {
    const arr = pedidosPorCliente.get(p.cliente_id) || []
    arr.push({ total: p.total, created_at: p.created_at })
    pedidosPorCliente.set(p.cliente_id, arr)
  }

  const now = Date.now()

  return (clientesRes.data || []).map(c => {
    const pedidos = pedidosPorCliente.get(c.id) || []
    const totalCompras = pedidos.reduce((s, p) => s + (p.total || 0), 0)
    const cantidadPedidos = pedidos.length

    let diasDesdeUltimo: number | null = null
    if (pedidos.length > 0) {
      const ultimo = Math.max(...pedidos.map(p => new Date(p.created_at).getTime()))
      diasDesdeUltimo = Math.floor((now - ultimo) / 86400000)
    }

    const segmento = totalCompras > 100000 ? 'Alto' : totalCompras > 50000 ? 'Medio' : 'Bajo'
    const actividad = diasDesdeUltimo === null
      ? 'Nuevo'
      : diasDesdeUltimo > 90
        ? 'Inactivo'
        : diasDesdeUltimo > 30
          ? 'En riesgo'
          : 'Activo'

    return {
      id: c.id,
      nombre_fantasia: safe(c.nombre_fantasia),
      razon_social: safe(c.razon_social),
      cuit: safe(c.cuit),
      direccion: safe(c.direccion),
      telefono: safe(c.telefono),
      email: safe(c.email),
      zona: safe(c.zona),
      latitud: c.latitud ?? '',
      longitud: c.longitud ?? '',
      limite_credito: c.limite_credito ?? 0,
      saldo_cuenta: c.saldo_cuenta ?? 0,
      activo: c.activo !== false ? 'Si' : 'No',
      total_compras: totalCompras,
      cantidad_pedidos: cantidadPedidos,
      ticket_promedio: cantidadPedidos > 0 ? Number((totalCompras / cantidadPedidos).toFixed(2)) : 0,
      dias_desde_ultimo_pedido: diasDesdeUltimo ?? 'N/A',
      segmento_valor: segmento,
      estado_actividad: actividad,
    }
  })
}

// ---------------------------------------------------------------------------
// Dataset 3: Productos (dimension)
// ---------------------------------------------------------------------------

export async function fetchProductosDimension(
  desde: string,
  hasta: string
): Promise<Record<string, unknown>[]> {
  const [productosRes, itemsRes] = await Promise.all([
    supabase.from('productos').select('*'),
    supabase
      .from('pedido_items')
      .select('producto_id, cantidad, precio_unitario, subtotal, pedido:pedidos!inner(created_at)')
      .gte('pedido.created_at', `${desde}T00:00:00`)
      .lte('pedido.created_at', `${hasta}T23:59:59`),
  ])

  if (productosRes.error) throw new Error(`Error cargando productos: ${productosRes.error.message}`)

  const ventasPorProducto = new Map<string, { cantidad: number; ingresos: number; dias: Set<string> }>()
  for (const item of itemsRes.data || []) {
    const existing = ventasPorProducto.get(item.producto_id) || { cantidad: 0, ingresos: 0, dias: new Set<string>() }
    existing.cantidad += item.cantidad || 0
    existing.ingresos += item.subtotal || (item.precio_unitario || 0) * (item.cantidad || 0)
    const pedido = item.pedido as unknown as Record<string, unknown> | null
    if (pedido?.created_at) {
      existing.dias.add(String(pedido.created_at).split('T')[0])
    }
    ventasPorProducto.set(item.producto_id, existing)
  }

  return (productosRes.data || []).map(p => {
    const ventas = ventasPorProducto.get(p.id) || { cantidad: 0, ingresos: 0, dias: new Set() }
    const costoUnitario = Number(p.costo_con_iva || 0)
    const costoTotal = costoUnitario * ventas.cantidad
    const margenTotal = ventas.ingresos - costoTotal

    const diasConVentas = ventas.dias.size
    const rotacion = diasConVentas > 0 ? ventas.cantidad / diasConVentas : 0
    const stockDias = rotacion > 0 ? (p.stock || 0) / rotacion : 999

    return {
      id: p.id,
      codigo: safe(p.codigo),
      nombre: p.nombre,
      categoria: safe(p.categoria),
      precio: p.precio,
      stock: p.stock ?? 0,
      stock_minimo: p.stock_minimo ?? 0,
      costo_sin_iva: p.costo_sin_iva ?? 0,
      costo_con_iva: p.costo_con_iva ?? 0,
      activo: p.activo !== false ? 'Si' : 'No',
      total_vendido: ventas.cantidad,
      total_ingresos: Number(ventas.ingresos.toFixed(2)),
      margen_total: Number(margenTotal.toFixed(2)),
      margen_porcentaje: ventas.ingresos > 0 ? Number(((margenTotal / ventas.ingresos) * 100).toFixed(2)) : 0,
      rotacion_diaria: Number(rotacion.toFixed(2)),
      stock_dias: stockDias >= 999 ? 'N/A' : Number(stockDias.toFixed(1)),
      estado_stock: (p.stock || 0) <= (p.stock_minimo || 0) ? 'Bajo' : 'OK',
      velocidad_venta: rotacion > 10 ? 'Rapida' : rotacion > 3 ? 'Media' : 'Lenta',
    }
  })
}

// ---------------------------------------------------------------------------
// Dataset 4: Compras (fact)
// ---------------------------------------------------------------------------

export async function fetchComprasFact(
  desde: string,
  hasta: string
): Promise<Record<string, unknown>[]> {
  const { data, error } = await supabase
    .from('compras')
    .select(`
      id,
      created_at,
      total,
      estado,
      proveedor:proveedores(nombre, cuit),
      items:compra_items(
        cantidad,
        costo_unitario,
        subtotal,
        producto:productos(nombre, codigo, categoria)
      )
    `)
    .gte('created_at', `${desde}T00:00:00`)
    .lte('created_at', `${hasta}T23:59:59`)
    .order('created_at', { ascending: false })

  if (error) throw new Error(`Error cargando compras: ${error.message}`)

  const rows: Record<string, unknown>[] = []

  for (const compra of data || []) {
    const proveedor = compra.proveedor as unknown as Record<string, unknown> | null
    const items = (compra.items || []) as Array<Record<string, unknown>>

    for (const item of items) {
      const producto = item.producto as Record<string, unknown> | null
      rows.push({
        compra_id: compra.id,
        fecha: new Date(compra.created_at).toLocaleDateString('es-AR'),
        proveedor_nombre: safe(proveedor?.nombre),
        proveedor_cuit: safe(proveedor?.cuit),
        producto_nombre: safe(producto?.nombre),
        producto_codigo: safe(producto?.codigo),
        producto_categoria: safe(producto?.categoria),
        cantidad: item.cantidad,
        costo_unitario: item.costo_unitario,
        subtotal: item.subtotal,
        estado: safe(compra.estado),
      })
    }
  }

  return rows
}

// ---------------------------------------------------------------------------
// Dataset 5: Cobranzas (fact)
// ---------------------------------------------------------------------------

export async function fetchCobranzasFact(
  desde: string,
  hasta: string
): Promise<Record<string, unknown>[]> {
  const { data, error } = await supabase
    .from('pagos')
    .select(`
      id,
      created_at,
      monto,
      forma_pago,
      referencia,
      notas,
      cliente:clientes(id, nombre_fantasia, zona),
      pedido_id
    `)
    .gte('created_at', `${desde}T00:00:00`)
    .lte('created_at', `${hasta}T23:59:59`)
    .order('created_at', { ascending: false })

  if (error) throw new Error(`Error cargando cobranzas: ${error.message}`)

  return (data || []).map(pago => {
    const cliente = pago.cliente as unknown as Record<string, unknown> | null
    return {
      pago_id: pago.id,
      fecha: new Date(pago.created_at).toLocaleDateString('es-AR'),
      cliente_id: safe(cliente?.id),
      cliente_nombre: safe(cliente?.nombre_fantasia),
      cliente_zona: safe(cliente?.zona),
      monto: pago.monto,
      forma_pago: safe(pago.forma_pago),
      referencia: safe(pago.referencia),
      notas: safe(pago.notas),
      pedido_asociado: safe(pago.pedido_id, 'N/A'),
    }
  })
}

// ---------------------------------------------------------------------------
// Dataset 6: Canasta de Productos (market basket)
// ---------------------------------------------------------------------------

export async function fetchCanastaProductos(
  desde: string,
  hasta: string
): Promise<Record<string, unknown>[]> {
  const { data: pedidos, error } = await supabase
    .from('pedidos')
    .select('id, items:pedido_items(producto_id)')
    .gte('created_at', `${desde}T00:00:00`)
    .lte('created_at', `${hasta}T23:59:59`)

  if (error) throw new Error(`Error cargando pedidos para canasta: ${error.message}`)
  if (!pedidos || pedidos.length === 0) return []

  const pairs = calculateMarketBasket(
    pedidos.map(p => ({ items: (p.items || []) as Array<{ producto_id: string }> })),
    2
  )

  if (pairs.length === 0) return []

  // Enriquecer con nombres
  const productIds = new Set<string>()
  pairs.forEach(p => { productIds.add(p.producto_a); productIds.add(p.producto_b) })

  const { data: productos } = await supabase
    .from('productos')
    .select('id, nombre, codigo')
    .in('id', Array.from(productIds))

  const names = new Map((productos || []).map(p => [p.id, p]))

  return pairs.map(pair => ({
    producto_a_nombre: names.get(pair.producto_a)?.nombre || 'Desconocido',
    producto_a_codigo: names.get(pair.producto_a)?.codigo || '',
    producto_b_nombre: names.get(pair.producto_b)?.nombre || 'Desconocido',
    producto_b_codigo: names.get(pair.producto_b)?.codigo || '',
    veces_comprados_juntos: pair.frecuencia,
    confianza_porcentaje: Number(pair.confianza.toFixed(1)),
    lift: Number(pair.lift.toFixed(2)),
    recomendacion: pair.lift > 1.5 ? 'Fuerte' : pair.lift > 1 ? 'Moderada' : 'Debil',
  }))
}

// ---------------------------------------------------------------------------
// Orchestrator: exportarBI
// ---------------------------------------------------------------------------

export async function exportarBI(desde: string, hasta: string): Promise<void> {
  const [ventas, clientes, productos, compras, cobranzas, canasta] = await Promise.all([
    fetchVentasDetallado(desde, hasta),
    fetchClientesDimension(desde, hasta),
    fetchProductosDimension(desde, hasta),
    fetchComprasFact(desde, hasta),
    fetchCobranzasFact(desde, hasta),
    fetchCanastaProductos(desde, hasta),
  ])

  const info: Record<string, unknown>[] = [
    { Campo: 'Fecha de exportacion', Valor: new Date().toLocaleString('es-AR') },
    { Campo: 'Periodo desde', Valor: desde },
    { Campo: 'Periodo hasta', Valor: hasta },
    { Campo: 'Filas en Ventas_Detallado', Valor: ventas.length },
    { Campo: 'Total Clientes', Valor: clientes.length },
    { Campo: 'Total Productos', Valor: productos.length },
    { Campo: 'Filas en Compras', Valor: compras.length },
    { Campo: 'Filas en Cobranzas', Valor: cobranzas.length },
    { Campo: 'Pares en Canasta', Valor: canasta.length },
    { Campo: '', Valor: '' },
    { Campo: 'Power BI - Paso 1', Valor: 'Obtener datos > Excel > seleccionar este archivo' },
    { Campo: 'Power BI - Paso 2', Valor: 'Importar todas las hojas excepto Info_Exportacion' },
    { Campo: 'Power BI - Paso 3', Valor: 'Crear relacion: Ventas_Detallado.cliente_id -> Clientes.id' },
    { Campo: 'Power BI - Paso 4', Valor: 'Crear relacion: Ventas_Detallado.producto_id -> Productos.id' },
    { Campo: 'Power BI - Paso 5', Valor: 'Usar Clientes.latitud/longitud para mapa de calor' },
  ]

  const sheets: SheetConfig[] = [
    { name: 'Info_Exportacion', data: info, columnWidths: [30, 70] },
    { name: 'Ventas_Detallado', data: ventas },
    { name: 'Clientes', data: clientes },
    { name: 'Productos', data: productos },
    { name: 'Compras', data: compras },
    { name: 'Cobranzas', data: cobranzas },
    { name: 'Canasta_Productos', data: canasta },
  ]

  const filename = `BI_Export_${desde}_${hasta}`
  const { createMultiSheetExcel } = await import('../utils/excel')
  await createMultiSheetExcel(sheets, filename)
}
