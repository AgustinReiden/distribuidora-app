/**
 * El alta rápida de un producto desde la factura: categoría, marca y proveedor.
 *
 * Lo pidió una usuaria que carga facturas: el producto que creaba desde la
 * compra nacía sin categoría, sin marca y sin proveedor, y había que ir después
 * a la ficha a completarlo. Ahora el alta los trae, y el proveedor arranca en el
 * de la factura.
 *
 * Lo que se fija acá es lo que el formulario manda. Crear la categoría o la marca
 * nueva lo hace el container (ver `ComprasContainer.productoRapido.test`).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ProductoDB, ProveedorDBExtended } from '../../types'
import type { CategoriaDB } from '../../hooks/queries/useCategoriasQuery'
import type { MarcaDB } from '../../hooks/queries/useMarcasQuery'

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

vi.mock('../../hooks/queries/useComprasQuery', () => ({
  useCargosPlantillaProveedorQuery: () => ({ data: null, isLoading: false }),
  // El aviso de factura duplicada: sin compras previas.
  // Variación de costo contra la compra anterior: sin anteriores.
  useCostosAnterioresQuery: () => ({ data: undefined }),
  useComprasMismaFacturaQuery: () => ({ data: [] }),
}))

// Encuadres de impuestos internos (mig 277): los ofrece el alta rápida.
vi.mock('../../hooks/queries/useImpuestosInternosQuery', () => ({
  useCatalogoIIQuery: () => ({
    data: {
      encuadres: [
        { id: '1', nombre: 'General', criterio: 'Sin jugo', activo: true },
        { id: '2', nombre: 'Reducida', criterio: 'Con jugo o agua', activo: true },
      ],
      alicuotas: [
        { id: '1', encuadre_id: '1', tasa_nominal: 0.08, vigente_desde: '2000-01-01', vigente_hasta: null },
        { id: '2', encuadre_id: '2', tasa_nominal: 0.04, vigente_desde: '2000-01-01', vigente_hasta: null },
      ],
    },
  }),
}))

import ModalCompra, { type ProductoRapidoInput } from './ModalCompra'

const PROVEEDORES = [
  { id: 'prov-1', nombre: 'JOSE FARIAS E HIJOS SRL', cuit: '30-11111111-1' },
  { id: 'prov-2', nombre: 'Distribuidora Norte', cuit: null },
  { id: 'prov-3', nombre: 'Manaos SA', cuit: null },
] as unknown as ProveedorDBExtended[]

const CATEGORIAS = [
  { id: 'c-1', nombre: 'PAPEL HIGIENICO', activa: true },
  { id: 'c-2', nombre: 'VIEJA', activa: false },
] as unknown as CategoriaDB[]

const MARCAS = [
  { id: 'm-1', nombre: 'SOL MAYOR', activa: true },
  { id: 'm-2', nombre: 'DESCONTINUADA', activa: false },
] as unknown as MarcaDB[]

/** `devuelto`: lo que la base agrega al producto creado (ej. el II derivado del encuadre). */
function renderModal(devuelto: Record<string, unknown> = {}) {
  const onCrearProductoRapido = vi.fn(async (d: ProductoRapidoInput) => (
    { id: 'p-nuevo', nombre: d.nombre, codigo: d.codigo, costo_sin_iva: d.costoSinIva, ...devuelto } as unknown as ProductoDB
  ))
  render(
    <ModalCompra
      productos={[]}
      proveedores={PROVEEDORES}
      categorias={CATEGORIAS}
      marcas={MARCAS}
      onSave={vi.fn()}
      onClose={vi.fn()}
      onCrearProductoRapido={onCrearProductoRapido}
    />,
  )
  return { onCrearProductoRapido, user: userEvent.setup() }
}

/** Elige el proveedor de la factura en su buscador (ui/Combobox). */
async function elegirProveedorFactura(user: ReturnType<typeof userEvent.setup>, nombre: string) {
  const combo = screen.getByRole('combobox', { name: 'Proveedor de la factura' })
  await user.click(combo)
  await user.type(combo, nombre)
  await user.click(within(screen.getByRole('listbox', { name: 'Proveedor de la factura' })).getByRole('option', { name: new RegExp(nombre) }))
}

const abrirAltaRapida = (user: ReturnType<typeof userEvent.setup>) =>
  user.click(screen.getByRole('button', { name: 'Crear producto nuevo' }))

async function crear(user: ReturnType<typeof userEvent.setup>, nombre = 'PAPEL HIGIENICO SOL MAYOR x 4') {
  await user.type(screen.getByPlaceholderText('Nombre del producto'), nombre)
  await user.click(screen.getByRole('button', { name: /crear y agregar/i }))
}

