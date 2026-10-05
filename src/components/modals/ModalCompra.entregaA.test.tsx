/**
 * Entrega A del rediseño de compras, tal como la ve quien carga la factura:
 *
 *  - el proveedor se busca (nombre o CUIT) y "+ Nuevo proveedor" arranca el
 *    alta con lo tipeado;
 *  - el aviso de factura ya cargada aparece al completar el cabezal y NO
 *    bloquea el registro;
 *  - el cuadre contra el total de la factura queda fijo al pie;
 *  - el borrador local: se ofrece al abrir (nunca se tira solo), se retoma con
 *    todo, marca las líneas cuyo producto ya no está, y se borra al registrar.
 *
 * La lógica fina vive testeada en utils (facturaDuplicada, filtrarOpciones,
 * borradorCompra) y en useBorradorCompra; acá va el cableado.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, within, act, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ProductoDB, ProveedorDBExtended } from '../../types'

vi.mock('../../lib/supabase', () => ({
  supabase: {
    storage: { from: vi.fn() },
    rpc: vi.fn(),
    from: vi.fn(),
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))

/** Lo que la query de factura duplicada recibe y devuelve. */
const mismaFactura = vi.fn((_criterio: { proveedorId: string | null; numeroFactura: string }) => ({ data: [] as unknown[] }))

vi.mock('../../hooks/queries/useComprasQuery', () => ({
  useCargosPlantillaProveedorQuery: () => ({ data: null, isLoading: false }),
  // Variación de costo contra la compra anterior: sin anteriores.
  useCostosAnterioresQuery: () => ({ data: undefined }),
  useComprasMismaFacturaQuery: (criterio: { proveedorId: string | null; numeroFactura: string }) => mismaFactura(criterio),
}))

// Catálogo de cargos y medidas (mig 278): vacío, como antes de la migración.
vi.mock('../../hooks/queries/useCargosCatalogoQuery', () => {
  // Referencias estables: el modal sincroniza su estado cuando cambian.
  const conceptos: unknown[] = [], medidas: unknown[] = [], ficha = {}
  return {
    useCargoConceptosQuery: () => ({ data: conceptos }),
    useCargoMedidasQuery: () => ({ data: medidas }),
    useProductoMedidasQuery: () => ({ data: ficha }),
  }
})
// Promociones del proveedor (#908): ninguna, como antes de la migración.
vi.mock('../../hooks/queries/usePromocionesProveedorQuery', () => {
  const promos: unknown[] = []
  return { usePromocionesProveedorQuery: () => ({ data: promos }) }
})
vi.mock('../../hooks/queries/useImpuestosInternosQuery', () => ({
  useCatalogoIIQuery: () => ({ data: { encuadres: [], alicuotas: [] } }),
}))

/** El alta de proveedor, stubbeada: sólo importa con qué nombre arranca. */
vi.mock('./ModalProveedor', () => ({
  default: ({ nombreInicial }: { nombreInicial?: string }) => (
    <div>
      <h2>Nuevo Proveedor</h2>
      <p>Arranca con: {nombreInicial || '(vacío)'}</p>
    </div>
  ),
}))

vi.mock('./ModalImportarCompra', () => ({ default: () => null }))

import ModalCompra, { type ModalCompraProps } from './ModalCompra'
import { claveBorradorCompra, serializarBorrador } from '../../utils/borradorCompra'
import { compraReducer, initialState } from './ModalCompra.reducer'

