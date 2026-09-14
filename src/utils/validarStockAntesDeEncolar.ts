/**
 * Valida que haya stock suficiente para un pedido offline ANTES de encolarlo,
 * descontando lo que ya reservan otros pedidos offline pendientes de
 * sincronizar. Usado por `guardarPedidoOffline` (useOfflineSync.ts).
 */

export interface StockValidationItem {
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
  items?: Array<{ productoId: string; cantidad: number }>;
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

  // Calcular stock reservado por pedidos offline pendientes
  const stockReservado: Record<string, number> = {}
  pedidosPendientes.forEach(pedido => {
    pedido.items?.forEach(item => {
      stockReservado[item.productoId] = (stockReservado[item.productoId] || 0) + item.cantidad
    })
  })

  for (const item of items) {
    const producto = productos.find(p => p.id === item.productoId)
    if (producto) {
      const stockActual = producto.stock || 0
      const reservado = stockReservado[item.productoId] || 0
      const stockDisponible = stockActual - reservado

      stockSnapshot[item.productoId] = {
        stockAlMomento: stockActual,
        reservadoOffline: reservado,
        disponible: stockDisponible
      }

      if (item.cantidad > stockDisponible) {
        itemsSinStock.push({
          productoId: item.productoId,
          nombre: producto.nombre || item.nombre || 'Producto desconocido',
          solicitado: item.cantidad,
          disponible: Math.max(0, stockDisponible)
        })
      }
    }
  }

  return { itemsSinStock, stockSnapshot }
}