describe('ModalCompra — alta rápida: proveedor', () => {
  it('arranca en el proveedor de la factura y viaja con el alta', async () => {
    const { user, onCrearProductoRapido } = renderModal()

    await elegirProveedorFactura(user, 'JOSE FARIAS E HIJOS SRL')
    await abrirAltaRapida(user)

    expect(screen.getByLabelText('Proveedor')).toHaveValue('prov-1')

    await crear(user)

    expect(onCrearProductoRapido).toHaveBeenCalledWith(expect.objectContaining({
      nombre: 'PAPEL HIGIENICO SOL MAYOR x 4',
      proveedorId: 'prov-1',
      categoria: '',
      marcaId: '',
    }))
  })

  it('si la factura se elige con el alta ya abierta, el proveedor la sigue', async () => {
    const { user } = renderModal()

    await abrirAltaRapida(user)
    expect(screen.getByLabelText('Proveedor')).toHaveValue('')

    await elegirProveedorFactura(user, 'Distribuidora Norte')

    expect(screen.getByLabelText('Proveedor')).toHaveValue('prov-2')
  })

  it('elegido a mano, deja de seguir a la factura', async () => {
    const { user, onCrearProductoRapido } = renderModal()

    await elegirProveedorFactura(user, 'JOSE FARIAS E HIJOS SRL')
    await abrirAltaRapida(user)
    await user.selectOptions(screen.getByLabelText('Proveedor'), 'prov-3')
    await elegirProveedorFactura(user, 'Distribuidora Norte')

    expect(screen.getByLabelText('Proveedor')).toHaveValue('prov-3')

    await crear(user)

    expect(onCrearProductoRapido).toHaveBeenCalledWith(expect.objectContaining({ proveedorId: 'prov-3' }))
  })
})

describe('ModalCompra — alta rápida: categoría y marca', () => {
  it('ofrece sólo las activas', async () => {
    const { user } = renderModal()

    await abrirAltaRapida(user)

    const textos = (label: string) =>
      within(screen.getByLabelText(label)).getAllByRole('option').map(o => o.textContent)
    expect(textos('Categoría')).toEqual(['Sin categoría', 'PAPEL HIGIENICO'])
    expect(textos('Marca')).toEqual(['Sin marca', 'SOL MAYOR'])
  })

  it('la elegida de la lista y la tipeada como nueva viajan en el alta', async () => {
    const { user, onCrearProductoRapido } = renderModal()

    await abrirAltaRapida(user)
    await user.selectOptions(screen.getByLabelText('Categoría'), 'PAPEL HIGIENICO')
    await user.click(screen.getByRole('button', { name: '+ Nueva marca' }))
    await user.type(screen.getByLabelText('Marca'), 'higienol')
    await crear(user)

    const alta = onCrearProductoRapido.mock.calls[0][0]
    expect(alta).toMatchObject({ categoria: 'PAPEL HIGIENICO', marcaId: '', marcaNueva: 'higienol' })
    expect(alta.categoriaNueva).toBeUndefined()
  })

  it('después de crear, la próxima alta arranca limpia y otra vez en el proveedor de la factura', async () => {
    const { user } = renderModal()

    await elegirProveedorFactura(user, 'JOSE FARIAS E HIJOS SRL')
    await abrirAltaRapida(user)
    await user.selectOptions(screen.getByLabelText('Categoría'), 'PAPEL HIGIENICO')
    await user.selectOptions(screen.getByLabelText('Marca'), 'm-1')
    await user.selectOptions(screen.getByLabelText('Proveedor'), 'prov-3')
    await crear(user)

    // El alta se cierra sola al agregar la línea.
    await abrirAltaRapida(user)

    expect(screen.getByLabelText('Categoría')).toHaveValue('')
    expect(screen.getByLabelText('Marca')).toHaveValue('')
    expect(screen.getByLabelText('Proveedor')).toHaveValue('prov-1')
  })
})

/**
 * El alta rápida elige el encuadre de impuestos internos (mig 277). Sin esto el
 * producto nacía sin impuesto interno y la línea en 0: así entraron la Citrus 3L
 * y la Cola Lata, con el II afuera del costo desde la primera compra.
 */
describe('ModalCompra — alta rápida: impuestos internos', () => {
  beforeEach(() => vi.clearAllMocks())

  it('ofrece los encuadres activos y el elegido viaja con el alta', async () => {
    const { user, onCrearProductoRapido } = renderModal()

    await abrirAltaRapida(user)
    const opciones = within(screen.getByLabelText('Imp. internos')).getAllByRole('option').map(o => o.textContent)
    expect(opciones).toEqual(['Sin definir', 'General', 'Reducida'])

    await user.selectOptions(screen.getByLabelText('Imp. internos'), '2')
    await crear(user)

    expect(onCrearProductoRapido.mock.calls[0][0]).toMatchObject({ iiEncuadreId: '2' })
  })

  it('la línea nueva toma la tasa que devolvió la base, no un 0', async () => {
    const { user } = renderModal({ impuestos_internos: 4.1667 })

    await abrirAltaRapida(user)
    await user.selectOptions(screen.getByLabelText('Imp. internos'), '2')
    await crear(user)

    expect(await screen.findAllByText('4,1667%')).not.toHaveLength(0)
  })
})
