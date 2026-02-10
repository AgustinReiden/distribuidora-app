/**
 * Market Basket Analysis — Análisis de canasta de productos
 *
 * Calcula qué productos se compran juntos con métricas de asociación:
 * - Frecuencia: veces que el par aparece en pedidos
 * - Confianza: P(B|A) — probabilidad de comprar B si se compra A
 * - Lift: cuánto más probable es la co-ocurrencia vs aleatorio (>1 = positivo)
 */

export interface ProductPair {
  producto_a: string
  producto_b: string
  frecuencia: number
  confianza: number
  lift: number
}

interface PedidoBasket {
  items: Array<{ producto_id: string }>
}

export function calculateMarketBasket(
  pedidos: PedidoBasket[],
  minSupport = 3
): ProductPair[] {
  const totalTransactions = pedidos.length
  if (totalTransactions < 2) return []

  const productCounts: Record<string, number> = {}
  const pairCounts: Record<string, number> = {}

  for (const pedido of pedidos) {
    const productos = [...new Set(
      pedido.items
        .map(i => i.producto_id)
        .filter(Boolean)
    )]

    for (const p of productos) {
      productCounts[p] = (productCounts[p] || 0) + 1
    }

    for (let i = 0; i < productos.length; i++) {
      for (let j = i + 1; j < productos.length; j++) {
        const key = productos[i] < productos[j]
          ? `${productos[i]}|${productos[j]}`
          : `${productos[j]}|${productos[i]}`
        pairCounts[key] = (pairCounts[key] || 0) + 1
      }
    }
  }

  const results: ProductPair[] = []

  for (const [pair, count] of Object.entries(pairCounts)) {
    if (count < minSupport) continue

    const [prodA, prodB] = pair.split('|')
    const freqA = productCounts[prodA] || 0
    const freqB = productCounts[prodB] || 0

    const confidenceAtoB = freqA > 0 ? count / freqA : 0
    const confidenceBtoA = freqB > 0 ? count / freqB : 0
    const confianza = Math.max(confidenceAtoB, confidenceBtoA)

    const expectedFreq = (freqA / totalTransactions) * (freqB / totalTransactions) * totalTransactions
    const lift = expectedFreq > 0 ? count / expectedFreq : 0

    results.push({
      producto_a: prodA,
      producto_b: prodB,
      frecuencia: count,
      confianza: confianza * 100,
      lift,
    })
  }

  return results.sort((a, b) => b.lift - a.lift)
}
