/**
 * FRV-1 (#1559): el hook dice qué falta para preciar. Con la consulta de escalas caída, 12
 * unidades con una escala de $90 salen a $100 de lista y el server lo acepta: quien confirma
 * tiene que saber que la consulta no cargó.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'

type Q = { data?: unknown; isLoading?: boolean; isError?: boolean; isPaused?: boolean; refetch: () => unknown }

const { estado, refetch } = vi.hoisted(() => {
  const refetchFn = vi.fn()
  const ok = (data: unknown) => ({ data, isLoading: false, isError: false, isPaused: false, refetch: refetchFn })
  return {
    refetch: refetchFn,
    estado: {
      ok,
      pricing: ok(new Map()) as Q,
      promos: ok(new Map()) as Q,
      minimos: ok(new Map()) as Q,
      combos: ok([]) as Q,
    },
  }
})

vi.mock('./queries/useGruposPrecioQuery', () => ({ usePricingMapQuery: () => estado.pricing }))
vi.mock('./queries/usePromocionesQuery', () => ({ usePromoMapQuery: () => estado.promos }))
vi.mock('./queries/useProductosQuery', () => ({ useMinimosVentaQuery: () => estado.minimos }))
vi.mock('./queries/useCombosQuery', () => ({ useCombosVigentesQuery: () => estado.combos }))

import { usePromocionPedido } from './usePromocionPedido'

const items = [{ productoId: 'p1', cantidad: 12, precioUnitario: 100 }]
const sinDatos = (extra: Partial<Q> = {}): Q => ({ data: undefined, isLoading: false, isError: false, isPaused: false, refetch, ...extra })

beforeEach(() => {
  refetch.mockClear()
  estado.pricing = estado.ok(new Map())
  estado.promos = estado.ok(new Map())
  estado.minimos = estado.ok(new Map())
  estado.combos = estado.ok([])
})

describe('usePromocionPedido — datosPrecio (FRV-1, #1559)', () => {
  it('con todo cargado no falta nada', () => {
    const { result } = renderHook(() => usePromocionPedido(items))
    expect(result.current.datosPrecio).toEqual({ cargando: [], fallaron: [], sinSenal: [] })
  })

  it('con la consulta de escalas caída lo dice, y "reintentar" la vuelve a pedir', () => {
    estado.pricing = sinDatos({ isError: true })
    const { result } = renderHook(() => usePromocionPedido(items))
    expect(result.current.datosPrecio.fallaron).toEqual(['las escalas mayoristas'])
    result.current.reintentarDatosPrecio()
    expect(refetch).toHaveBeenCalledTimes(1)
  })

  it('con las promos caídas lo dice aunque haya un dato viejo (como VTA-2)', () => {
    estado.promos = { ...estado.ok(new Map()), isError: true }
    const { result } = renderHook(() => usePromocionPedido(items))
    expect(result.current.datosPrecio.fallaron).toEqual(['las promociones'])
  })

  // Decisión del dueño (#1559): el alta confirma con las promos de hace unos minutos si el
  // refetch falla; la edición (VTA-2) y el cambio de cliente no, porque son online.
  it('el alta (promosFallanConDato: false): promos en error CON dato no bloquean', () => {
    estado.promos = { ...estado.ok(new Map()), isError: true }
    const { result } = renderHook(() => usePromocionPedido(items, undefined, undefined, undefined, undefined, { promosFallanConDato: false }))
    expect(result.current.datosPrecio.fallaron).toEqual([])
  })

  it('el alta (promosFallanConDato: false): promos en error SIN dato bloquean', () => {
    estado.promos = sinDatos({ isError: true })
    const { result } = renderHook(() => usePromocionPedido(items, undefined, undefined, undefined, undefined, { promosFallanConDato: false }))
    expect(result.current.datosPrecio.fallaron).toEqual(['las promociones'])
  })

  it('el alta (promosFallanConDato: false): promos cargando sin dato bloquean', () => {
    estado.promos = sinDatos({ isLoading: true })
    const { result } = renderHook(() => usePromocionPedido(items, undefined, undefined, undefined, undefined, { promosFallanConDato: false }))
    expect(result.current.datosPrecio.cargando).toEqual(['las promociones'])
  })

  it('con los mínimos o los combos caídos, también', () => {
    estado.minimos = sinDatos({ isError: true })
    estado.combos = sinDatos({ isError: true })
    const { result } = renderHook(() => usePromocionPedido(items))
    expect(result.current.datosPrecio.fallaron).toEqual(['los mínimos de venta', 'los combos'])
  })

  it('un error con el dato de hace unos minutos en la caché no bloquea (sólo las promos)', () => {
    estado.pricing = { ...estado.ok(new Map()), isError: true }
    const { result } = renderHook(() => usePromocionPedido(items))
    expect(result.current.datosPrecio.fallaron).toEqual([])
  })

  it('mientras carga figura como cargando, y no se reintenta nada', () => {
    estado.pricing = sinDatos({ isLoading: true })
    const { result } = renderHook(() => usePromocionPedido(items))
    expect(result.current.datosPrecio.cargando).toEqual(['las escalas mayoristas'])
    result.current.reintentarDatosPrecio()
    expect(refetch).not.toHaveBeenCalled() // ya se está pidiendo
  })

  it('sin señal y sin dato (la query queda pausada) figura como sin señal', () => {
    estado.pricing = sinDatos({ isPaused: true })
    const { result } = renderHook(() => usePromocionPedido(items))
    expect(result.current.datosPrecio.sinSenal).toEqual(['las escalas mayoristas'])
  })

  it('un vale blanco no lleva combos: sus consultas no cuentan', () => {
    estado.combos = sinDatos({ isError: true })
    const { result } = renderHook(() => usePromocionPedido(items, undefined, undefined, undefined, undefined, { habilitados: false }))
    expect(result.current.datosPrecio.fallaron).toEqual([])
    expect(result.current.entradasDatosPrecio.map(e => e.nombre)).not.toContain('los combos')
  })
})
