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
import { describe, it, expect, vi } from 'vitest'
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

function renderModal() {
  const onCrearProductoRapido = vi.fn(async (d: ProductoRapidoInput) => (
    { id: 'p-nuevo', nombre: d.nombre, codigo: d.codigo, costo_sin_iva: d.costoSinIva } as unknown as ProductoDB
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

/** El select de proveedor de la factura: se lo ubica por su opción vacía, que es única. */
const proveedorFactura = () =>
  screen.getByRole('option', { name: 'Seleccionar proveedor...' }).closest('select') as HTMLSelectElement

const abrirAltaRapida = (user: ReturnType<typeof userEvent.setup>) =>
  user.click(screen.getByRole('button', { name: 'Crear producto nuevo' }))

async function crear(user: ReturnType<typeof userEvent.setup>, nombre = 'PAPEL HIGIENICO SOL MAYOR x 4') {
  await user.type(screen.getByPlaceholderText('Nombre del producto'), nombre)
  await user.click(screen.getByRole('button', { name: /crear y agregar/i }))
}

describe('ModalCompra — alta rápida: proveedor', () => {
  it('arranca en el proveedor de la factura y viaja con el alta', async () => {
    const { user, onCrearProductoRapido } = renderModal()

    await user.selectOptions(proveedorFactura(), 'prov-1')
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

    await user.selectOptions(proveedorFactura(), 'prov-2')

    expect(screen.getByLabelText('Proveedor')).toHaveValue('prov-2')
  })

  it('elegido a mano, deja de seguir a la factura', async () => {
    const { user, onCrearProductoRapido } = renderModal()

    await user.selectOptions(proveedorFactura(), 'prov-1')
    await abrirAltaRapida(user)
    await user.selectOptions(screen.getByLabelText('Proveedor'), 'prov-3')
    await user.selectOptions(proveedorFactura(), 'prov-2')

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

    await user.selectOptions(proveedorFactura(), 'prov-1')
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
