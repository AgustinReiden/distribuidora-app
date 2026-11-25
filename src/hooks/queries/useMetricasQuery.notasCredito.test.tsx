/**
 * REP-1 (tanda 6 de #1603; decisión del dueño del 24/11): el Dashboard es NETO de notas de
 * crédito de venta, como los reportes.
 *
 * El escenario es REP-20 de la reauditoría: cuatro boletas entregadas por 1.050 y cuatro notas
 * por 350. Los reportes del server decían 700 y el Dashboard 1.050; el cliente C1, 900 en
 * «clientes más activos» y 650 (600 acá, con otros números) en Ventas por cliente.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { fechaLocalISO } from '../../utils/formatters'
import { addDiasISO, ventanaAnterior, ventanaPeriodoDashboard } from '../../utils/metricasDashboard'

const m = vi.hoisted(() => ({
  pedidos: [] as Array<Record<string, unknown>>,
  notas: [] as Array<Record<string, unknown>>,
  anterior: [] as Array<Record<string, unknown>>,
  // La RPC de las notas del preventista (tanda 6 bis): lo que devuelve y con qué se la llamó.
  delVendedor: [] as Array<Record<string, unknown>>,
  llamadasRpc: [] as Array<{ nombre: string; args: Record<string, unknown> }>,
}))

vi.mock('../supabase/base', () => {
  const armar = (tabla: string) => {
    let cols = ''
    const b: Record<string, unknown> = {}
    const enc = () => b
    b.select = (c: string) => { cols = c; return b }
    for (const op of ['eq', 'neq', 'or', 'gte', 'lte', 'order']) b[op] = enc
    b.range = (desde: number) => {
      let filas: Array<Record<string, unknown>> = []
      if (desde === 0) {
        if (tabla === 'notas_credito_venta') filas = m.notas
        else if (tabla === 'pedidos' && cols.includes('items:pedido_items')) filas = m.pedidos
        // La serie de 7 días lee las mismas boletas (de hoy); los cancelados, ninguna.
        else if (tabla === 'pedidos' && cols === 'total, cargo_envio, fecha, canal') filas = m.pedidos
        else if (tabla === 'pedidos' && cols === 'total, cargo_envio, estado, canal') filas = m.anterior
      }
      return Promise.resolve({ data: filas, error: null })
    }
    return b
  }
  const rpc = (nombre: string, args: Record<string, unknown>) => {
    m.llamadasRpc.push({ nombre, args })
    return { range: () => Promise.resolve({ data: m.delVendedor, error: null }) }
  }
  return { supabase: { from: (tabla: string) => armar(tabla), rpc } }
})
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))

import { useMetricasQuery } from './useMetricasQuery'

const hoy = fechaLocalISO()

const boleta = (id: number, cliente: number, total: number, extra: Record<string, unknown> = {}) => ({
  id, cliente_id: cliente, estado: 'entregado', canal: 'app', tipo_factura: 'ZZ', total, cargo_envio: 0,
  fecha: hoy, usuario_id: 'prev-1', cliente: { nombre_fantasia: `Cliente ${cliente}` }, items: [], ...extra,
})

const nota = (id: number, cliente: number, total: number, pedido: Record<string, unknown> = {}, extra: Record<string, unknown> = {}) => ({
  id, fecha: hoy, cliente_id: cliente, total, anulada: false,
  pedido: { estado: 'entregado', canal: 'app', tipo_factura: 'ZZ', usuario_id: 'prev-1', ...pedido },
  ...extra,
})

function wrapper({ children }: { children: React.ReactNode }): React.ReactElement {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

async function correr(usuarioId?: string | null) {
  const { result } = renderHook(() => useMetricasQuery('mes', usuarioId), { wrapper })
  await waitFor(() => expect(result.current.isSuccess).toBe(true))
  return result.current.data!
}

beforeEach(() => {
  // 1.050 entregados: C1 900 (3 boletas), C3 150.
  m.pedidos = [boleta(1, 1, 200), boleta(2, 1, 300), boleta(3, 1, 400), boleta(4, 3, 150)]
  // 350 en notas: 300 al cliente 1, 50 al 3.
  m.notas = [nota(1, 1, 100), nota(2, 1, 100), nota(3, 1, 100), nota(4, 3, 50)]
  m.anterior = []
  m.delVendedor = []
  m.llamadasRpc = []
})

describe('el Dashboard es neto de notas de crédito de venta (REP-1)', () => {
  it('«Venta entregada» resta las notas: 1.050 − 350 = 700', async () => {
    const d = await correr()
    expect(d.ventasPeriodo).toBe(700)
  })

  it('«clientes más activos» resta la nota de cada cliente: C1 900 − 300 = 600; C3 150 − 50 = 100', async () => {
    const d = await correr()
    expect(d.clientesMasActivos.map(c => [c.nombre, c.total])).toEqual([['Cliente 1', 600], ['Cliente 3', 100]])
  })

  it('una nota no resta pedidos ni clientes', async () => {
    const d = await correr()
    expect(d.pedidosEntregados).toBe(4)
    expect(d.pedidosPeriodo).toBe(4)
    expect(d.clientesMasActivos).toHaveLength(2)
  })

  it('el gráfico de 7 días resta las notas de cada día: hoy 1.050 − 350 = 700', async () => {
    const d = await correr()
    expect(d.ventasPorDia[d.ventasPorDia.length - 1].ventas).toBe(700)
  })

  it('el período anterior también es neto: la comparación es entre universos iguales', async () => {
    const mes = ventanaPeriodoDashboard('mes', hoy)
    const prev = ventanaAnterior(mes.desde!, hoy)
    m.anterior = [{ total: 500, cargo_envio: 0, estado: 'entregado', canal: 'app' }]
    m.notas = [nota(1, 1, 100), { ...nota(2, 1, 120), fecha: prev.hasta }]
    const d = await correr()
    expect(d.ventasPeriodoAnterior).toBe(500 - 120)
    expect(d.ventasPeriodo).toBe(1050 - 100)
  })

  it('no resta una nota anulada, una de un vale blanco, una de un canje ni una de un pedido sin entregar', async () => {
    m.notas = [
      nota(1, 1, 100, {}, { anulada: true }),
      nota(2, 1, 100, { tipo_factura: 'VB' }),
      nota(3, 1, 100, { canal: 'cambio' }),
      nota(4, 3, 50, { estado: 'asignado' }),
    ]
    const d = await correr()
    expect(d.ventasPeriodo).toBe(1050)
  })

  it('el Dashboard de un vendedor resta sólo las notas de SUS boletas', async () => {
    m.notas = [nota(1, 1, 100), nota(2, 1, 100, { usuario_id: 'otro' }), nota(3, 3, 50)]
    const d = await correr('prev-1')
    expect(d.ventasPeriodo).toBe(1050 - 150)
  })

  it('un preventista sin notas (la RLS no le da ninguna y la RPC tampoco) ve lo suyo, en bruto y sin error', async () => {
    m.notas = []
    const d = await correr('prev-1')
    expect(d.ventasPeriodo).toBe(1050)
  })
})

// Tanda 6 bis (decisión del dueño del 24/11: «que vea $ 700, neto»): al preventista la RLS no le
// deja leer las notas por REST; las de SUS boletas le llegan por notas_credito_venta_del_vendedor.
describe('el Dashboard del preventista también es neto (RPC de sus notas)', () => {
  it('vendió $ 1.050 y tiene una nota de $ 350: ve $ 700', async () => {
    m.notas = []
    m.delVendedor = [{ fecha: hoy, cliente_id: 1, total: 350 }]
    const d = await correr('prev-1')
    expect(d.ventasPeriodo).toBe(700)
    expect(d.ventasPorDia[d.ventasPorDia.length - 1].ventas).toBe(700)
    expect(d.clientesMasActivos.map(c => [c.nombre, c.total])).toEqual([['Cliente 1', 550], ['Cliente 3', 150]])
  })

  it('le pide a la RPC desde la ventana más vieja (período, anterior o gráfico), sin tope arriba', async () => {
    const mes = ventanaPeriodoDashboard('mes', hoy)
    const prev = ventanaAnterior(mes.desde!, hoy)
    await correr('prev-1')
    expect(m.llamadasRpc).toEqual([
      { nombre: 'notas_credito_venta_del_vendedor', args: { p_desde: [mes.desde!, prev.desde, addDiasISO(hoy, -6)].sort()[0], p_hasta: null, p_cliente_id: null } },
    ])
  })

  it('el período anterior del preventista también es neto', async () => {
    const mes = ventanaPeriodoDashboard('mes', hoy)
    const prev = ventanaAnterior(mes.desde!, hoy)
    m.anterior = [{ total: 500, cargo_envio: 0, estado: 'entregado', canal: 'app' }]
    m.notas = []
    m.delVendedor = [{ fecha: prev.hasta, cliente_id: 1, total: 120 }]
    const d = await correr('prev-1')
    expect(d.ventasPeriodoAnterior).toBe(380)
    expect(d.ventasPeriodo).toBe(1050)
  })

  it('el Dashboard de admin y encargado (sin vendedor) no llama a la RPC: lee las notas por REST', async () => {
    await correr()
    expect(m.llamadasRpc).toEqual([])
  })
})
