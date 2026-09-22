/**
 * La ficha: "+ Nueva categoría" y "+ Nueva marca".
 *
 * Lo tipeado viaja APARTE de lo elegido en la lista, y lo crea el container
 * antes que el producto (`useAsegurarCatalogo`). Antes el nombre nuevo de
 * categoría iba directo a `categoria` como texto, nadie creaba la fila en
 * `categorias`, y el producto quedaba sin `categoria_id` (25 así en prod al
 * 22/09/2026). La marca no tenía el botón, y la categoría hacía de marca: FRAU y
 * MANITO están cargadas como categorías.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalProducto from './ModalProducto'
import type { ProductoDB } from '../../types'

vi.mock('../../hooks/queries', () => ({
  useMarcasQuery: () => ({
    data: [
      { id: 'm-1', nombre: 'MANAOS', activa: true },
      { id: 'm-2', nombre: 'DESCONTINUADA', activa: false },
    ],
  }),
}))

// Sólo se montan en edición y arrastran sus propias queries.
vi.mock('../productos/ProductoCondicionesMayoristas', () => ({
  default: () => null,
}))
vi.mock('../productos/ProductoLotes', () => ({
  default: () => null,
}))

const GASEOSA = {
  id: '340',
  nombre: 'COCA COLA X 3LTS X 6UND',
  precio: 26700,
  stock: 26,
  stock_minimo: 10,
  categoria: 'GASEOSAS',
  marca_id: 'm-1',
  costo_sin_iva: 24300,
  porcentaje_iva: 21,
  condicion_iva: 'gravado',
} as unknown as ProductoDB

function renderFicha(producto: ProductoDB = GASEOSA) {
  const onSave = vi.fn()
  render(
    <ModalProducto
      producto={producto}
      categorias={['GASEOSAS', 'AGUAS']}
      proveedores={[]}
      onSave={onSave}
      onClose={vi.fn()}
      guardando={false}
      esAdmin
    />,
  )
  return { onSave, user: userEvent.setup() }
}

const guardar = () => screen.getByRole('button', { name: /Guardar/ })

describe('ModalProducto — categoría y marca nuevas', () => {
  beforeEach(() => vi.clearAllMocks())

  it('la marca nueva viaja aparte; la elegida queda como estaba para que el container la reemplace', async () => {
    const { onSave, user } = renderFicha()

    await user.click(screen.getByRole('button', { name: '+ Nueva marca' }))
    await user.type(screen.getByLabelText('Marca'), 'frau')
    await user.click(guardar())

    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0]).toMatchObject({ marca_nueva: 'frau', marca_id: 'm-1' })
  })

  it('la categoría nueva ya no se escribe como texto de `categoria`', async () => {
    const { onSave, user } = renderFicha()

    await user.click(screen.getByRole('button', { name: '+ Nueva categoría' }))
    await user.type(screen.getByLabelText('Categoría'), 'bebidas')
    await user.click(guardar())

    // Antes `categoria` salía 'bebidas' y el producto quedaba sin categoria_id.
    expect(onSave.mock.calls[0][0]).toMatchObject({ categoria_nueva: 'bebidas', categoria: 'GASEOSAS' })
  })

  it('"Elegir existente" descarta lo tipeado y vale lo elegido', async () => {
    const { onSave, user } = renderFicha({ ...GASEOSA, marca_id: null } as unknown as ProductoDB)

    await user.click(screen.getByRole('button', { name: '+ Nueva marca' }))
    await user.type(screen.getByLabelText('Marca'), 'frau')
    await user.click(screen.getByRole('button', { name: 'Elegir existente' }))
    await user.selectOptions(screen.getByLabelText('Marca'), 'm-1')
    await user.click(guardar())

    const payload = onSave.mock.calls[0][0]
    expect(payload.marca_nueva).toBeUndefined()
    expect(payload.marca_id).toBe('m-1')
  })

  it('un nombre de puros espacios no cuenta como nuevo', async () => {
    const { onSave, user } = renderFicha()

    await user.click(screen.getByRole('button', { name: '+ Nueva categoría' }))
    await user.type(screen.getByLabelText('Categoría'), '   ')
    await user.click(guardar())

    const payload = onSave.mock.calls[0][0]
    expect(payload.categoria_nueva).toBeUndefined()
    expect(payload.categoria).toBe('GASEOSAS')
  })

  it('la lista de marcas ofrece sólo las activas', () => {
    renderFicha()

    const opciones = within(screen.getByLabelText('Marca')).getAllByRole('option').map(o => o.textContent)
    expect(opciones).toEqual(['Sin marca', 'MANAOS'])
  })
})
