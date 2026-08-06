import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { CondicionMayoristaProducto } from '../../utils/condicionesMayoristas'
import type { GrupoPrecioConDetalles } from '../../types'

const actualizarEscala = vi.fn(() => Promise.resolve())
const eliminarEscala = vi.fn(() => Promise.resolve())
const agregarACondicion = vi.fn(() => Promise.resolve())
const quitarDeCondicion = vi.fn(() => Promise.resolve())
const crearEscala = vi.fn(() => Promise.resolve())

let condiciones: CondicionMayoristaProducto[] = []
let grupos: GrupoPrecioConDetalles[] = []

vi.mock('../../hooks/queries', () => ({
  useProductosQuery: () => ({
    data: [
      { id: 'p1', nombre: 'Fideo Mostachol' },
      { id: 'p2', nombre: 'Fideo Codito' },
      { id: 'p3', nombre: 'Fideo Tirabuzón' },
    ],
    isLoading: false,
  }),
  useGruposPrecioQuery: () => ({ data: grupos, isLoading: false }),
  useGruposPrecioPorProductoQuery: () => ({ condiciones, isLoading: false, error: null }),
  useActualizarPrecioEscalaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useActualizarEscalaMutation: () => ({ mutateAsync: actualizarEscala, isPending: false }),
  useEliminarEscalaMutation: () => ({ mutateAsync: eliminarEscala, isPending: false }),
  useAgregarProductoACondicionMutation: () => ({ mutateAsync: agregarACondicion, isPending: false }),
  useQuitarProductoDeCondicionMutation: () => ({ mutateAsync: quitarDeCondicion, isPending: false }),
  useCrearEscalaMutation: () => ({ mutateAsync: crearEscala, isPending: false }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn() }),
}))

import ProductoCondicionesMayoristas from './ProductoCondicionesMayoristas'

function condicion(over: Partial<CondicionMayoristaProducto> = {}): CondicionMayoristaProducto {
  return {
    grupoId: 'g1',
    grupoNombre: 'Fideos por bulto',
    descripcion: null,
    activo: true,
    cantidadProductos: 3,
    escalas: [
      {
        escalaId: 'e1',
        cantidadMinima: 12,
        precioGrupo: 800,
        precioOverride: null,
        precioEfectivo: 800,
        esOverride: false,
        activo: true,
        escala: {
          cantidadMinima: 12,
          precioUnitario: 800,
          etiqueta: null,
          minProductosDistintos: 1,
          minimosPorProducto: new Map(),
        },
      },
    ],
    ...over,
  }
}

/** Condición del catálogo, para el selector de "sumar a una condición". */
function grupo(over: Partial<GrupoPrecioConDetalles> = {}): GrupoPrecioConDetalles {
  return {
    id: 'g1',
    nombre: 'Fideos por bulto',
    activo: true,
    productos: [
      { id: 'gp1', grupo_precio_id: 'g1', producto_id: 'p1' },
      { id: 'gp2', grupo_precio_id: 'g1', producto_id: 'p2' },
      { id: 'gp3', grupo_precio_id: 'g1', producto_id: 'p3' },
    ],
    escalas: [],
    ...over,
  } as GrupoPrecioConDetalles
}

// Producto de $1000 final, IVA 21, costo total $600, costo real $500.
const props = {
  productoId: 'p1',
  precioLista: 1000,
  costoTotal: 600,
  costoReal: 500,
  porcentajeIva: 21,
}

beforeEach(() => {
  vi.clearAllMocks()
  condiciones = []
  grupos = []
})

