/**
 * La ficha: el campo Subrubro (mig 270, #828).
 *
 * Antes sólo aparecía si el rubro ya tenía subrubros; en prod no había ninguno y
 * el dueño creía que el campo no existía. Ahora se ve siempre que haya rubro, y
 * se puede tipear uno nuevo. Lo tipeado viaja aparte (`subrubro_nuevo`) y lo crea
 * el container como hijo del rubro (`useAsegurarCatalogo`, con su propio test).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalProducto from './ModalProducto'
import type { ProductoDB } from '../../types'

vi.mock('../../hooks/queries', () => ({
  useMarcasQuery: () => ({ data: [] }),
  useCatalogoIIQuery: () => ({ data: { encuadres: [], alicuotas: [] } }),
}))
vi.mock('../productos/ProductoCondicionesMayoristas', () => ({ default: () => null }))
vi.mock('../productos/ProductoLotes', () => ({ default: () => null }))
vi.mock('../productos/ProductoMedidas', () => ({ default: () => null }))

const GASEOSA = {
  id: '340',
  nombre: 'COCA COLA X 3LTS X 6UND',
  precio: 26700,
  stock: 26,
  stock_minimo: 10,
  categoria: 'GASEOSAS',
  costo_sin_iva: 24300,
  porcentaje_iva: 21,
  condicion_iva: 'gravado',
} as unknown as ProductoDB

interface Opciones {
  producto?: ProductoDB
  subrubros?: Array<{ id: string; nombre: string; rubro: string }>
  rubrosConFila?: string[]
  esAdmin?: boolean
}

function renderFicha({ producto = GASEOSA, subrubros = [], rubrosConFila, esAdmin = true }: Opciones = {}) {
  const onSave = vi.fn()
  render(
    <ModalProducto
      producto={producto}
      categorias={['GASEOSAS', 'AGUAS']}
      subrubros={subrubros}
      rubrosConFila={rubrosConFila}
      proveedores={[]}
      onSave={onSave}
      onClose={vi.fn()}
      guardando={false}
      esAdmin={esAdmin}
    />,
  )
  return { onSave, user: userEvent.setup() }
}

const guardar = () => screen.getByRole('button', { name: /Guardar/ })

describe('ModalProducto — subrubro', () => {
  beforeEach(() => vi.clearAllMocks())

  it('un rubro sin subrubros igual muestra el campo, para tipear uno nuevo', () => {
    renderFicha({ rubrosConFila: ['GASEOSAS', 'AGUAS'] })

    const campo = screen.getByLabelText('Subrubro')
    expect(campo).toBeEnabled()
    expect(campo.tagName).toBe('INPUT')
  })

  it('un subrubro tipeado viaja aparte, y no hay subcategoria_id que le gane', async () => {
    const { onSave, user } = renderFicha({
      rubrosConFila: ['GASEOSAS', 'AGUAS'],
      producto: { ...GASEOSA, subcategoria_id: 's-viejo' } as unknown as ProductoDB,
      subrubros: [{ id: 's-viejo', nombre: 'COLAS', rubro: 'GASEOSAS' }],
    })

    await user.click(screen.getByRole('button', { name: '+ Nuevo subrubro' }))
    await user.type(screen.getByLabelText('Subrubro'), 'sin azucar')
    await user.click(guardar())

    const payload = onSave.mock.calls[0][0]
    // El container lo crea como hijo de `categoria` y le pone el id al producto.
    expect(payload).toMatchObject({ categoria: 'GASEOSAS', subrubro_nuevo: 'sin azucar', subcategoria_id: null })
  })

  it('un rubro con subrubros ofrece elegir uno y también crear', async () => {
    const { onSave, user } = renderFicha({
      rubrosConFila: ['GASEOSAS', 'AGUAS'],
      subrubros: [{ id: 's-1', nombre: 'COLAS', rubro: 'GASEOSAS' }],
    })

    await user.selectOptions(screen.getByLabelText('Subrubro'), 's-1')
    expect(screen.getByRole('button', { name: '+ Nuevo subrubro' })).toBeInTheDocument()
    await user.click(guardar())

    expect(onSave.mock.calls[0][0]).toMatchObject({ subcategoria_id: 's-1' })
    expect(onSave.mock.calls[0][0].subrubro_nuevo).toBeUndefined()
  })

  it('un rubro que no es fila de categorías: campo deshabilitado con el motivo', async () => {
    const { onSave, user } = renderFicha({ rubrosConFila: ['AGUAS'] })

    expect(screen.getByLabelText('Subrubro')).toBeDisabled()
    expect(screen.getByText(/todavía no está cargado en Categorías/)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: '+ Nuevo subrubro' })).not.toBeInTheDocument()
    await user.click(guardar())

    expect(onSave.mock.calls[0][0].subrubro_nuevo).toBeUndefined()
    expect(onSave.mock.calls[0][0].subcategoria_id).toBeNull()
  })

  it('sin permiso de crear no ofrece "crear"', () => {
    renderFicha({ rubrosConFila: ['GASEOSAS'], esAdmin: false })
    expect(screen.queryByLabelText('Subrubro')).not.toBeInTheDocument()
  })

  it('con un rubro nuevo tipeado, el subrubro nuevo viaja junto a él', async () => {
    const { onSave, user } = renderFicha({ rubrosConFila: ['GASEOSAS'] })

    await user.click(screen.getByRole('button', { name: '+ Nueva categoría' }))
    expect(screen.queryByLabelText('Subrubro')).not.toBeInTheDocument()
    await user.type(screen.getByLabelText('Categoría'), 'limpieza')
    await user.type(screen.getByLabelText('Subrubro'), 'lavandina')
    await user.click(guardar())

    expect(onSave.mock.calls[0][0]).toMatchObject({
      categoria_nueva: 'limpieza',
      subrubro_nuevo: 'lavandina',
      subcategoria_id: null,
    })
  })
})
