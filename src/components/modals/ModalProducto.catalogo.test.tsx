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

// Sólo se montan en edición y arrastran sus propias queries.
vi.mock('../productos/ProductoCondicionesMayoristas', () => ({
  default: () => null,
}))
vi.mock('../productos/ProductoLotes', () => ({
  default: () => null,
}))
vi.mock('../productos/ProductoMedidas', () => ({
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

/**
 * El encuadre de impuestos internos (mig 277). La ficha ya no tipea una tasa:
 * elige un encuadre y costea con la MISMA tasa que la base le va a poner al
 * guardar (`derivar_ii_producto`). Si costeara con otra, el producto nacería con
 * un costo real y un costo promedio que no coinciden con su propio II.
 */
describe('ModalProducto — encuadre de impuestos internos', () => {
  beforeEach(() => vi.clearAllMocks())

  it('elegir General costea con 8,6957% y manda el encuadre', async () => {
    const { onSave, user } = renderFicha()

    await user.selectOptions(screen.getByLabelText('Imp. internos (encuadre)'), '1')
    expect(screen.getByText(/8% nominal · 8,6957% sobre el neto/)).toBeInTheDocument()
    await user.click(guardar())

    const payload = onSave.mock.calls[0][0]
    expect(payload.ii_encuadre_id).toBe('1')
    expect(payload.impuestos_internos).toBe(8.6957)
    // 24.300 × 1,086957 — el costo real que la ficha persiste.
    expect(payload.costo_real).toBeCloseTo(24300 * 1.086957, 2)
  })

  it('la tasa no es un campo editable: no hay input de porcentaje de II', () => {
    renderFicha()
    expect(screen.queryByLabelText('Imp. Internos (%)')).not.toBeInTheDocument()
  })

  it('una ficha sin encuadre conserva y muestra la tasa heredada', () => {
    renderFicha({ ...GASEOSA, impuestos_internos: 9.18, ii_encuadre_id: null } as unknown as ProductoDB)

    expect((screen.getByLabelText('Imp. internos (encuadre)') as HTMLSelectElement).value).toBe('')
    expect(screen.getByText(/Sin definir · conserva 9,18% sobre el neto/)).toBeInTheDocument()
  })
})
