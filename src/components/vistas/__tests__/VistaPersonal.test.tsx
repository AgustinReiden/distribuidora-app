/**
 * VistaPersonal (entrega 3 de gastos): las tarjetas del personal de la sucursal,
 * con el mismo molde que las de Clientes. La vista sólo muestra y avisa: quién
 * puede qué lo decide el server.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaPersonal, { type VistaPersonalProps } from '../VistaPersonal'
import { formatPrecio } from '../../../utils/formatters'
import type { Empleado } from '../../../types/personal'

const SUCURSALES = [{ id: 1, nombre: 'Tucumán' }, { id: 2, nombre: 'Taco Pozo' }]

const empleado = (e: Partial<Empleado> & Pick<Empleado, 'id' | 'nombre'>): Empleado => ({
  puesto: 'otro', sucursal_id: 1, de_las_dos: false, cuil: null, fecha_ingreso: null, telefono: null,
  activo: true, fecha_baja: null, usuario: null, cliente: null, vehiculo: null, arreglo: null,
  arranque: null, saldo: 0, es_propio: false, ...e,
})

const LUIS = empleado({
  id: 1, nombre: 'Luis Prios', puesto: 'preventista',
  usuario: { id: 'u-1', nombre: 'prios' },
  cliente: { id: 10, nombre_fantasia: 'Kiosco Luis', activo: true },
  arreglo: { id: 1, vigente_desde: '2026-01-05', vigente_hasta: null, sueldo: 150000, frecuencia: 'semanal', comisiona: true },
  arranque: '2026-01-05', saldo: -5000,
})
const PABLO = empleado({ id: 2, nombre: 'Pablo Ríos', puesto: 'transportista', vehiculo: { id: 7, patente: 'AC456EF', descripcion: 'Partner' } })
const ANA = empleado({ id: 3, nombre: 'Ana Gómez', puesto: 'administracion', de_las_dos: true })
const PROPIO = empleado({ id: 4, nombre: 'Yo Mismo', puesto: 'administracion', es_propio: true })
const SE_FUE = empleado({ id: 5, nombre: 'Rosa Vieja', puesto: 'ayudante', activo: false, fecha_baja: '2026-09-30', saldo: 12000 })

function renderVista(props: Partial<VistaPersonalProps> = {}) {
  const handlers = {
    onRetry: vi.fn(), onNuevo: vi.fn(), onEditar: vi.fn(), onDarDeBaja: vi.fn(), onReactivar: vi.fn(), onVerFicha: vi.fn(),
  }
  render(
    <VistaPersonal
      empleados={[LUIS, PABLO, ANA, PROPIO, SE_FUE]}
      loading={false}
      sucursalActual={{ id: 1, nombre: 'Tucumán' }}
      sucursales={SUCURSALES}
      {...handlers}
      {...props}
    />,
  )
  return { ...handlers, user: userEvent.setup() }
}

const tarjeta = (nombre: string) => screen.getByRole('heading', { level: 3, name: nombre }).closest('li') as HTMLElement

describe('VistaPersonal', () => {
  it('encabezado: título, crumbs, buscador, pastillas y alta', () => {
    renderVista()
    expect(screen.getByRole('heading', { level: 1 })).toHaveTextContent('Personal')
    expect(screen.getByText('ADMINISTRACIÓN')).toBeInTheDocument()
    expect(screen.getByText('TUCUMÁN')).toBeInTheDocument()
    // Cuenta los activos, igual que la pastilla "Todos" (Rosa Vieja está inactiva).
    expect(screen.getByText('4 EMPLEADOS')).toBeInTheDocument()
    expect(screen.getByPlaceholderText('Buscar empleado')).toBeInTheDocument()
    const grupo = screen.getByRole('group', { name: 'Filtrar personal' })
    expect(within(grupo).getByRole('button', { name: 'Todos · 4' })).toBeInTheDocument()
    expect(within(grupo).getByRole('button', { name: 'Con saldo · 2' })).toBeInTheDocument()
    expect(within(grupo).getByRole('button', { name: 'Inactivos' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Nuevo empleado/ })).toBeInTheDocument()
  })

  it('la tarjeta muestra puesto, sucursal, arreglo, vínculos y saldo', () => {
    renderVista()
    const t = within(tarjeta('Luis Prios'))
    expect(t.getByText('Preventista · Tucumán')).toBeInTheDocument()
    expect(t.getByText(/Semanal · .*150\.000.* \+ comisión/)).toBeInTheDocument()
    expect(t.getByText('Usuario prios')).toBeInTheDocument()
    expect(t.getByText('Cliente “Kiosco Luis”')).toBeInTheDocument()
    expect(t.getByText('Saldo · debe')).toBeInTheDocument()
    expect(t.getByText(formatPrecio(5000).replace(/\s/g, ' '))).toBeInTheDocument()
    expect(t.getByRole('button', { name: 'Ver ficha' })).toBeInTheDocument()
  })

  it('muestra el vehículo, "Sin usuario en la app" y "Sin arreglo"', () => {
    renderVista()
    const t = within(tarjeta('Pablo Ríos'))
    expect(t.getByText('Partner AC456EF')).toBeInTheDocument()
    expect(t.getByText('Sin usuario en la app')).toBeInTheDocument()
    expect(t.getByText('Sin arreglo')).toBeInTheDocument()
    expect(t.getByText('Saldo')).toBeInTheDocument()
  })

  it('el saldo a favor dice "a su favor"', () => {
    renderVista({ empleados: [empleado({ id: 9, nombre: 'Con Favor', saldo: 3000 })] })
    expect(screen.getByText('Saldo · a su favor')).toBeInTheDocument()
  })

  it('un arreglo que empieza en el futuro lo dice', () => {
    renderVista({
      empleados: [empleado({
        id: 9, nombre: 'Recién Llegado',
        arreglo: { id: 1, vigente_desde: '2099-03-02', vigente_hasta: null, sueldo: 100000, frecuencia: 'mensual', comisiona: false },
        arranque: '2099-03-02',
      })],
    })
    expect(screen.getByText(/empieza el 02\/03/)).toBeInTheDocument()
  })

  it('un empleado de las dos dice "Las dos"', () => {
    renderVista()
    expect(within(tarjeta('Ana Gómez')).getByText('Administración · Las dos')).toBeInTheDocument()
  })

  it('el filtro Con saldo trae también a un inactivo con saldo', async () => {
    const { user } = renderVista()
    expect(screen.queryByRole('heading', { level: 3, name: 'Rosa Vieja' })).toBeNull()
    await user.click(screen.getByRole('button', { name: 'Con saldo · 2' }))
    expect(screen.getByRole('heading', { level: 3, name: 'Luis Prios' })).toBeInTheDocument()
    const t = within(tarjeta('Rosa Vieja'))
    expect(t.getByText('Inactivo')).toBeInTheDocument()
    expect(screen.queryByRole('heading', { level: 3, name: 'Pablo Ríos' })).toBeNull()
  })

  it('la cuenta propia no tiene desactivar y dice "Tu cuenta"', () => {
    renderVista()
    const t = within(tarjeta('Yo Mismo'))
    expect(t.getByText('Tu cuenta')).toBeInTheDocument()
    expect(t.queryByRole('button', { name: /Desactivar empleado/ })).toBeNull()
    expect(t.getByRole('button', { name: 'Editar empleado Yo Mismo' })).toBeInTheDocument()
  })

  it('un inactivo tiene reactivar y no desactivar', async () => {
    const { user, onReactivar } = renderVista()
    await user.click(screen.getByRole('button', { name: 'Inactivos' }))
    const t = within(tarjeta('Rosa Vieja'))
    expect(t.queryByRole('button', { name: /Desactivar empleado/ })).toBeNull()
    await user.click(t.getByRole('button', { name: 'Reactivar empleado Rosa Vieja' }))
    expect(onReactivar).toHaveBeenCalledWith(SE_FUE)
  })

  it('un activo tiene desactivar, con su título, y no reactivar', async () => {
    const { user, onDarDeBaja } = renderVista()
    const t = within(tarjeta('Luis Prios'))
    expect(t.queryByRole('button', { name: /Reactivar empleado/ })).toBeNull()
    const boton = t.getByRole('button', { name: 'Desactivar empleado Luis Prios' })
    expect(boton).toHaveAttribute('title', 'Desactivar. Su cuenta y su historial quedan.')
    await user.click(boton)
    expect(onDarDeBaja).toHaveBeenCalledWith(LUIS)
  })

  it('buscar "rios" deja a Pablo Ríos', async () => {
    // Sin Luis: su usuario ("prios") también contiene "rios".
    const { user } = renderVista({ empleados: [PABLO, ANA] })
    await user.type(screen.getByPlaceholderText('Buscar empleado'), 'rios')
    expect(screen.getByRole('heading', { level: 3, name: 'Pablo Ríos' })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { level: 3, name: 'Ana Gómez' })).toBeNull()
  })

  it('editar, ver ficha y nuevo avisan', async () => {
    const { user, onEditar, onVerFicha, onNuevo } = renderVista()
    const t = within(tarjeta('Luis Prios'))
    await user.click(t.getByRole('button', { name: 'Editar empleado Luis Prios' }))
    await user.click(t.getByRole('button', { name: 'Ver ficha' }))
    await user.click(screen.getByRole('button', { name: /Nuevo empleado/ }))
    expect(onEditar).toHaveBeenCalledWith(LUIS)
    expect(onVerFicha).toHaveBeenCalledWith(LUIS)
    expect(onNuevo).toHaveBeenCalled()
  })

  it('vacíos: sin empleados y sin coincidencias', async () => {
    const { user } = renderVista({ empleados: [] })
    expect(screen.getByText('Todavía no hay empleados. Cargá el primero con «Nuevo empleado».')).toBeInTheDocument()
    await user.type(screen.getByPlaceholderText('Buscar empleado'), 'zzz')
    expect(screen.getByText('Ningún empleado coincide.')).toBeInTheDocument()
  })

  it('con sólo inactivos y el filtro "Todos" dice que no hay activos, no que nada coincide', () => {
    renderVista({ empleados: [SE_FUE] })
    expect(screen.getByText('No hay empleados activos.')).toBeInTheDocument()
    expect(screen.queryByText('Ningún empleado coincide.')).not.toBeInTheDocument()
    expect(screen.getByText('0 EMPLEADOS')).toBeInTheDocument()
  })

  it('el encabezado en singular cuenta sólo a los activos', () => {
    renderVista({ empleados: [LUIS, SE_FUE] })
    expect(screen.getByText('1 EMPLEADO')).toBeInTheDocument()
  })

  it('cargando no muestra vacío', () => {
    renderVista({ empleados: [], loading: true })
    expect(screen.queryByText(/Todavía no hay empleados/)).toBeNull()
  })

  it('con error ofrece reintentar', async () => {
    const { user, onRetry } = renderVista({ empleados: [], error: new Error('x') })
    await user.click(screen.getByRole('button', { name: /reintentar/i }))
    expect(onRetry).toHaveBeenCalled()
  })
})
