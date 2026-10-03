/**
 * Caracterizacion de `VistaProveedores` (WP-51, #775), ANTES de paginarla.
 *
 * Fija, por rol ARIA y por texto (nunca por clase), lo que el usuario ve hoy con
 * una lista CHICA —menos que una pagina—: cuantas tarjetas hay, el resumen, los
 * filtros (buscador y las tres tarjetas de estado), la lista vacia y la carga.
 *
 * La lista chica es a proposito: lo que cambia con la paginacion es lo que pasa
 * ARRIBA de una pagina, y eso lo cubre `VistaProveedores.paginacion.test.tsx`.
 * Este archivo tiene que seguir verde, sin tocarse, despues de paginar.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaProveedores, { type VistaProveedoresProps } from '../VistaProveedores'
import { formatPrecio } from '../../../utils/formatters'
import type { CompraDBExtended, ProveedorDBExtended } from '../../../types'

function proveedor(id: number, nombre: string, extra: Partial<ProveedorDBExtended> = {}): ProveedorDBExtended {
  return { id: String(id), nombre, cuit: `30-7000000${id}-1`, contacto: `Contacto ${nombre}`, activo: true, ...extra }
}

/** 5 proveedores: 3 activos y 2 inactivos. */
const PROVEEDORES: ProveedorDBExtended[] = [
  proveedor(1, 'Distribuidora Norte'),
  proveedor(2, 'Lacteos del Sur'),
  proveedor(3, 'Mayorista Centro'),
  proveedor(4, 'Envases Oeste', { activo: false }),
  proveedor(5, 'Bebidas Este', { activo: false }),
]

function compra(id: number, proveedorId: string, total: number, fecha: string): CompraDBExtended {
  return { id: String(id), proveedor_id: proveedorId, total, fecha_compra: fecha } as unknown as CompraDBExtended
}

/** Distribuidora Norte: 2 compras (1.000 + 500). Lacteos del Sur: 1 compra (250). */
const COMPRAS: CompraDBExtended[] = [
  compra(1, '1', 1000, '2026-09-01'),
  compra(2, '1', 500, '2026-09-10'),
  compra(3, '2', 250, '2026-09-05'),
]

function renderVista(overrides: Partial<VistaProveedoresProps> = {}) {
  const props: VistaProveedoresProps = {
    proveedores: PROVEEDORES,
    compras: COMPRAS,
    loading: false,
    isAdmin: true,
    onNuevoProveedor: vi.fn(),
    onEditarProveedor: vi.fn(),
    onEliminarProveedor: vi.fn(),
    onToggleActivo: vi.fn(),
    ...overrides,
  }
  render(<VistaProveedores {...props} />)
  return props
}

/** `formatPrecio` separa el signo con un espacio duro; el texto del DOM llega normalizado. */
const monto = (n: number) => formatPrecio(n).replace(/\s+/g, ' ')

/** Una tarjeta por proveedor: su nombre es el unico h3. */
const nombresDeTarjetas = () => screen.getAllByRole('heading', { level: 3 }).map(h => h.textContent)

describe('VistaProveedores — encabezado y resumen', () => {
  it('se titula "Proveedores" y resume activos de total', () => {
    renderVista()
    expect(screen.getByRole('heading', { level: 1, name: 'Proveedores' })).toBeInTheDocument()
    expect(screen.getByText('3 activos de 5 proveedores')).toBeInTheDocument()
  })

  it('las tres tarjetas de resumen cuentan total, activos e inactivos', () => {
    renderVista()
    expect(screen.getByText('Total proveedores').previousElementSibling).toHaveTextContent('5')
    expect(screen.getByText('Activos').previousElementSibling).toHaveTextContent('3')
    expect(screen.getByText('Inactivos').previousElementSibling).toHaveTextContent('2')
  })
})

describe('VistaProveedores — lista', () => {
  it('con 5 proveedores dibuja 5 tarjetas, en el orden recibido', () => {
    renderVista()
    expect(nombresDeTarjetas()).toEqual([
      'Distribuidora Norte', 'Lacteos del Sur', 'Mayorista Centro', 'Envases Oeste', 'Bebidas Este',
    ])
  })

  it('cada tarjeta dice cuantas compras tiene y cuanto sumaron', () => {
    renderVista()
    expect(screen.getByText('2 compras')).toBeInTheDocument()
    expect(screen.getByText(monto(1500))).toBeInTheDocument()
    expect(screen.getByText('1 compras')).toBeInTheDocument()
    expect(screen.getByText(monto(250))).toBeInTheDocument()
    // Los otros tres no compraron nada.
    expect(screen.getAllByText('0 compras')).toHaveLength(3)
    // La fecha de la ultima compra solo aparece donde hubo compras.
    expect(screen.getAllByText(/^Ultima:/)).toHaveLength(2)
  })

  it('un proveedor inactivo lleva la marca "Inactivo" y se ofrece "Activar"', () => {
    renderVista()
    expect(screen.getAllByText('Inactivo')).toHaveLength(2)
    expect(screen.getAllByRole('button', { name: 'Activar' })).toHaveLength(2)
    expect(screen.getAllByRole('button', { name: 'Desactivar' })).toHaveLength(3)
  })

  it('el admin tiene Editar y Eliminar por tarjeta y las llama con el proveedor', async () => {
    const props = renderVista()
    expect(screen.getAllByRole('button', { name: 'Editar' })).toHaveLength(5)
    expect(screen.getAllByRole('button', { name: 'Eliminar' })).toHaveLength(5)
    await userEvent.setup().click(screen.getAllByRole('button', { name: 'Editar' })[2])
    expect(props.onEditarProveedor).toHaveBeenCalledWith(PROVEEDORES[2])
    await userEvent.setup().click(screen.getAllByRole('button', { name: 'Eliminar' })[1])
    expect(props.onEliminarProveedor).toHaveBeenCalledWith('2')
    await userEvent.setup().click(screen.getAllByRole('button', { name: 'Desactivar' })[0])
    expect(props.onToggleActivo).toHaveBeenCalledWith(PROVEEDORES[0])
  })

  it('sin ser admin no hay acciones ni "Nuevo Proveedor"', () => {
    renderVista({ isAdmin: false })
    expect(nombresDeTarjetas()).toHaveLength(5)
    expect(screen.queryByRole('button', { name: /Nuevo Proveedor/ })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Editar' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Eliminar' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Desactivar' })).not.toBeInTheDocument()
  })

  it('"Nuevo Proveedor" llama a onNuevoProveedor', async () => {
    const props = renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: /Nuevo Proveedor/ }))
    expect(props.onNuevoProveedor).toHaveBeenCalledTimes(1)
  })
})

