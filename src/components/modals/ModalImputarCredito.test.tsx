/**
 * ModalImputarCredito: qué pedidos ofrece (con faltante, sin el de origen de la
 * NC), el monto por defecto y la vista previa del resto, la confirmación dentro
 * del modal y el payload exacto que llega a `imputar_credito_a_pedido`.
 *
 * Se mockea el cliente de Supabase (no el hook): así queda fijado el contrato
 * con la RPC —nombres de parámetros, ids numéricos, UUID de idempotencia—.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpcCalls: Array<{ fn: string; args: Record<string, unknown> }> = []
let rpcResult: { data: unknown; error: { message: string; code?: string } | null }
let pedidosDB: unknown[] = []
let origenNC: { id: number; pedido_id: number } | null = null
const success = vi.fn()

function builder(rows: () => unknown[]) {
  const b: Record<string, unknown> = {}
  for (const m of ['select', 'eq', 'neq', 'order']) b[m] = () => b
  b.range = () => Promise.resolve({ data: rows(), error: null })
  b.maybeSingle = () => Promise.resolve({ data: origenNC, error: null })
  return b
}

vi.mock('../../hooks/supabase/base', () => ({
  supabase: {
    rpc: (fn: string, args: Record<string, unknown>) => {
      rpcCalls.push({ fn, args })
      return Promise.resolve(rpcResult)
    },
    from: (tabla: string) => builder(() => (tabla === 'pedidos' ? pedidosDB : [])),
  },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success, error: vi.fn() }),
}))

import ModalImputarCredito, { imputarCreditoSchema, type ModalImputarCreditoProps } from './ModalImputarCredito'
import { formatPrecio } from '../../utils/formatters'

/** formatPrecio separa con espacio duro; el texto del DOM se compara normalizado. */
const fp = (n: number) => formatPrecio(n).replace(/\s/g, ' ')

function montar(props: Partial<ModalImputarCreditoProps> = {}) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const onClose = vi.fn()
  const onImputado = vi.fn()
  render(
    <QueryClientProvider client={qc}>
      <ModalImputarCredito
        inline
        clienteId="858"
        credito={{ pagoId: '901', monto: 16700, notaCreditoId: '5', pedidoOrigenId: '6510' }}
        onClose={onClose}
        onImputado={onImputado}
        {...props}
      />
    </QueryClientProvider>,
  )
  return { onClose, onImputado }
}

const opcion = (id: string) => screen.queryByRole('option', { name: new RegExp(`^Pedido #${id} `) })

