/**
 * `ModalSustituirRegalo` en modo reparto (#831, mig 275).
 *
 * Con dos filas o más el regalo se reparte en sabores: la suma tiene que ser
 * EXACTAMENTE la cantidad original, y recién ahí se llama a
 * `dividir_regalo_pedido` con las partes. Y cada operación lleva su propio
 * clientRequestId: un reparto no puede reusar el de la sustitución.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'

const PRODUCTOS = [
  { id: '314', nombre: 'Manaos Limon 3L', stock: 100 },
  { id: '80', nombre: 'Manaos Naranja 3L', stock: 100 },
  { id: '79', nombre: 'Manaos Lima Limon 3L', stock: 100 },
  { id: '81', nombre: 'Manaos Manzana 3L', stock: 87 },
]

const dividir = vi.fn()
const sustituir = vi.fn()

vi.mock('../../hooks/queries', () => ({
  useProductosQuery: () => ({ data: PRODUCTOS }),
  usePromoAcumuladorQuery: () => ({ data: null }),
}))
vi.mock('../../hooks/queries/useSustituirRegaloMutation', () => ({
  useSustituirRegaloMutation: () => ({ mutateAsync: sustituir, isPending: false }),
  useDividirRegaloMutation: () => ({ mutateAsync: dividir, isPending: false }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn() }),
}))

import ModalSustituirRegalo from './ModalSustituirRegalo'
import type { ProductoDB } from '../../types'

const renderModal = () => render(
  <ModalSustituirRegalo
    pedidoItemId="24656"
    productoOriginal={PRODUCTOS[0] as unknown as ProductoDB}
    cantidadOriginal={14}
    regaloMueveStock={false}
    promocionId="13"
    unidadesPorBloque={6}
    onClose={vi.fn()}
  />,
)

const cantidad = (n: number, valor: number) =>
  fireEvent.change(screen.getByLabelText(`Cantidad ${n}`), { target: { value: String(valor) } })
// Abre el combobox de la fila y elige la opcion del producto `id` (por su nombre).
const producto = (n: number, id: string) => {
  const nombre = PRODUCTOS.find(p => p.id === id)!.nombre
  fireEvent.focus(screen.getByRole('combobox', { name: `Producto ${n}` }))
  const opcion = screen.getAllByRole('option').find(o => (o.textContent ?? '').startsWith(`${nombre} ·`))
  if (!opcion) throw new Error(`no hay opcion para ${nombre}`)
  fireEvent.click(opcion)
}

describe('ModalSustituirRegalo — reparto en sabores', () => {
  beforeEach(() => {
    dividir.mockReset().mockResolvedValue({ sustitucionId: '1', repartoId: 'r', modo: 'B' })
    sustituir.mockReset()
  })

  it('con la suma distinta de la original no deja confirmar', () => {
    renderModal()
    fireEvent.click(screen.getByRole('button', { name: /repartir en otro sabor/i }))
    producto(1, '314')
    cantidad(1, 6)
    producto(2, '80')
    cantidad(2, 4)
    fireEvent.change(screen.getByPlaceholderText(/el cliente prefiere/i), { target: { value: 'pidió sabores' } })

    expect(screen.getByText(/Asignado 10 de 14/)).toBeInTheDocument()
    const confirmar = screen.getByRole('button', { name: /repartir regalo/i })
    expect(confirmar).toBeDisabled()
    fireEvent.click(confirmar)
    expect(dividir).not.toHaveBeenCalled()
  })

  it('con la suma exacta llama a dividir con las partes y no a sustituir', async () => {
    renderModal()
    fireEvent.click(screen.getByRole('button', { name: /repartir en otro sabor/i }))
    fireEvent.click(screen.getByRole('button', { name: /repartir en otro sabor/i }))
    producto(1, '314')
    cantidad(1, 6)
    producto(2, '80')
    cantidad(2, 4)
    producto(3, '79')
    cantidad(3, 4)
    fireEvent.change(screen.getByPlaceholderText(/el cliente prefiere/i), { target: { value: 'pidió sabores' } })

    expect(screen.getByText(/Asignado 14 de 14/)).toBeInTheDocument()
    const confirmar = screen.getByRole('button', { name: /repartir regalo/i })
    expect(confirmar).not.toBeDisabled()
    fireEvent.click(confirmar)

    await waitFor(() => expect(dividir).toHaveBeenCalledTimes(1))
    expect(sustituir).not.toHaveBeenCalled()
    const arg = dividir.mock.calls[0][0]
    expect(arg).toMatchObject({
      pedidoItemId: '24656',
      motivo: 'pidió sabores',
      partes: [
        { productoId: '314', cantidad: 6 },
        { productoId: '80', cantidad: 4 },
        { productoId: '79', cantidad: 4 },
      ],
    })
    expect(arg.clientRequestId).toMatch(/^[0-9a-f-]{36}$/)
  })

  it('la sustitución simple y el reparto no comparten clientRequestId', async () => {
    sustituir.mockRejectedValue(new Error('Sin conexion'))
    renderModal()
    producto(1, '80')
    fireEvent.change(screen.getByPlaceholderText(/el cliente prefiere/i), { target: { value: 'otro sabor' } })
    fireEvent.click(screen.getByRole('button', { name: /cambiar regalo/i }))
    await waitFor(() => expect(sustituir).toHaveBeenCalledTimes(1))

    fireEvent.click(screen.getByRole('button', { name: /repartir en otro sabor/i }))
    cantidad(1, 10)
    producto(2, '79')
    cantidad(2, 4)
    fireEvent.click(screen.getByRole('button', { name: /repartir regalo/i }))
    await waitFor(() => expect(dividir).toHaveBeenCalledTimes(1))

    expect(dividir.mock.calls[0][0].clientRequestId)
      .not.toBe(sustituir.mock.calls[0][0].clientRequestId)
  })

  it('en reparto el original esta en su lugar alfabetico, como "regalo actual", y se elige buscando "manz" (bug de manzana)', async () => {
    // Original = Manzana (el caso del dueno: 24 de manzana en 12 naranja + 12 manzana).
    render(
      <ModalSustituirRegalo
        pedidoItemId="1"
        productoOriginal={PRODUCTOS[3] as unknown as ProductoDB}
        cantidadOriginal={24}
        regaloMueveStock={false}
        promocionId="13"
        unidadesPorBloque={6}
        onClose={vi.fn()}
      />,
    )
    fireEvent.click(screen.getByRole('button', { name: /repartir en otro sabor/i }))
    fireEvent.focus(screen.getByRole('combobox', { name: 'Producto 1' }))
    const textos = screen.getAllByRole('option').map(o => o.textContent ?? '')
    const idxManzana = textos.findIndex(t => t.startsWith('Manaos Manzana 3L'))
    expect(textos[idxManzana]).toBe('Manaos Manzana 3L · regalo actual')
    // Alfabetico: Lima Limon, Limon, Manzana, Naranja
    expect(textos.map(t => t.split(' ·')[0])).toEqual([
      'Manaos Lima Limon 3L', 'Manaos Limon 3L', 'Manaos Manzana 3L', 'Manaos Naranja 3L',
    ])
    // Buscando "manz" queda solo el original y se puede elegir.
    fireEvent.change(screen.getByRole('combobox', { name: 'Producto 1' }), { target: { value: 'manz' } })
    const filtradas = screen.getAllByRole('option')
    expect(filtradas).toHaveLength(1)
    fireEvent.click(filtradas[0])
    expect(screen.getByRole('combobox', { name: 'Producto 1' })).toHaveValue('Manaos Manzana 3L')

    cantidad(1, 12)
    producto(2, '80')
    cantidad(2, 12)
    fireEvent.change(screen.getByPlaceholderText(/el cliente prefiere/i), { target: { value: 'mitad y mitad' } })
    fireEvent.click(screen.getByRole('button', { name: /repartir regalo/i }))
    await waitFor(() => expect(dividir).toHaveBeenCalledTimes(1))
    expect(dividir.mock.calls[0][0].partes).toEqual([
      { productoId: '81', cantidad: 12 },
      { productoId: '80', cantidad: 12 },
    ])
  })

  it('con el original desactivado no se ofrece en el reparto y avisa', () => {
    render(
      <ModalSustituirRegalo
        pedidoItemId="1"
        productoOriginal={{ ...PRODUCTOS[3], activo: false } as unknown as ProductoDB}
        cantidadOriginal={24}
        regaloMueveStock={false}
        promocionId="13"
        unidadesPorBloque={6}
        onClose={vi.fn()}
      />,
    )
    fireEvent.click(screen.getByRole('button', { name: /repartir en otro sabor/i }))
    expect(screen.getByText(/esta desactivado: no se puede dejar parte del regalo/i)).toBeInTheDocument()
    fireEvent.focus(screen.getByRole('combobox', { name: 'Producto 1' }))
    const textos = screen.getAllByRole('option').map(o => o.textContent ?? '')
    expect(textos.some(t => t.startsWith('Manaos Manzana 3L'))).toBe(false)
  })
})