describe('VistaProveedores — filtros', () => {
  it('el buscador filtra por nombre, por CUIT y por contacto', async () => {
    renderVista()
    const buscador = screen.getByRole('textbox')
    const user = userEvent.setup()

    await user.type(buscador, 'norte')
    expect(nombresDeTarjetas()).toEqual(['Distribuidora Norte'])

    await user.clear(buscador)
    await user.type(buscador, '30-70000003')
    expect(nombresDeTarjetas()).toEqual(['Mayorista Centro'])

    await user.clear(buscador)
    await user.type(buscador, 'contacto lacteos')
    expect(nombresDeTarjetas()).toEqual(['Lacteos del Sur'])
  })

  it('una busqueda sin resultados dice "No se encontraron proveedores"', async () => {
    renderVista()
    await userEvent.setup().type(screen.getByRole('textbox'), 'zzz')
    expect(screen.getByText('No se encontraron proveedores')).toBeInTheDocument()
    expect(screen.queryAllByRole('heading', { level: 3 })).toHaveLength(0)
    // Con un filtro puesto no se ofrece cargar "el primero".
    expect(screen.queryByRole('button', { name: 'Agregar primer proveedor' })).not.toBeInTheDocument()
  })

  it('las tarjetas de resumen filtran: Activos, Inactivos y Total', async () => {
    renderVista()
    const user = userEvent.setup()

    await user.click(screen.getByText('Inactivos'))
    expect(nombresDeTarjetas()).toEqual(['Envases Oeste', 'Bebidas Este'])

    await user.click(screen.getByText('Activos'))
    expect(nombresDeTarjetas()).toEqual(['Distribuidora Norte', 'Lacteos del Sur', 'Mayorista Centro'])

    await user.click(screen.getByText('Total proveedores'))
    expect(nombresDeTarjetas()).toHaveLength(5)
  })

  it('el buscador y el estado se combinan', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(screen.getByText('Inactivos'))
    await user.type(screen.getByRole('textbox'), 'bebidas')
    expect(nombresDeTarjetas()).toEqual(['Bebidas Este'])
    // "Norte" existe, pero es un proveedor activo: con "Inactivos" no aparece.
    await user.clear(screen.getByRole('textbox'))
    await user.type(screen.getByRole('textbox'), 'norte')
    expect(screen.getByText('No se encontraron proveedores')).toBeInTheDocument()
  })
})

describe('VistaProveedores — lista vacia y carga', () => {
  it('sin proveedores dice "No hay proveedores registrados" y el admin puede cargar el primero', async () => {
    const props = renderVista({ proveedores: [] })
    expect(screen.getByText('No hay proveedores registrados')).toBeInTheDocument()
    expect(screen.queryAllByRole('heading', { level: 3 })).toHaveLength(0)
    await userEvent.setup().click(screen.getByRole('button', { name: 'Agregar primer proveedor' }))
    expect(props.onNuevoProveedor).toHaveBeenCalledTimes(1)
  })

  it('sin proveedores y sin ser admin no se ofrece cargar el primero', () => {
    renderVista({ proveedores: [], isAdmin: false })
    expect(screen.getByText('No hay proveedores registrados')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Agregar primer proveedor' })).not.toBeInTheDocument()
  })

  it('cargando avisa "Cargando..." y no dibuja ni las tarjetas ni el vacio', () => {
    renderVista({ loading: true })
    expect(screen.getByRole('status')).toHaveTextContent('Cargando...')
    expect(screen.queryAllByRole('heading', { level: 3 })).toHaveLength(0)
    expect(screen.queryByText('No hay proveedores registrados')).not.toBeInTheDocument()
  })

  it('no hay control de paginacion con una lista chica', () => {
    renderVista()
    expect(screen.getAllByRole('heading', { level: 3 })).toHaveLength(5)
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Página anterior' })).not.toBeInTheDocument()
  })
})