describe('ProductoCondicionesMayoristas', () => {
  it('avisa cuando el producto no está en ninguna condición', () => {
    render(<ProductoCondicionesMayoristas {...props} />)
    expect(screen.getByText(/no está en ninguna condición mayorista/i)).toBeInTheDocument()
  })

  it('muestra la regla, el precio y los dos márgenes de la escala', () => {
    condiciones = [condicion()]
    render(<ProductoCondicionesMayoristas {...props} />)

    expect(screen.getByText('Fideos por bulto')).toBeInTheDocument()
    expect(screen.getByText(/12\+ unidades/)).toBeInTheDocument()
    // Bruto: 800 vs costo total 600 → 33.3%
    expect(screen.getByText(/Bruto 33\.3%/)).toBeInTheDocument()
    // Neto: 800/1.21 = 661.16 vs costo real 500 → 32.2%
    expect(screen.getByText(/Neto 32\.2%/)).toBeInTheDocument()
    // 800 sobre una lista de 1000
    expect(screen.getByText(/20\.0% bajo lista/)).toBeInTheDocument()
  })

  it('sin permiso de edición no ofrece editar ni borrar', () => {
    condiciones = [condicion()]
    render(<ProductoCondicionesMayoristas {...props} puedeEditar={false} />)
    expect(screen.queryByRole('button', { name: /Editar la escala/ })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Eliminar la escala/ })).not.toBeInTheDocument()
    expect(screen.queryByText(/Agregar precio por cantidad/)).not.toBeInTheDocument()
  })

  it('dice con qué otros sabores se combina la condición', () => {
    condiciones = [condicion()]
    grupos = [grupo()]
    render(<ProductoCondicionesMayoristas {...props} puedeEditar />)
    // El aviso "afecta a N productos" al editar llega tarde si no se sabe
    // de antemano que la condición es compartida.
    expect(screen.getByText(/Suma con Fideo Codito, Fideo Tirabuzón/)).toBeInTheDocument()
  })

  it('al editar una escala compartida avisa que alcanza a todos', async () => {
    condiciones = [condicion()]
    const user = userEvent.setup()
    render(<ProductoCondicionesMayoristas {...props} puedeEditar />)

    await user.click(screen.getByRole('button', { name: /Editar la escala/ }))
    expect(screen.getByText(/la comparten 3 productos/i)).toBeInTheDocument()
  })

  it('una condición de un solo producto no muestra el aviso de alcance', async () => {
    condiciones = [condicion({ cantidadProductos: 1 })]
    const user = userEvent.setup()
    render(<ProductoCondicionesMayoristas {...props} puedeEditar />)

    await user.click(screen.getByRole('button', { name: /Editar la escala/ }))
    expect(screen.queryByText(/la comparten/i)).not.toBeInTheDocument()
  })

  it('el margen se recalcula con lo tipeado, antes de guardar', async () => {
    condiciones = [condicion()]
    const user = userEvent.setup()
    render(<ProductoCondicionesMayoristas {...props} puedeEditar />)

    await user.click(screen.getByRole('button', { name: /Editar la escala/ }))
    const precio = screen.getByLabelText('Precio mayorista')
    await user.clear(precio)
    await user.type(precio, '900')

    // 900 vs costo total 600 → 50%
    expect(screen.getByText(/Bruto 50\.0%/)).toBeInTheDocument()
    expect(screen.getByText(/10\.0% bajo lista/)).toBeInTheDocument()
  })

  it('guarda la escala editada con cantidad, precio y etiqueta', async () => {
    condiciones = [condicion()]
    const user = userEvent.setup()
    render(<ProductoCondicionesMayoristas {...props} puedeEditar />)

    await user.click(screen.getByRole('button', { name: /Editar la escala/ }))
    const cantidad = screen.getByLabelText('Cantidad mínima')
    await user.clear(cantidad)
    await user.type(cantidad, '24')
    await user.type(screen.getByLabelText('Etiqueta'), 'Fardo')
    await user.click(screen.getByRole('button', { name: 'Guardar' }))

    expect(actualizarEscala).toHaveBeenCalledWith({
      escalaId: 'e1',
      cantidadMinima: 24,
      precioUnitario: 800,
      etiqueta: 'Fardo',
    })
  })

  it('borrar una escala pide confirmación en la misma fila', async () => {
    condiciones = [condicion()]
    const user = userEvent.setup()
    render(<ProductoCondicionesMayoristas {...props} puedeEditar />)

    await user.click(screen.getByRole('button', { name: /Eliminar la escala/ }))
    expect(eliminarEscala).not.toHaveBeenCalled()

    await user.click(screen.getByRole('button', { name: /Sí, borrar/ }))
    expect(eliminarEscala).toHaveBeenCalledWith({ escalaId: 'e1' })
  })

  it('agrega un precio por cantidad a la condición', async () => {
    condiciones = [condicion()]
    const user = userEvent.setup()
    render(<ProductoCondicionesMayoristas {...props} puedeEditar />)

    await user.click(screen.getByRole('button', { name: /Agregar precio por cantidad/ }))
    await user.type(screen.getByLabelText('Cantidad mínima'), '24')
    await user.type(screen.getByLabelText('Precio mayorista'), '750')
    await user.click(screen.getByRole('button', { name: 'Agregar' }))

    expect(crearEscala).toHaveBeenCalledWith({
      grupoId: 'g1',
      cantidadMinima: 24,
      precioUnitario: 750,
      etiqueta: null,
    })
  })

  it('sin condición propia, ofrece sumarlo a una existente antes que crear una nueva', async () => {
    // Es el arreglo del fardo surtido: crear condición por sabor es lo que
    // deja la suma entre productos sin activarse.
    grupos = [grupo({ id: 'g9', nombre: 'Fideos Cotella 500g' })]
    const user = userEvent.setup()
    render(<ProductoCondicionesMayoristas {...props} puedeEditar onCrearCondicion={vi.fn()} />)

    await user.click(screen.getByRole('button', { name: /Sumar a una condición/ }))
    await user.selectOptions(screen.getByLabelText('Sumar a una condición'), 'g9')

    expect(agregarACondicion).toHaveBeenCalledWith({ grupoId: 'g9', productoId: 'p1' })
  })

  it('el selector no ofrece condiciones en las que el producto ya está', async () => {
    condiciones = [condicion()]
    grupos = [grupo(), grupo({ id: 'g9', nombre: 'Otra condición' })]
    const user = userEvent.setup()
    render(<ProductoCondicionesMayoristas {...props} puedeEditar />)

    await user.click(screen.getByRole('button', { name: /Sumar a otra condición/ }))
    const opciones = screen.getByLabelText('Sumar a una condición')
    expect(opciones).not.toHaveTextContent('Fideos por bulto')
    expect(opciones).toHaveTextContent('Otra condición')
  })

  it('sacar el producto de una condición pide confirmación', async () => {
    condiciones = [condicion()]
    const user = userEvent.setup()
    render(<ProductoCondicionesMayoristas {...props} puedeEditar />)

    await user.click(screen.getByRole('button', { name: /Sacar este producto de/ }))
    expect(quitarDeCondicion).not.toHaveBeenCalled()

    await user.click(screen.getByRole('button', { name: 'Sí' }))
    expect(quitarDeCondicion).toHaveBeenCalledWith({ grupoId: 'g1', productoId: 'p1' })
  })
})
