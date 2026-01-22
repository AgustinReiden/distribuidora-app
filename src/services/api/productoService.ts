/**
 * ProductoService - Servicio para operaciones de productos
 */

import { BaseService } from './baseService'
import type { Producto } from '../../types'

export interface StockItem {
  producto_id: string;
  cantidad: number;
}

export interface PrecioUpdate {
  codigo: string;
  precio_neto?: number;
  imp_internos?: number;
  precio_final?: number;
}

export interface ActualizarPreciosResult {
  actualizados: number;
  errores: string[];
}

export interface ProductoVendido extends Producto {
  cantidad_vendida: number;
}

export interface ValidationResult {
  valid: boolean;
  errors: string[];
}

class ProductoService extends BaseService<Producto> {
  constructor() {
    super('productos', {
      orderBy: 'nombre',
      ascending: true
    })
  }

  /**
   * Obtiene productos con stock bajo
   */
  async getStockBajo(umbral = 10): Promise<Producto[]> {
    return this.query(async (query) => {
      return query
        .select('*')
        .lt('stock', umbral)
        .order('stock', { ascending: true })
    }) as Promise<Producto[]>
  }

  /**
   * Obtiene productos por categoría
   */
  async getByCategoria(categoria: string): Promise<Producto[]> {
    return this.getAll({
      filters: { categoria }
    })
  }

  /**
   * Busca productos por nombre o código
   */
  async buscar(termino: string): Promise<Producto[]> {
    return this.query(async (query) => {
      return query
        .select('*')
        .or(`nombre.ilike.%${termino}%,codigo.ilike.%${termino}%`)
        .order('nombre')
    }) as Promise<Producto[]>
  }

  /**
   * Actualiza stock de un producto
   */
  async actualizarStock(productoId: string, cantidad: number): Promise<Producto | null> {
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
   */
  async descontarStock(items: StockItem[]): Promise<boolean> {
    return this.rpc<boolean>(
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
   */
  async restaurarStock(items: StockItem[]): Promise<boolean> {
    return this.rpc<boolean>(
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
   */
  async actualizarPreciosMasivo(precios: PrecioUpdate[]): Promise<ActualizarPreciosResult> {
    // Intentar con RPC primero
    try {
      const result = await this.rpc<ActualizarPreciosResult>('actualizar_precios_masivo', {
        precios: JSON.stringify(precios)
      })
      return result
    } catch {
      // Fallback: actualizar uno por uno
      const errores: string[] = []
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
            } as Partial<Producto>)
            actualizados++
          } else {
            errores.push(`Producto ${precio.codigo} no encontrado`)
          }
        } catch (error) {
          errores.push(`Error en ${precio.codigo}: ${(error as Error).message}`)
        }
      }

      return { actualizados, errores }
    }
  }

  /**
   * Obtiene productos más vendidos
   */
  async getMasVendidos(limit = 10, desde: Date | null = null, hasta: Date | null = null): Promise<ProductoVendido[]> {
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
      const id = item.producto_id as string
      const producto = item.productos as unknown as Producto
      const cantidad = item.cantidad as number
      if (!acc[id]) {
        acc[id] = {
          ...producto,
          cantidad_vendida: 0
        }
      }
      acc[id].cantidad_vendida += cantidad
      return acc
    }, {} as Record<string, ProductoVendido>)

    return Object.values(agrupado)
      .sort((a, b) => b.cantidad_vendida - a.cantidad_vendida)
      .slice(0, limit)
  }

  /**
   * Valida datos del producto
   */
  validate(data: Partial<Producto> & { precio_final?: number }): ValidationResult {
    const errors: string[] = []

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
