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
import { logger } from '../../utils/logger'
import type { Producto } from '../../types'

export interface StockItem {
  producto_id: string;
  cantidad: number;
}

export interface StockFaltante {
  producto_id: string;
  nombre: string;
  codigo?: string;
  solicitado: number;
  disponible: number;
}

export interface DisponibilidadResult {
  disponible: boolean;
  faltantes: StockFaltante[];
}

export interface StockOperationResult {
  success: boolean;
  error?: string;
  faltantes?: StockFaltante[];
}

export interface MermaInput {
  producto_id: string;
  cantidad: number;
  motivo?: string;
  fecha?: string;
}

export interface MermaFiltros {
  producto_id?: string;
  desde?: string;
  hasta?: string;
}

export interface Merma {
  id: string;
  producto_id: string;
  cantidad: number;
  motivo: string;
  fecha: string;
  producto?: {
    id: string;
    nombre: string;
    codigo: string;
  };
}

export interface ResumenMovimientos {
  producto: {
    id: string;
    nombre: string;
    codigo?: string;
  };
  stockActual: number;
  totalVendido: number;
  totalMermas: number;
  stockBajo: boolean;
}

interface StockAjuste {
  producto_id: string;
  cantidad: number;
  tipo: 'restaurar' | 'descontar';
}

class StockManager {
  private umbralStockBajo: number;

  constructor() {
    this.umbralStockBajo = 10
  }

  /**
   * Verifica si hay stock suficiente para los items
   */
  async verificarDisponibilidad(items: StockItem[]): Promise<DisponibilidadResult> {
    const faltantes: StockFaltante[] = []

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
   */
  async reservarStock(items: StockItem[], options: { validar?: boolean } = {}): Promise<StockOperationResult> {
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
        error: (error as Error).message
      }
    }
  }

  /**
   * Libera stock reservado (restaura)
   */
  async liberarStock(items: StockItem[]): Promise<StockOperationResult> {
    try {
      await productoService.restaurarStock(items)
      return { success: true }
    } catch (error) {
      return {
        success: false,
        error: (error as Error).message
      }
    }
  }

  /**
   * Ajusta diferencias de stock entre items originales y nuevos
   */
  async ajustarDiferencia(itemsOriginales: StockItem[], itemsNuevos: StockItem[]): Promise<StockOperationResult> {
    // Crear mapa de items originales
    const mapaOriginal = new Map(
      itemsOriginales.map(i => [i.producto_id, i.cantidad])
    )

    // Crear mapa de items nuevos
    const mapaNuevo = new Map(
      itemsNuevos.map(i => [i.producto_id, i.cantidad])
    )

    const ajustes: StockAjuste[] = []

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
   */
  async getProductosStockBajo(umbral = this.umbralStockBajo): Promise<Producto[]> {
    return productoService.getStockBajo(umbral)
  }

  /**
   * Registra una merma de stock.
   *
   * Orden de operaciones (para consistencia):
   * 1. Descontar stock atómicamente (con FOR UPDATE lock via RPC)
   * 2. Insertar registro de merma
   *
   * Si el descuento falla (stock insuficiente), no se crea registro huérfano.
   * Si el INSERT falla después del descuento, se restaura el stock.
   */
  async registrarMerma(merma: MermaInput): Promise<Merma> {
    const { producto_id, cantidad, motivo, fecha } = merma

    try {
      // Paso 1: Descontar stock atómicamente PRIMERO
      // Si falla por stock insuficiente, no se crea merma huérfana
      await productoService.actualizarStock(producto_id, -cantidad)

      // Paso 2: Registrar en tabla de mermas
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

      if (error) {
        // Rollback: restaurar stock si falla el INSERT de merma
        logger.error('Error insertando merma, restaurando stock:', error)
        try {
          await productoService.actualizarStock(producto_id, cantidad)
        } catch (rollbackError) {
          logger.error('Error en rollback de stock tras fallo de merma:', rollbackError)
        }
        throw error
      }

      return data as Merma
    } catch (error) {
      logger.error('Error registrando merma:', error)
      throw error
    }
  }

  /**
   * Obtiene historial de mermas
   */
  async getMermas(filtros: MermaFiltros = {}): Promise<Merma[]> {
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
      logger.error('Error obteniendo mermas:', error)
      return []
    }

    return (data || []) as Merma[]
  }

  /**
   * Obtiene resumen de movimientos de stock
   */
  async getResumenMovimientos(productoId: string, desde: Date | null = null, hasta: Date | null = null): Promise<ResumenMovimientos | null> {
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

    const ventasData = ventasResult.data || []
    const ventas = ventasData
      .filter((v) => {
        const item = v as { pedido?: { estado?: string } }
        return item.pedido?.estado === 'entregado'
      })
      .reduce((sum, v) => {
        const item = v as { cantidad: number }
        return sum + item.cantidad
      }, 0)

    const mermasData = mermasResult.data || []
    const mermas = mermasData.reduce((sum, m) => {
      const item = m as { cantidad: number }
      return sum + item.cantidad
    }, 0)

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
   */
  setUmbralStockBajo(umbral: number): void {
    this.umbralStockBajo = umbral
  }
}

// Singleton
export const stockManager = new StockManager()
export default stockManager
