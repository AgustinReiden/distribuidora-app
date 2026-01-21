/**
 * StockManager - Gestor de lógica de negocio para stock
 *
 * Centraliza todas las operaciones de stock:
 * - Validación de disponibilidad
 * - Reserva y liberación de stock
 * - Alertas de stock bajo
 * - Movimientos de inventario
 */

import { productoService } from '../api/productoService'
import { supabase } from '../../hooks/supabase/base'

class StockManager {
  constructor() {
    this.umbralStockBajo = 10
  }

  /**
   * Verifica si hay stock suficiente para los items
   * @param {Array<{producto_id: string, cantidad: number}>} items
   * @returns {Promise<{disponible: boolean, faltantes: Array}>}
   */
  async verificarDisponibilidad(items) {
    const faltantes = []

    for (const item of items) {
      const producto = await productoService.getById(item.producto_id)

      if (!producto) {
        faltantes.push({
          producto_id: item.producto_id,
          nombre: 'Producto no encontrado',
          solicitado: item.cantidad,
          disponible: 0
        })
        continue
      }

      if ((producto.stock || 0) < item.cantidad) {
        faltantes.push({
          producto_id: item.producto_id,
          nombre: producto.nombre,
          codigo: producto.codigo,
          solicitado: item.cantidad,
          disponible: producto.stock || 0
        })
      }
    }

    return {
      disponible: faltantes.length === 0,
      faltantes
    }
  }

  /**
   * Reserva stock para un pedido (descuenta)
   * @param {Array<{producto_id: string, cantidad: number}>} items
   * @param {Object} options
   * @returns {Promise<{success: boolean, error?: string}>}
   */
  async reservarStock(items, options = {}) {
    const { validar = true } = options

    try {
      // Validar disponibilidad primero
      if (validar) {
        const { disponible, faltantes } = await this.verificarDisponibilidad(items)

        if (!disponible) {
          const mensaje = faltantes
            .map(f => `${f.nombre}: ${f.disponible}/${f.solicitado}`)
            .join(', ')
          return {
            success: false,
            error: `Stock insuficiente: ${mensaje}`,
            faltantes
          }
        }
      }

      // Descontar stock
      await productoService.descontarStock(items)

      return { success: true }
    } catch (error) {
      return {
        success: false,
        error: error.message
      }
    }
  }

  /**
   * Libera stock reservado (restaura)
   * @param {Array<{producto_id: string, cantidad: number}>} items
   * @returns {Promise<{success: boolean, error?: string}>}
   */
  async liberarStock(items) {
    try {
      await productoService.restaurarStock(items)
      return { success: true }
    } catch (error) {
      return {
        success: false,
        error: error.message
      }
    }
  }

  /**
   * Ajusta diferencias de stock entre items originales y nuevos
   * @param {Array} itemsOriginales
   * @param {Array} itemsNuevos
   * @returns {Promise<{success: boolean}>}
   */
  async ajustarDiferencia(itemsOriginales, itemsNuevos) {
    // Crear mapa de items originales
    const mapaOriginal = new Map(
      itemsOriginales.map(i => [i.producto_id, i.cantidad])
    )

    // Crear mapa de items nuevos
    const mapaNuevo = new Map(
      itemsNuevos.map(i => [i.producto_id, i.cantidad])
    )

    const ajustes = []

    // Calcular diferencias
    // 1. Items que se quitaron o redujeron -> restaurar stock
    for (const [productoId, cantidadOriginal] of mapaOriginal) {
      const cantidadNueva = mapaNuevo.get(productoId) || 0
      const diferencia = cantidadOriginal - cantidadNueva

      if (diferencia > 0) {
        ajustes.push({
          producto_id: productoId,
          cantidad: diferencia,
          tipo: 'restaurar'
        })
      }
    }

    // 2. Items nuevos o aumentados -> descontar stock
    for (const [productoId, cantidadNueva] of mapaNuevo) {
      const cantidadOriginal = mapaOriginal.get(productoId) || 0
      const diferencia = cantidadNueva - cantidadOriginal

      if (diferencia > 0) {
        ajustes.push({
          producto_id: productoId,
          cantidad: diferencia,
          tipo: 'descontar'
        })
      }
    }

    // Aplicar ajustes
    const paraRestaurar = ajustes
      .filter(a => a.tipo === 'restaurar')
      .map(a => ({ producto_id: a.producto_id, cantidad: a.cantidad }))

    const paraDescontar = ajustes
      .filter(a => a.tipo === 'descontar')
      .map(a => ({ producto_id: a.producto_id, cantidad: a.cantidad }))

    if (paraRestaurar.length > 0) {
      await this.liberarStock(paraRestaurar)
    }

    if (paraDescontar.length > 0) {
      const result = await this.reservarStock(paraDescontar, { validar: true })
      if (!result.success) {
        // Rollback de lo restaurado
        if (paraRestaurar.length > 0) {
          await this.reservarStock(paraRestaurar, { validar: false })
        }
        return result
      }
    }

    return { success: true }
  }