describe('ModalImputarCredito', () => {
  beforeEach(() => {
    rpcCalls.length = 0
    success.mockReset()
    origenNC = null
    rpcResult = {
      data: { pago_id: 901, pedido_id: 7001, monto_imputado: 10000, resto_a_favor: 6700, pago_resto_id: 902 },
      error: null,
    }
    pedidosDB = [
      { id: 7002, fecha: '2026-10-01', total: 3000, monto_pagado: 0, estado: 'entregado' },
      { id: 7001, fecha: '2026-09-20', total: 12000, monto_pagado: 2000, estado: 'entregado' },
      { id: 6510, fecha: '2026-09-01', total: 50000, monto_pagado: 0, estado: 'entregado' },
      { id: 7003, fecha: '2026-09-25', total: 800, monto_pagado: 800, estado: 'entregado' },
    ]
  })

  it('muestra el crédito con su origen y ofrece sólo pedidos con faltante, sin el de origen', async () => {
    montar()
    expect(await screen.findByRole('option', { name: /^Pedido #7001 / })).toBeInTheDocument()
    expect(screen.getByText(fp(16700))).toBeInTheDocument()
    expect(screen.getByText('Nota de crédito #5 (origen pedido #6510)')).toBeInTheDocument()
    expect(opcion('7001')).toHaveTextContent(`falta ${fp(10000)}`)
    expect(opcion('7002')).toBeInTheDocument()
    expect(opcion('6510')).toBeNull()
    expect(opcion('7003')).toBeNull()
    expect(screen.getByText('Una vez imputada, la nota de crédito ya no se puede anular.')).toBeInTheDocument()
  })

  it('el monto por defecto es el mínimo y la vista previa muestra el resto', async () => {
    montar()
    await screen.findByRole('option', { name: /^Pedido #7001 / })
    // El más viejo primero: 7001, que debe 10.000 de un crédito de 16.700.
    expect(screen.getByLabelText('Monto a imputar')).toHaveValue('10000')
    expect(screen.getByTestId('preview-imputacion')).toHaveTextContent(
      `Se imputan ${fp(10000)} al pedido #7001 · quedan ${fp(6700)} a favor`,
    )
    fireEvent.change(screen.getByRole('combobox'), { target: { value: '7002' } })
    expect(screen.getByTestId('preview-imputacion')).toHaveTextContent(
      `Se imputan ${fp(3000)} al pedido #7002 · quedan ${fp(13700)} a favor`,
    )
    fireEvent.change(screen.getByLabelText('Monto a imputar'), { target: { value: '1000' } })
    expect(screen.getByTestId('preview-imputacion')).toHaveTextContent(
      `Se imputan ${fp(1000)} al pedido #7002 · quedan ${fp(15700)} a favor`,
    )
  })

  it('un monto mayor a lo que falta no se puede imputar', async () => {
    montar()
    await screen.findByRole('option', { name: /^Pedido #7001 / })
    fireEvent.change(screen.getByLabelText('Monto a imputar'), { target: { value: '12000' } })
    expect(screen.getByRole('alert')).toHaveTextContent('no puede superar lo que le falta al pedido')
    expect(screen.getByRole('button', { name: /Imputar/ })).toBeDisabled()
  })

  it('confirma dentro del modal y llama a la RPC con los parámetros exactos', async () => {
    const { onClose, onImputado } = montar()
    await screen.findByRole('option', { name: /^Pedido #7001 / })
    fireEvent.click(screen.getByRole('button', { name: /^Imputar$/ }))
    expect(rpcCalls).toHaveLength(0)
    fireEvent.click(screen.getByRole('button', { name: 'Sí, imputar' }))
    await waitFor(() => expect(rpcCalls).toHaveLength(1))
    expect(rpcCalls[0].fn).toBe('imputar_credito_a_pedido')
    const { p_client_request_id, ...resto } = rpcCalls[0].args
    expect(resto).toEqual({ p_pago_id: 901, p_pedido_id: 7001, p_monto: 10000 })
    expect(p_client_request_id).toMatch(/^[0-9a-f-]{36}$/i)
    await waitFor(() => expect(onClose).toHaveBeenCalled())
    expect(onImputado).toHaveBeenCalledWith(expect.objectContaining({
      montoImputado: 10000, restoAFavor: 6700, pagoRestoId: '902',
    }))
  })

  it('un reintento tras un error del servidor reusa el mismo UUID', async () => {
    rpcResult = { data: null, error: { message: 'El pedido ya no tiene saldo pendiente', code: '22023' } }
    montar()
    await screen.findByRole('option', { name: /^Pedido #7001 / })
    fireEvent.click(screen.getByRole('button', { name: /^Imputar$/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Sí, imputar' }))
    expect(await screen.findByText('El pedido ya no tiene saldo pendiente')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /^Imputar$/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Sí, imputar' }))
    await waitFor(() => expect(rpcCalls).toHaveLength(2))
    expect(rpcCalls[1].args.p_client_request_id).toBe(rpcCalls[0].args.p_client_request_id)
  })

  it('sin el pedido de origen en las props lo busca por la NC y lo excluye', async () => {
    origenNC = { id: 5, pedido_id: 7001 }
    montar({ credito: { pagoId: '901', monto: 16700, notaCreditoId: '5' } })
    expect(await screen.findByRole('option', { name: /^Pedido #7002 / })).toBeInTheDocument()
    expect(opcion('7001')).toBeNull()
    expect(screen.getByText('Nota de crédito #5 (origen pedido #7001)')).toBeInTheDocument()
  })

  it('un pago a cuenta no lleva el aviso de la NC', async () => {
    montar({ credito: { pagoId: '901', monto: 500 } })
    await screen.findByRole('option', { name: /^Pedido #6510 / })
    expect(screen.getByText('Pago a cuenta')).toBeInTheDocument()
    expect(screen.queryByText(/ya no se puede anular/)).toBeNull()
  })

  it('sin pedidos imputables explica que el crédito queda a favor', async () => {
    pedidosDB = [{ id: 6510, fecha: '2026-09-01', total: 50000, monto_pagado: 0, estado: 'entregado' }]
    montar()
    expect(await screen.findByText(/no tiene pedidos con saldo pendiente/)).toHaveTextContent(
      'sin contar el pedido #6510',
    )
    expect(screen.queryByRole('button', { name: /^Imputar$/ })).toBeNull()
  })

  it('el schema co-locado acepta ids numéricos y rechaza montos no positivos', () => {
    expect(imputarCreditoSchema.safeParse({ pagoId: 901, pedidoId: 7001, monto: '10' }).success).toBe(true)
    expect(imputarCreditoSchema.safeParse({ pagoId: 901, pedidoId: 7001, monto: 0 }).success).toBe(false)
    expect(imputarCreditoSchema.safeParse({ pagoId: 901, pedidoId: '', monto: 5 }).success).toBe(false)
  })
})