const PRODUCTOS = [
  { id: 'p1', nombre: 'Aceite Girasol 900ml', codigo: 'ACE900', stock: 12, costo_sin_iva: 100, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' },
  { id: 'p2', nombre: 'Fideos 500g', codigo: 'FID500', stock: 30, costo_sin_iva: 50, impuestos_internos: 0, porcentaje_iva: 21, condicion_iva: 'gravado' },
] as unknown as ProductoDB[]

const PROVEEDORES = [
  { id: 'prov-1', nombre: 'Manaos SA', cuit: '30-11111111-1' },
  { id: 'prov-2', nombre: 'José Farías e Hijos', cuit: '30-71234567-8' },
] as unknown as ProveedorDBExtended[]

const CLAVE = claveBorradorCompra(1, 'u1')

type OnSave = NonNullable<ModalCompraProps['onSave']>

function renderModal(over: { conBorrador?: boolean; productos?: ProductoDB[] } = {}) {
  const onSave = vi.fn<OnSave>(() => Promise.resolve())
  const onClose = vi.fn()
  const utils = render(
    <ModalCompra
      productos={over.productos ?? PRODUCTOS}
      proveedores={PROVEEDORES}
      onSave={onSave}
      onClose={onClose}
      onCrearProveedor={vi.fn()}
      sucursalId={over.conBorrador === false ? null : 1}
      usuarioId={over.conBorrador === false ? null : 'u1'}
    />,
  )
  return { ...utils, onSave, onClose, user: userEvent.setup({ advanceTimers: vi.advanceTimersByTime }) }
}

const comboProveedor = () => screen.getByRole('combobox', { name: 'Proveedor de la factura' })
const listaProveedores = () => screen.getByRole('listbox', { name: 'Proveedor de la factura' })

async function agregarProducto(user: ReturnType<typeof userEvent.setup>, nombre: string) {
  await user.click(screen.getByPlaceholderText('Buscar producto por nombre o codigo...'))
  await user.click(screen.getByRole('button', { name: new RegExp(nombre) }))
}

beforeEach(() => {
  vi.useFakeTimers({ shouldAdvanceTime: true })
  window.localStorage.clear()
  mismaFactura.mockClear()
  mismaFactura.mockImplementation(() => ({ data: [] }))
})

afterEach(() => {
  vi.useRealTimers()
})

describe('buscador de proveedor', () => {
  it('encuentra por CUIT y sin tildes', async () => {
    const { user } = renderModal()
    await user.type(comboProveedor(), '3071234')
    expect(within(listaProveedores()).getAllByRole('option').map(o => o.textContent)).toEqual([
      'José Farías e Hijos30-71234567-8',
      // Siempre se ofrece el alta con lo tipeado, salvo que sea un nombre exacto.
      '+ Nuevo proveedor "3071234"',
    ])
    await user.clear(comboProveedor())
    await user.type(comboProveedor(), 'farias{Enter}')
    expect(comboProveedor()).toHaveValue('José Farías e Hijos')
  })

  it('"+ Nuevo proveedor" abre el alta con lo tipeado', async () => {
    const { user } = renderModal()
    await user.type(comboProveedor(), 'Aguas del Sur')
    await user.click(within(listaProveedores()).getByRole('option', { name: '+ Nuevo proveedor "Aguas del Sur"' }))
    expect(await screen.findByText('Arranca con: Aguas del Sur')).toBeInTheDocument()
  })

  it('Escape con la lista abierta la cierra a ella, no al modal', async () => {
    const { user, onClose } = renderModal()
    await user.click(comboProveedor())
    expect(comboProveedor()).toHaveAttribute('aria-expanded', 'true')
    await user.keyboard('{Escape}')
    expect(onClose).not.toHaveBeenCalled()
    expect(comboProveedor()).toHaveAttribute('aria-expanded', 'false')
  })
})

describe('factura duplicada al cabezal', () => {
  it('avisa al salir del número, con el número y la fecha de la otra compra, y no bloquea', async () => {
    mismaFactura.mockImplementation(({ proveedorId, numeroFactura }) => ({
      data: proveedorId === 'prov-1' && numeroFactura === 'A0005-00467758'
        ? [{ id: '304', numeroFactura: '0005-00467758', fechaCompra: '2026-10-01', total: 1000 }]
        : [],
    }))
    const { user, onSave } = renderModal({ conBorrador: false })
    await user.type(comboProveedor(), 'manaos{Enter}')
    await user.type(screen.getByPlaceholderText('Ej: 0001-00012345'), 'A0005-00467758')
    // Mientras se tipea, nada.
    expect(screen.queryByText(/Ya hay una compra/)).toBeNull()
    await user.tab()

    const aviso = screen.getByRole('status')
    expect(aviso).toHaveTextContent('Ya hay una compra con este número: #304 del 01/10')
    await user.click(within(aviso).getByRole('button', { name: '(ver)' }))
    expect(aviso).toHaveTextContent('factura 0005-00467758')

    // No borra ni bloquea: se registra igual.
    await agregarProducto(user, 'Aceite Girasol 900ml')
    await user.click(screen.getByRole('button', { name: /registrar compra/i }))
    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0]).toMatchObject({ numeroFactura: 'A0005-00467758', proveedorId: 'prov-1' })
  })
})

