import { describe, it, expect } from 'vitest'
import { calculateMarketBasket, type ProductPair } from './marketBasket'

describe('calculateMarketBasket', () => {
  describe('Edge cases', () => {
    it('returns empty array for empty input', () => {
      const result = calculateMarketBasket([])
      expect(result).toEqual([])
    })

    it('returns empty array for single pedido (less than 2)', () => {
      const pedidos = [
        {
          items: [
            { producto_id: 'prod-a' },
            { producto_id: 'prod-b' },
          ],
        },
      ]
      const result = calculateMarketBasket(pedidos)
      expect(result).toEqual([])
    })

    it('returns empty array when no pairs meet minSupport threshold', () => {
      // 3 pedidos, each with different product pairs
      // No pair appears 3+ times (default minSupport)
      const pedidos = [
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-c' }, { producto_id: 'prod-d' }] },
        { items: [{ producto_id: 'prod-e' }, { producto_id: 'prod-f' }] },
      ]
      const result = calculateMarketBasket(pedidos)
      expect(result).toEqual([])
    })
  })

  describe('Simple cases', () => {
    it('calculates metrics correctly for 3 pedidos with same pair (A, B)', () => {
      // All 3 pedidos contain both A and B
      // Frequency: 3
      // Product A count: 3, Product B count: 3
      // Confidence P(B|A) = 3/3 = 1.0 = 100%
      // Confidence P(A|B) = 3/3 = 1.0 = 100%
      // Max confidence = 100%
      // Expected frequency = (3/3) * (3/3) * 3 = 3
      // Lift = 3/3 = 1.0
      const pedidos = [
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
      ]

      const result = calculateMarketBasket(pedidos)

      expect(result).toHaveLength(1)
      expect(result[0]).toEqual({
        producto_a: 'prod-a',
        producto_b: 'prod-b',
        frecuencia: 3,
        confianza: 100,
        lift: 1,
      })
    })

    it('respects custom minSupport threshold', () => {
      // Pair (A, B) appears 2 times
      // With minSupport=2, should be included
      // With minSupport=3, should be excluded
      const pedidos = [
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-c' }] },
      ]

      const resultDefault = calculateMarketBasket(pedidos)
      expect(resultDefault).toHaveLength(0)

      const resultMinSupport2 = calculateMarketBasket(pedidos, 2)
      expect(resultMinSupport2).toHaveLength(1)
      expect(resultMinSupport2[0].frecuencia).toBe(2)
    })
  })

  describe('Data cleaning', () => {
    it('deduplicates producto_ids within a single pedido', () => {
      // Pedido 1: A, B, B (duplicate)
      // Pedido 2: A, B
      // Pedido 3: A, B
      // After dedup, all 3 pedidos have exactly (A, B)
      // Same as simple case above
      const pedidos = [
        {
          items: [
            { producto_id: 'prod-a' },
            { producto_id: 'prod-b' },
            { producto_id: 'prod-b' }, // duplicate
          ],
        },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
      ]

      const result = calculateMarketBasket(pedidos)

      expect(result).toHaveLength(1)
      expect(result[0].frecuencia).toBe(3)
      expect(result[0].confianza).toBe(100)
    })

    it('filters out falsy producto_ids (null, undefined, empty string)', () => {
      // Pedido 1: A, B, null
      // Pedido 2: A, B, undefined
      // Pedido 3: A, B, ""
      // After filtering, all 3 pedidos have exactly (A, B)
      const pedidos = [
        {
          items: [
            { producto_id: 'prod-a' },
            { producto_id: 'prod-b' },
            { producto_id: null as any },
          ],
        },
        {
          items: [
            { producto_id: 'prod-a' },
            { producto_id: 'prod-b' },
            { producto_id: undefined as any },
          ],
        },
        {
          items: [
            { producto_id: 'prod-a' },
            { producto_id: 'prod-b' },
            { producto_id: '' },
          ],
        },
      ]

      const result = calculateMarketBasket(pedidos)

      expect(result).toHaveLength(1)
      expect(result[0].frecuencia).toBe(3)
      expect(result[0].confianza).toBe(100)
    })
  })

  describe('Confidence calculation', () => {
    it('calculates asymmetric confidence correctly when products have different frequencies', () => {
      // Pedido 1: A, B (pair)
      // Pedido 2: A, B (pair)
      // Pedido 3: A, B (pair)
      // Pedido 4: A only
      // Pedido 5: A only
      //
      // Product A count: 5
      // Product B count: 3
      // Pair (A, B) count: 3
      //
      // Confidence P(B|A) = 3/5 = 0.6 = 60%
      // Confidence P(A|B) = 3/3 = 1.0 = 100%
      // Max confidence = 100%
      //
      // Expected frequency = (5/5) * (3/5) * 5 = 3
      // Lift = 3/3 = 1.0
      const pedidos = [
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }] },
        { items: [{ producto_id: 'prod-a' }] },
      ]

      const result = calculateMarketBasket(pedidos)

      expect(result).toHaveLength(1)
      expect(result[0]).toEqual({
        producto_a: 'prod-a',
        producto_b: 'prod-b',
        frecuencia: 3,
        confianza: 100, // max(60, 100) = 100
        lift: 1,
      })
    })
  })

  describe('Lift calculation', () => {
    it('calculates lift > 1 when products are positively correlated', () => {
      // Pedido 1: A, B (pair)
      // Pedido 2: A, B (pair)
      // Pedido 3: A, B (pair)
      // Pedido 4: C
      // Pedido 5: D
      //
      // Total transactions: 5
      // Product A count: 3
      // Product B count: 3
      // Pair (A, B) count: 3
      //
      // Expected frequency = (3/5) * (3/5) * 5 = 9/5 = 1.8
      // Lift = 3/1.8 = 1.667 (rounded)
      //
      // Lift > 1 means positive correlation (they co-occur more than expected)
      const pedidos = [
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-c' }] },
        { items: [{ producto_id: 'prod-d' }] },
      ]

      const result = calculateMarketBasket(pedidos)

      expect(result).toHaveLength(1)
      expect(result[0].lift).toBeCloseTo(1.667, 2)
      expect(result[0].lift).toBeGreaterThan(1)
    })

    it('calculates lift with known values accurately', () => {
      // Pedido 1: A, B
      // Pedido 2: A, B
      // Pedido 3: A, B
      // Pedido 4: A, B
      // Pedido 5: A, C
      // Pedido 6: A, C
      // Pedido 7: B, C
      // Pedido 8: B, C
      // Pedido 9: B, C
      // Pedido 10: D
      //
      // Total: 10
      // A count: 6 (pedidos 1-6)
      // B count: 7 (pedidos 1-4, 7-9)
      // C count: 5 (pedidos 5-9)
      //
      // Pair (A, B): 4
      // Expected = (6/10) * (7/10) * 10 = 4.2
      // Lift = 4/4.2 = 0.952
      //
      // Pair (A, C): 2 (below minSupport=3, excluded)
      //
      // Pair (B, C): 3
      // Expected = (7/10) * (5/10) * 10 = 3.5
      // Lift = 3/3.5 = 0.857
      const pedidos = [
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-c' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-c' }] },
        { items: [{ producto_id: 'prod-b' }, { producto_id: 'prod-c' }] },
        { items: [{ producto_id: 'prod-b' }, { producto_id: 'prod-c' }] },
        { items: [{ producto_id: 'prod-b' }, { producto_id: 'prod-c' }] },
        { items: [{ producto_id: 'prod-d' }] },
      ]

      const result = calculateMarketBasket(pedidos)

      expect(result).toHaveLength(2) // (A,B) and (B,C), (A,C) excluded
      
      const pairAB = result.find(
        p => p.producto_a === 'prod-a' && p.producto_b === 'prod-b'
      )
      expect(pairAB).toBeDefined()
      expect(pairAB!.frecuencia).toBe(4)
      expect(pairAB!.lift).toBeCloseTo(0.952, 2)

      const pairBC = result.find(
        p => p.producto_a === 'prod-b' && p.producto_b === 'prod-c'
      )
      expect(pairBC).toBeDefined()
      expect(pairBC!.frecuencia).toBe(3)
      expect(pairBC!.lift).toBeCloseTo(0.857, 2)
    })
  })

  describe('Sorting and ordering', () => {
    it('sorts results by lift descending', () => {
      // Pedido 1-4: A, B (lift will be high)
      // Pedido 5-7: C, D (lift will be medium)
      // Pedido 8-10: E, F (lift will be low due to more transactions)
      // Plus filler pedidos
      //
      // Creating scenario where lifts differ:
      // High lift: pair appears frequently relative to individual occurrences
      // Low lift: pair appears infrequently relative to individual occurrences
      const pedidos = [
        // Pair (A, B): 4 times, A:4, B:4
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        // Pair (C, D): 3 times, C:6, D:6 (lower lift than A,B)
        { items: [{ producto_id: 'prod-c' }, { producto_id: 'prod-d' }] },
        { items: [{ producto_id: 'prod-c' }, { producto_id: 'prod-d' }] },
        { items: [{ producto_id: 'prod-c' }, { producto_id: 'prod-d' }] },
        { items: [{ producto_id: 'prod-c' }] },
        { items: [{ producto_id: 'prod-c' }] },
        { items: [{ producto_id: 'prod-c' }] },
        { items: [{ producto_id: 'prod-d' }] },
        { items: [{ producto_id: 'prod-d' }] },
        { items: [{ producto_id: 'prod-d' }] },
      ]

      const result = calculateMarketBasket(pedidos)

      expect(result.length).toBeGreaterThan(0)
      
      // Verify descending order
      for (let i = 0; i < result.length - 1; i++) {
        expect(result[i].lift).toBeGreaterThanOrEqual(result[i + 1].lift)
      }

      // Pair (A, B): expected = (4/13)*(4/13)*13 = 1.23, lift = 4/1.23 = 3.25
      // Pair (C, D): expected = (6/13)*(6/13)*13 = 2.77, lift = 3/2.77 = 1.08
      // So (A, B) should come first
      expect(result[0].producto_a).toBe('prod-a')
      expect(result[0].producto_b).toBe('prod-b')
    })

    it('handles multiple product pairs with varying frequencies', () => {
      // Multiple pairs with different characteristics
      const pedidos = [
        // Pair (A, B): 5 times
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        { items: [{ producto_id: 'prod-a' }, { producto_id: 'prod-b' }] },
        // Pair (C, D): 3 times
        { items: [{ producto_id: 'prod-c' }, { producto_id: 'prod-d' }] },
        { items: [{ producto_id: 'prod-c' }, { producto_id: 'prod-d' }] },
        { items: [{ producto_id: 'prod-c' }, { producto_id: 'prod-d' }] },
        // Pair (E, F): 4 times
        { items: [{ producto_id: 'prod-e' }, { producto_id: 'prod-f' }] },
        { items: [{ producto_id: 'prod-e' }, { producto_id: 'prod-f' }] },
        { items: [{ producto_id: 'prod-e' }, { producto_id: 'prod-f' }] },
        { items: [{ producto_id: 'prod-e' }, { producto_id: 'prod-f' }] },
      ]

      const result = calculateMarketBasket(pedidos)

      expect(result).toHaveLength(3)
      
      // Verify all pairs are present
      expect(result.some(p => p.producto_a === 'prod-a' && p.producto_b === 'prod-b')).toBe(true)
      expect(result.some(p => p.producto_a === 'prod-c' && p.producto_b === 'prod-d')).toBe(true)
      expect(result.some(p => p.producto_a === 'prod-e' && p.producto_b === 'prod-f')).toBe(true)
      
      // Verify frequencies
      const pairAB = result.find(p => p.producto_a === 'prod-a')
      const pairCD = result.find(p => p.producto_a === 'prod-c')
      const pairEF = result.find(p => p.producto_a === 'prod-e')
      
      expect(pairAB!.frecuencia).toBe(5)
      expect(pairCD!.frecuencia).toBe(3)
      expect(pairEF!.frecuencia).toBe(4)
    })
  })

  describe('Alphabetical pair ordering', () => {
    it('ensures producto_a < producto_b alphabetically', () => {
      // Test that pair keys are always stored in sorted order
      const pedidos = [
        { items: [{ producto_id: 'prod-z' }, { producto_id: 'prod-a' }] },
        { items: [{ producto_id: 'prod-z' }, { producto_id: 'prod-a' }] },
        { items: [{ producto_id: 'prod-z' }, { producto_id: 'prod-a' }] },
      ]

      const result = calculateMarketBasket(pedidos)

      expect(result).toHaveLength(1)
      // Should be ordered as (prod-a, prod-z) not (prod-z, prod-a)
      expect(result[0].producto_a).toBe('prod-a')
      expect(result[0].producto_b).toBe('prod-z')
    })
  })
})
