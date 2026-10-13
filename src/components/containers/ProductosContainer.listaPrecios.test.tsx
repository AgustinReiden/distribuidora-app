/**
 * El botón "Lista de precios" de Productos: arma el PDF con los datos leídos en
 * el momento (no con la caché), muestra que está trabajando y, si falla, avisa
 * con el mensaje real normalizado.
 */
import React from 'react'
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

const espias = vi.hoisted(() => ({
  fetchDatosListaPrecios: vi.fn(),
  generarListaPrecios: vi.fn(),
  notificarError: vi.fn(),
}))

vi.mock('../../hooks/queries', () => {
  const mut = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    useProductosQuery: () => ({ data: [], isLoading: false, isError: false, refetch: vi.fn() }),
    useCatalogoDepositoQuery: () => ({ data: [], isLoading: false, isError: false, refetch: vi.fn() }),
    useCrearProductoMutation: mut,
    useActualizarProductoMutation: mut,
    useEliminarProductoMutation: mut,
    useRegistrarMermaMutation: mut,
    useRegistrarCambioProductoMutation: mut,
    useCrearGrupoPrecioMutation: mut,
    useProveedoresActivosQuery: () => ({ data: [] }),
    useClientesQuery: () => ({ data: [] }),
    useCategoriasQuery: () => ({ data: [] }),
    useSubcategoriasQuery: () => ({ data: [] }),
    useGruposPrecioQuery: () => ({ data: [] }),
    useAsegurarCatalogo: () => ({ asegurar: vi.fn(), creando: false }),
    usePromocionesListQuery: () => ({ data: [] }),
    fetchDatosListaPrecios: espias.fetchDatosListaPrecios,
  }
})
vi.mock('../../hooks/queries/useControlStockQuery', () => ({ useAplicarControlStockMutation: () => ({ mutateAsync: vi.fn() }) }))
vi.mock('../../contexts/AuthDataContext', () => ({ useAuthData: () => ({ isAdmin: false, perfil: { rol: 'preventista' } }) }))
vi.mock('../../contexts/NotificationContext', () => ({ useNotification: () => ({ error: espias.notificarError, success: vi.fn() }) }))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalNombre: 'Taco Pozo' }) }))
vi.mock('../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => {} }))
vi.mock('../../lib/pdf', () => ({ generarListaPrecios: espias.generarListaPrecios }))
vi.mock('../../assets/marca/crecer-logo.png?inline', () => ({ default: 'data:image/png;base64,LOGO' }))
vi.mock('../vistas/VistaProductos', () => ({
  default: (props: { onListaPrecios?: () => void; generandoListaPrecios?: boolean }) => (
    <button type="button" onClick={props.onListaPrecios} disabled={props.generandoListaPrecios}>
      Lista de precios
    </button>
  ),
}))

import ProductosContainer from './ProductosContainer'

const DATOS = {
  productos: [
    { id: '1', nombre: 'AGUA 2L', precio: 900, activo: true, categoria: 'AGUAS', subcategoria_id: null },
    { id: '2', nombre: 'VIEJO', precio: 500, activo: false, categoria: 'AGUAS', subcategoria_id: null },
  ],
  grupos: [],
  nombresSubrubro: new Map(),
}

const montar = () => render(<MemoryRouter><ProductosContainer /></MemoryRouter>)
const boton = () => screen.findByRole('button', { name: 'Lista de precios' }, { timeout: 15000 })

describe('ProductosContainer: lista de precios en PDF', () => {
  beforeEach(() => vi.clearAllMocks())

  it('lee los datos al tocar el botón y arma el PDF de la sucursal activa, con el logo', async () => {
    espias.fetchDatosListaPrecios.mockResolvedValue(DATOS)
    const user = userEvent.setup()
    montar()
    expect(espias.fetchDatosListaPrecios).not.toHaveBeenCalled()

    await user.click(await boton())

    await waitFor(() => expect(espias.generarListaPrecios).toHaveBeenCalledTimes(1))
    expect(espias.fetchDatosListaPrecios).toHaveBeenCalledTimes(1)
    expect(espias.generarListaPrecios).toHaveBeenCalledWith({
      secciones: [
        { rubro: 'AGUAS', subrubro: null, sinCategoria: false, filas: [{ nombre: 'AGUA 2L', precio: 900, condicion: [] }] },
      ],
      sucursal: 'Taco Pozo',
      logo: 'data:image/png;base64,LOGO',
    })
    expect(espias.notificarError).not.toHaveBeenCalled()
  })

  it('mientras arma la lista el botón queda deshabilitado, y vuelve cuando termina', async () => {
    let resolver: (datos: typeof DATOS) => void = () => {}
    espias.fetchDatosListaPrecios.mockReturnValue(new Promise(r => { resolver = r }))
    const user = userEvent.setup()
    montar()

    await user.click(await boton())
    await waitFor(async () => expect(await boton()).toBeDisabled())

    resolver(DATOS)
    await waitFor(async () => expect(await boton()).toBeEnabled())
    expect(espias.generarListaPrecios).toHaveBeenCalledTimes(1)
  })

  it('si falla, avisa con el mensaje real (aunque no sea un Error) y no genera nada', async () => {
    // supabase-js rechaza con un objeto plano, no con un Error.
    espias.fetchDatosListaPrecios.mockRejectedValue({
      message: 'Sin conexión: no se pudo armar la lista de precios. Revisá la señal e intentá de nuevo.',
    })
    const user = userEvent.setup()
    montar()

    await user.click(await boton())

    await waitFor(() => expect(espias.notificarError).toHaveBeenCalledWith(
      'Sin conexión: no se pudo armar la lista de precios. Revisá la señal e intentá de nuevo.',
    ))
    expect(espias.generarListaPrecios).not.toHaveBeenCalled()
    expect(await boton()).toBeEnabled()
  })
})