describe('cuadre fijo al pie', () => {
  it('muestra el total calculado y la diferencia contra la factura', async () => {
    const { user } = renderModal({ conBorrador: false })
    expect(screen.queryByRole('group', { name: 'Cuadre contra la factura' })).toBeNull()

    await agregarProducto(user, 'Aceite Girasol 900ml')
    const barra = screen.getByRole('group', { name: 'Cuadre contra la factura' })
    // 1 × 100 + 21% de IVA.
    expect(barra).toHaveTextContent('Total calculado')
    expect(within(barra).getByTestId('cuadre-diferencia')).toHaveTextContent('Dif. —')

    const factura = within(barra).getByRole('textbox', { name: 'Total impreso en la factura' })
    await user.type(factura, '130')
    expect(within(barra).getByTestId('cuadre-diferencia')).toHaveTextContent(/Dif\..*9/)

    await user.clear(factura)
    await user.type(factura, '121')
    expect(within(barra).getByTestId('cuadre-diferencia')).toHaveTextContent('✓ Cierra')
  })
})

describe('borrador local', () => {
  const sembrarBorrador = (productoId = 'p1') => {
    const producto = { ...PRODUCTOS[0], id: productoId, nombre: productoId === 'p1' ? 'Aceite Girasol 900ml' : 'Producto Borrado' } as ProductoDB
    const estado = [
      { type: 'SET_PROVEEDOR_ID', payload: 'prov-1' },
      { type: 'SET_NUMERO_FACTURA', payload: '0005-00001234' },
      { type: 'AGREGAR_ITEM', payload: producto },
      { type: 'AGREGAR_CARGO' },
      { type: 'SET_PESO_CARGO', payload: { cargoId: 1, lineaId: 1, peso: 3 } },
    ].reduce((s, a) => compraReducer(s, a as Parameters<typeof compraReducer>[1]), initialState)
    window.localStorage.setItem(CLAVE, serializarBorrador(estado, new Date(2026, 9, 3, 14, 20)))
  }

  it('al abrir lo ofrece y no deja cargar hasta decidir; retomar trae todo', async () => {
    sembrarBorrador()
    const { user } = renderModal()

    expect(screen.queryByRole('combobox', { name: 'Proveedor de la factura' })).toBeNull()
    await user.click(screen.getByRole('button', { name: 'Retomar borrador del 03/10 14:20 (1 línea)' }))

    expect(comboProveedor()).toHaveValue('Manaos SA')
    expect(screen.getByPlaceholderText('Ej: 0001-00012345')).toHaveValue('0005-00001234')
    expect(screen.getAllByText('Aceite Girasol 900ml').length).toBeGreaterThan(0)
    expect(screen.queryByText(/ya no existe o está inactivo/)).toBeNull()
  })

  it('descartar lo borra y deja la compra vacía', async () => {
    sembrarBorrador()
    const { user } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Descartar' }))
    expect(window.localStorage.getItem(CLAVE)).toBeNull()
    expect(comboProveedor()).toHaveValue('')
  })

  it('cerrar sin decidir no lo tira', async () => {
    sembrarBorrador()
    const { unmount } = renderModal()
    unmount()
    expect(window.localStorage.getItem(CLAVE)).not.toBeNull()
  })

  it('marca las líneas cuyo producto ya no existe', async () => {
    sembrarBorrador('p-borrado')
    const { user } = renderModal()
    await user.click(screen.getByRole('button', { name: /Retomar borrador/ }))
    expect(screen.getByText(/Este producto ya no existe o está inactivo/)).toBeInTheDocument()
  })

  it('autosave mientras se carga y, al registrar, se borra y no vuelve', async () => {
    const { user, unmount } = renderModal()
    await user.type(comboProveedor(), 'manaos{Enter}')
    await agregarProducto(user, 'Aceite Girasol 900ml')
    act(() => { vi.advanceTimersByTime(1000) })
    expect(window.localStorage.getItem(CLAVE)).not.toBeNull()

    await user.click(screen.getByRole('button', { name: /registrar compra/i }))
    expect(window.localStorage.getItem(CLAVE)).toBeNull()
    act(() => { vi.advanceTimersByTime(5000) })
    unmount()
    expect(window.localStorage.getItem(CLAVE)).toBeNull()
  })

  it('avisa si otra pestaña registra o descarta la misma compra', async () => {
    const { user } = renderModal()
    await user.type(comboProveedor(), 'manaos{Enter}')
    act(() => {
      fireEvent(window, new StorageEvent('storage', { key: CLAVE, newValue: null }))
    })
    expect(screen.getByRole('alert')).toHaveTextContent('En otra pestaña esta compra se registró o se descartó')
  })
})
