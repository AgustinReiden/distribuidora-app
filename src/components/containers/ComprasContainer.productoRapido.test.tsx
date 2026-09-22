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
 * Y el producto nacía sin categoría, sin marca y sin proveedor: el alta rápida
 * no los tenía. Ahora los tiene, y la categoría o la marca nueva se crea antes
 * que el producto (ver `useAsegurarCatalogo`).
 *
 * Se monta el container con el modal stubbeado porque lo que se rompió es el
 * cableado —quién avisa, qué se guarda—, no el formulario.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mockCrearProducto = vi.fn()
const mockAsegurar = vi.fn()
const notifyError = vi.fn()
const notifySuccess = vi.fn()

/** Lo que el modal manda al apretar "Crear y Agregar". Cada test lo ajusta. */
const ALTA_BASICA = { nombre: 'MANI JAMON x 1kg', codigo: '0802', costoSinIva: 7533 }
let altaQueMandaElModal: Record<string, unknown> = ALTA_BASICA

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
  useCategoriasQuery: () => ({ data: [] }),
  useMarcasQuery: () => ({ data: [] }),
  useAsegurarCatalogo: () => ({ asegurar: mockAsegurar, creando: false }),
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
    onCrearProductoRapido?: (d: Record<string, unknown>) => Promise<unknown>
  }) => (
    <button
      type="button"
      onClick={async () => {
        try {
          await onCrearProductoRapido?.(altaQueMandaElModal)
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
    altaQueMandaElModal = ALTA_BASICA
    mockAsegurar.mockResolvedValue({})
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

  it('guarda la categoría, la marca y el proveedor elegidos en el alta', async () => {
    altaQueMandaElModal = {
      ...ALTA_BASICA,
      categoria: 'SNACKS',
      marcaId: 'm-1',
      proveedorId: '7',
    }
    mockCrearProducto.mockResolvedValue({ id: 398, nombre: 'MANI JAMON x 1kg' })

    await abrirCompraYCrearProducto()

    await waitFor(() => expect(mockCrearProducto).toHaveBeenCalledTimes(1))
    expect(mockCrearProducto).toHaveBeenCalledWith(expect.objectContaining({
      categoria: 'SNACKS',
      marca_id: 'm-1',
      proveedor_id: '7',
    }))
  })

  it('la categoría y la marca nuevas se crean antes que el producto y mandan sobre las elegidas', async () => {
    altaQueMandaElModal = {
      ...ALTA_BASICA,
      categoria: 'SNACKS',
      marcaId: 'm-1',
      proveedorId: '7',
      categoriaNueva: 'frutos secos',
      marcaNueva: 'frau',
    }
    mockAsegurar.mockResolvedValue({ categoria: 'FRUTOS SECOS', marca_id: 'm-9' })
    mockCrearProducto.mockResolvedValue({ id: 398, nombre: 'MANI JAMON x 1kg' })

    await abrirCompraYCrearProducto()

    await waitFor(() => expect(mockCrearProducto).toHaveBeenCalledTimes(1))
    expect(mockAsegurar).toHaveBeenCalledWith({ categoria_nueva: 'frutos secos', marca_nueva: 'frau' })
    expect(mockAsegurar.mock.invocationCallOrder[0]).toBeLessThan(mockCrearProducto.mock.invocationCallOrder[0])
    expect(mockCrearProducto).toHaveBeenCalledWith(expect.objectContaining({
      categoria: 'FRUTOS SECOS',
      marca_id: 'm-9',
      proveedor_id: '7',
    }))
  })

  it('sin proveedor en la factura el producto nace sin proveedor, no con un string vacío', async () => {
    altaQueMandaElModal = { ...ALTA_BASICA, categoria: '', marcaId: '', proveedorId: '' }
    mockCrearProducto.mockResolvedValue({ id: 398, nombre: 'MANI JAMON x 1kg' })

    await abrirCompraYCrearProducto()

    await waitFor(() => expect(mockCrearProducto).toHaveBeenCalledTimes(1))
    expect(mockCrearProducto).toHaveBeenCalledWith(expect.objectContaining({
      categoria: undefined,
      marca_id: null,
      proveedor_id: null,
    }))
  })

  it('si la marca nueva no se puede crear, el producto tampoco y se avisa por qué', async () => {
    altaQueMandaElModal = { ...ALTA_BASICA, marcaNueva: 'descontinuada' }
    mockAsegurar.mockRejectedValue(new Error('La marca "DESCONTINUADA" ya existe pero está desactivada. Reactivala desde Productos → Marcas, o elegí otra.'))

    await abrirCompraYCrearProducto()

    await waitFor(() => expect(notifyError).toHaveBeenCalledTimes(1))
    expect(notifyError.mock.calls[0][0]).toContain('está desactivada')
    expect(mockCrearProducto).not.toHaveBeenCalled()
    expect(notifySuccess).not.toHaveBeenCalled()
  })
})
