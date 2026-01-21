/**
 * ProductoService - Servicio para operaciones de productos
 */

import { BaseService } from './baseService'

class ProductoService extends BaseService {
  constructor() {
    super('productos', {
      orderBy: 'nombre',
      ascending: true
    })
  }

  /**
   * Obtiene productos con stock bajo
   * @param {number} umbral - Umbral de stock mínimo
   * @returns {Promise<Array>}
   */
  async getStockBajo(umbral = 10) {
    return this.query(async (query) => {
      return query
        .select('*')
        .lt('stock', umbral)
        .order('stock', { ascending: true })
    })
  }

  /**
   * Obtiene productos por categoría
   * @param {string} categoria
   * @returns {Promise<Array>}
   */
  async getByCategoria(categoria) {
    return this.getAll({
      filters: { categoria }
    })
  }

  /**
   * Busca productos por nombre o código
   * @param {string} termino
   * @returns {Promise<Array>}
   */
  async buscar(termino) {
    return this.query(async (query) => {
      return query
        .select('*')
        .or(`nombre.ilike.%${termino}%,codigo.ilike.%${termino}%`)
        .order('nombre')
    })
  }

  /**
   * Actualiza stock de un producto
   * @param {string} productoId
   * @param {number} cantidad - Cantidad a agregar (negativo para restar)
   * @returns {Promise<Object>}
   */
  async actualizarStock(productoId, cantidad) {
    // Primero obtener stock actual
    const producto = await this.getById(productoId)
    if (!producto) {
      throw new Error('Producto no encontrado')
    }

    const nuevoStock = (producto.stock || 0) + cantidad
    if (nuevoStock < 0) {
      throw new Error('Stock insuficiente')
    }

    return this.update(productoId, { stock: nuevoStock })
  }

  /**
   * Descuenta stock atómicamente usando RPC
   * @param {Array<{producto_id: string, cantidad: number}>} items
   * @returns {Promise<boolean>}
   */
  async descontarStock(items) {
    return this.rpc(
      'descontar_stock_atomico',
      { items: JSON.stringify(items) },
      async () => {
        // Fallback: actualizar uno por uno en transacción
        for (const item of items) {
          await this.actualizarStock(item.producto_id, -item.cantidad)
        }
        return true
      }
    )
  }

  /**
   * Restaura stock atómicamente usando RPC
   * @param {Array<{producto_id: string, cantidad: number}>} items
   * @returns {Promise<boolean>}
   */
  async restaurarStock(items) {
    return this.rpc(
      'restaurar_stock_atomico',
      { items: JSON.stringify(items) },
      async () => {
        // Fallback: actualizar uno por uno
        for (const item of items) {
          await this.actualizarStock(item.producto_id, item.cantidad)
        }
        return true
      }
    )
  }

  /**
   * Actualiza precios masivamente
   * @param {Array<{codigo: string, precio_neto?: number, imp_internos?: number, precio_final?: number}>} precios
   * @returns {Promise<{actualizados: number, errores: string[]}>}
   */
  async actualizarPreciosMasivo(precios) {
    // Intentar con RPC primero
    try {
      const result = await this.rpc('actualizar_precios_masivo', {
        precios: JSON.stringify(precios)
      })
      return result
    } catch {
      // Fallback: actualizar uno por uno
      const errores = []
      let actualizados = 0

      for (const precio of precios) {
        try {
          const { data: productos } = await this.db
            .from(this.table)
            .select('id')
            .eq('codigo', precio.codigo)
            .single()

          if (productos) {
            await this.update(productos.id, {
              precio_neto: precio.precio_neto,
              imp_internos: precio.imp_internos,
              precio_final: precio.precio_final
            })
            actualizados++
          } else {
            errores.push(`Producto ${precio.codigo} no encontrado`)
          }
        } catch (error) {
          errores.push(`Error en ${precio.codigo}: ${error.message}`)
        }
      }

      return { actualizados, errores }
    }
  }

  /**
   * Obtiene productos más vendidos
   * @param {number} limit
   * @param {Date} desde
   * @param {Date} hasta
   * @returns {Promise<Array>}
   */
  async getMasVendidos(limit = 10, desde = null, hasta = null) {
    let query = this.db
      .from('pedido_items')
      .select(`
        producto_id,
        productos:producto_id(id, nombre, codigo, precio_final),
        cantidad
      `)

    if (desde) {
      query = query.gte('created_at', desde.toISOString())
    }
    if (hasta) {
      query = query.lte('created_at', hasta.toISOString())
    }

    const { data, error } = await query

    if (error) {
      this.handleError('obtener más vendidos', error)
      return []
    }

    // Agrupar y sumar cantidades
    const agrupado = (data || []).reduce((acc, item) => {
      const id = item.producto_id
      if (!acc[id]) {
        acc[id] = {
          ...item.productos,
          cantidad_vendida: 0
        }
      }
      acc[id].cantidad_vendida += item.cantidad
      return acc
    }, {})

    return Object.values(agrupado)
      .sort((a, b) => b.cantidad_vendida - a.cantidad_vendida)
      .slice(0, limit)
  }

  /**
   * Valida datos del producto
   * @param {Object} data
   * @returns {{ valid: boolean, errors: string[] }}
   */
  validate(data) {
    const errors = []

    if (!data.nombre?.trim()) {
      errors.push('El nombre es requerido')
    }

    if (!data.codigo?.trim()) {
      errors.push('El código es requerido')
    }

    if (data.precio_final !== undefined && data.precio_final < 0) {
      errors.push('El precio no puede ser negativo')
    }

    if (data.stock !== undefined && data.stock < 0) {
      errors.push('El stock no puede ser negativo')
    }

    return {
      valid: errors.length === 0,
      errors
    }
  }
}

// Singleton
export const productoService = new ProductoService()
export default productoService