  /**
   * Obtiene productos con stock bajo
   * @param {number} umbral
   * @returns {Promise<Array>}
   */
  async getProductosStockBajo(umbral = this.umbralStockBajo) {
    return productoService.getStockBajo(umbral)
  }

  /**
   * Registra una merma de stock
   * @param {Object} merma
   * @returns {Promise<Object>}
   */
  async registrarMerma(merma) {
    const { producto_id, cantidad, motivo, fecha } = merma

    try {
      // Registrar en tabla de mermas
      const { data, error } = await supabase
        .from('mermas_stock')
        .insert({
          producto_id,
          cantidad,
          motivo: motivo || 'Sin especificar',
          fecha: fecha || new Date().toISOString()
        })
        .select()
        .single()

      if (error) throw error

      // Descontar del stock
      await productoService.actualizarStock(producto_id, -cantidad)

      return data
    } catch (error) {
      console.error('Error registrando merma:', error)
      throw error
    }
  }

  /**
   * Obtiene historial de mermas
   * @param {Object} filtros
   * @returns {Promise<Array>}
   */
  async getMermas(filtros = {}) {
    let query = supabase
      .from('mermas_stock')
      .select(`
        *,
        producto:productos(id, nombre, codigo)
      `)
      .order('fecha', { ascending: false })

    if (filtros.producto_id) {
      query = query.eq('producto_id', filtros.producto_id)
    }

    if (filtros.desde) {
      query = query.gte('fecha', filtros.desde)
    }

    if (filtros.hasta) {
      query = query.lte('fecha', filtros.hasta)
    }

    const { data, error } = await query

    if (error) {
      console.error('Error obteniendo mermas:', error)
      return []
    }

    return data || []
  }

  /**
   * Obtiene resumen de movimientos de stock
   * @param {string} productoId
   * @param {Date} desde
   * @param {Date} hasta
   * @returns {Promise<Object>}
   */
  async getResumenMovimientos(productoId, desde = null, hasta = null) {
    // Obtener producto actual
    const producto = await productoService.getById(productoId)
    if (!producto) {
      return null
    }

    // Obtener ventas (items de pedidos entregados)
    let queryVentas = supabase
      .from('pedido_items')
      .select(`
        cantidad,
        pedido:pedidos(estado, fecha_creacion)
      `)
      .eq('producto_id', productoId)

    // Obtener mermas
    let queryMermas = supabase
      .from('mermas_stock')
      .select('cantidad, fecha')
      .eq('producto_id', productoId)

    if (desde) {
      queryVentas = queryVentas.gte('pedido.fecha_creacion', desde.toISOString())
      queryMermas = queryMermas.gte('fecha', desde.toISOString())
    }

    if (hasta) {
      queryVentas = queryVentas.lte('pedido.fecha_creacion', hasta.toISOString())
      queryMermas = queryMermas.lte('fecha', hasta.toISOString())
    }

    const [ventasResult, mermasResult] = await Promise.all([
      queryVentas,
      queryMermas
    ])

    const ventas = (ventasResult.data || [])
      .filter(v => v.pedido?.estado === 'entregado')
      .reduce((sum, v) => sum + v.cantidad, 0)

    const mermas = (mermasResult.data || [])
      .reduce((sum, m) => sum + m.cantidad, 0)

    return {
      producto: {
        id: producto.id,
        nombre: producto.nombre,
        codigo: producto.codigo
      },
      stockActual: producto.stock || 0,
      totalVendido: ventas,
      totalMermas: mermas,
      stockBajo: (producto.stock || 0) < this.umbralStockBajo
    }
  }

  /**
   * Configura el umbral de stock bajo
   * @param {number} umbral
   */
  setUmbralStockBajo(umbral) {
    this.umbralStockBajo = umbral
  }
}

// Singleton
export const stockManager = new StockManager()
export default stockManager
