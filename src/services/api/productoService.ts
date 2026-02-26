/**
 * ProductoService - Servicio para operaciones de productos
 */

import { BaseService } from './baseService'
import { escapePostgrestFilter } from '../../utils/sanitize'
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
   * Busca productos por nombre o código.
   * Sanitiza el término de búsqueda para prevenir inyección PostgREST.
   */
  async buscar(termino: string): Promise<Producto[]> {
    const safe = escapePostgrestFilter(termino)
    if (!safe) return []

    return this.query(async (query) => {
      return query
        .select('*')
        .or(`nombre.ilike.%${safe}%,codigo.ilike.%${safe}%`)
        .order('nombre')
    }) as Promise<Producto[]>
  }

  /**
   * Actualiza stock de un producto de forma atómica usando RPCs existentes.
   *
   * Usa `descontar_stock_atomico` o `restaurar_stock_atomico` con FOR UPDATE
   * para prevenir race conditions en operaciones concurrentes.
   *
   * @param productoId - ID del producto
   * @param cantidad - Positivo para sumar, negativo para restar
   */
  async actualizarStock(productoId: string, cantidad: number): Promise<Producto | null> {
    if (cantidad === 0) {
      return this.getById(productoId)
    }

    const items = [{ producto_id: productoId, cantidad: Math.abs(cantidad) }]

    if (cantidad < 0) {
      // Descontar stock atómicamente (incluye validación de stock suficiente)
      await this.descontarStock(items)
    } else {
      // Restaurar/agregar stock atómicamente
      await this.restaurarStock(items)
    }

    // Invalidar cache y retornar producto actualizado
    this.invalidateCache()
    return this.getById(productoId)
  }

  /**
   * Descuenta stock atómicamente usando RPC con FOR UPDATE lock.
   * Valida stock suficiente para todos los items antes de descontar.
   */
  async descontarStock(items: StockItem[]): Promise<{ success: boolean; errores?: string[] }> {
    const result = await this.rpc<{ success: boolean; errores?: string[] }>(
      'descontar_stock_atomico',
      { p_items: items }
    )

    if (!result.success) {
      throw new Error(result.errores?.join(', ') || 'Error descontando stock')
    }

    return result
  }

  /**
   * Restaura stock atómicamente usando RPC.
   * Valida que las cantidades sean positivas.
   */
  async restaurarStock(items: StockItem[]): Promise<{ success: boolean; errores?: string[] }> {
    const result = await this.rpc<{ success: boolean; errores?: string[] }>(
      'restaurar_stock_atomico',
      { p_items: items }
    )

    if (!result.success) {
      throw new Error(result.errores?.join(', ') || 'Error restaurando stock')
    }

    return result
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
