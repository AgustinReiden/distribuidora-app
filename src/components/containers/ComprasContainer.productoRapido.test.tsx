/**
 * "Crear producto rápido" desde una factura tiene que avisar cuando falla.
 *
 * EL HUECO
 * --------
 * El handler llamaba a `mutateAsync` sin `catch`, y el modal atrapaba el
 * rechazo con un `catch {}` cuyo comentario decía "Error handled by container".
 * No lo manejaba nadie: el mensaje —que existía, y era bueno— se computaba y se
 * tiraba. Para la usuaria el botón "Crear y Agregar" no hacía absolutamente
 * nada.
 *
 * Pasó en prod (Tucumán, 10/09/2026): cargó cuatro productos nuevos en una
 * factura y en el quinto chocó contra el código duplicado del que acababa de
 * crear. Diez clicks, cero mensajes, y la conclusión razonable de que la app se
 * había roto. Los logs del gateway muestran el intento repetido y ninguna
 * respuesta de error: nunca llegó a haber INSERT.
 *
 * Se monta el container con el modal stubbeado porque lo que se rompió es el
 * cableado —quién avisa—, no el formulario.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mockCrearProducto = vi.fn()
const notifyError = vi.fn()
const notifySuccess = vi.fn()

vi.mock('../../hooks/queries', () => ({
  useComprasQuery: () => ({ data: [], isLoading: false }),
  useProveedoresQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  useNotasCreditoByCompraQuery: () => ({ data: [] }),
  useNotasCreditoResumenQuery: () => ({ data: {} }),
  useRegistrarCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useActualizarCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useAnularCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCambiarProveedorCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCrearProductoMutation: () => ({ mutateAsync: mockCrearProducto, isPending: false }),
  useCrearProveedorMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useRegistrarNotaCreditoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useActualizarProductoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))

vi.mock('../../hooks/queries/useLotesQuery', () => ({
  useLotesCompraQuery: () => ({ data: [] }),
}))

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isAdmin: true, user: { id: 'u1' } }),
}))

vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: notifyError, success: notifySuccess, warning: vi.fn() }),
}))

vi.mock('../../hooks/useResetOnSucursalChange', () => ({
  useResetOnSucursalChange: () => undefined,
}))

vi.mock('../vistas/VistaCompras', () => ({
  default: ({ onNuevaCompra }: { onNuevaCompra?: () => void }) => (
    <button type="button" onClick={onNuevaCompra}>Nueva compra</button>
  ),
}))

// El modal real no es lo que se prueba: sólo hace falta disparar el alta rápida
// tal como la dispara él —await, y si rechaza, seguir sin romper la pantalla—.
vi.mock('../modals/ModalCompra', () => ({
  default: ({ onCrearProductoRapido }: {
    onCrearProductoRapido?: (d: { nombre: string; codigo: string; costoSinIva: number }) => Promise<unknown>
  }) => (
    <button
      type="button"
      onClick={async () => {
        try {
          await onCrearProductoRapido?.({ nombre: 'MANI JAMON x 1kg', codigo: '0802', costoSinIva: 7533 })
        } catch {
          // Igual que el modal de verdad: deja el formulario como estaba.
        }
      }}
    >
      Crear y Agregar
    </button>
  ),
}))

import ComprasContainer from './ComprasContainer'

async function abrirCompraYCrearProducto() {
  const user = userEvent.setup()
  render(<ComprasContainer />)
  // Los modales y la vista son chunks lazy: hay que esperar a que resuelvan.
  await user.click(await screen.findByText('Nueva compra'))
  await user.click(await screen.findByText('Crear y Agregar'))
}

describe('alta rápida de producto desde la factura', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('muestra el error de la base cuando el alta falla', async () => {
    mockCrearProducto.mockRejectedValue(
      new Error('Ya existe un producto con código "0802": «MANI JAMON x 1kg». Buscalo por nombre o código y agregalo, o cargá este con otro código.')
    )

    await abrirCompraYCrearProducto()

    await waitFor(() => expect(notifyError).toHaveBeenCalledTimes(1))
    expect(notifyError.mock.calls[0][0]).toContain('Ya existe un producto con código "0802"')
    expect(notifySuccess).not.toHaveBeenCalled()
  })

  it('no se queda callado ni cuando el error no es un Error', async () => {
    mockCrearProducto.mockRejectedValue('boom')

    await abrirCompraYCrearProducto()

    await waitFor(() => expect(notifyError).toHaveBeenCalledWith('No se pudo crear el producto'))
  })

  it('avisa del éxito y no ensucia con un error cuando el alta anda', async () => {
    mockCrearProducto.mockResolvedValue({ id: 398, nombre: 'MANI JAMON x 1kg', codigo: '0802' })

    await abrirCompraYCrearProducto()

    await waitFor(() => expect(notifySuccess).toHaveBeenCalledTimes(1))
    expect(notifyError).not.toHaveBeenCalled()
  })
})
