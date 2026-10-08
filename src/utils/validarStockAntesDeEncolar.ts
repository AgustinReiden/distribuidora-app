/**
 * Valida que haya stock suficiente para un pedido offline ANTES de encolarlo,
 * descontando lo que ya reservan otros pedidos offline pendientes de
 * sincronizar. Usado por `guardarPedidoOffline` y por la validación previa al
 * replay (`sincronizarPedidos`), ambos en useOfflineSync.ts.
 *
 * Compara por PRODUCTO, no por línea, con el criterio del servidor (ver
 * `cantidadesQueDescuentanStock`): un producto comprado y regalado suma las dos.
 */
import { cantidadesQueDescuentanStock, type RenglonDeStock } from './stockDelPedido'

export interface StockValidationItem extends RenglonDeStock {
  productoId: string;
  cantidad: number;
  nombre?: string;
}

export interface ProductoStock {
  id: string;
  nombre: string;
  stock: number;
}

export interface PedidoPendienteStock {
  items?: RenglonDeStock[];
}

export interface ItemSinStock {
  productoId: string;
  nombre: string;
  solicitado: number;
  disponible: number;
}

export interface StockSnapshot {
  [productoId: string]: {
    stockAlMomento: number;
    reservadoOffline: number;
    disponible: number;
  };
}

export interface ValidacionStockResult {
  itemsSinStock: ItemSinStock[];
  stockSnapshot: StockSnapshot;
}

export function validarStockAntesDeEncolar(
  items: StockValidationItem[],
  productos: ProductoStock[],
  pedidosPendientes: PedidoPendienteStock[] = []
): ValidacionStockResult {
  const itemsSinStock: ItemSinStock[] = []
  const stockSnapshot: StockSnapshot = {}

  // Stock reservado por pedidos offline pendientes (misma regla que el pedido nuevo)
  const stockReservado = cantidadesQueDescuentanStock(
    pedidosPendientes.flatMap(pedido => pedido.items ?? [])
  )
  // Lo que ESTE pedido descuenta, sumado por producto
  const solicitadoPorProducto = cantidadesQueDescuentanStock(items)

  // Un renglón por producto, en el orden en que aparece en el pedido
  const vistos = new Set<string>()
  for (const item of items) {
    const id = String(item.productoId)
    if (vistos.has(id)) continue
    vistos.add(id)

    const producto = productos.find(p => String(p.id) === id)
    if (!producto) continue

    const stockActual = producto.stock || 0
    const reservado = stockReservado.get(id) ?? 0
    const stockDisponible = stockActual - reservado
    const solicitado = solicitadoPorProducto.get(id) ?? 0

    stockSnapshot[item.productoId] = {
      stockAlMomento: stockActual,
      reservadoOffline: reservado,
      disponible: stockDisponible
    }

    if (solicitado > 0 && solicitado > stockDisponible) {
      itemsSinStock.push({
        productoId: item.productoId,
        nombre: producto.nombre || item.nombre || 'Producto desconocido',
        solicitado,
        disponible: Math.max(0, stockDisponible)
      })
    }
  }

  return { itemsSinStock, stockSnapshot }
}
