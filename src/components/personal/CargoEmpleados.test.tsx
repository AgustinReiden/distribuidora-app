/**
 * CargoEmpleados (gastos 7): la sección «A cargo de empleados» de la baja de stock y de la
 * resolución de una salvedad. El monto por defecto es el costo repartido en partes iguales
 * mientras nadie toque un monto; el aviso de «más que el costo» no bloquea.
 */
import { useState } from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { EmpleadoParaElegir, LineaCargo } from '../../types/personal'

const empleados = vi.hoisted(() => ({ data: [] as EmpleadoParaElegir[] }))
vi.mock('../../hooks/queries/usePersonalQuery', () => ({
  useEmpleadosParaElegirQuery: () => ({ data: empleados.data }),
}))

import CargoEmpleados from './CargoEmpleados'

const emp = (o: Partial<EmpleadoParaElegir> & Pick<EmpleadoParaElegir, 'id' | 'nombre'>): EmpleadoParaElegir => ({
  usuario_id: null,
  vehiculo_id: null,
  activo: true,
  ...o,
})

const EMPLEADOS = [
  emp({ id: 1, nombre: 'Ana Gómez' }),
  emp({ id: 2, nombre: 'Beto Ríos' }),
  emp({ id: 3, nombre: 'Carla Paz' }),
  emp({ id: 4, nombre: 'Diego Baja', activo: false }),
  emp({ id: 5, nombre: 'Yo Mismo', usuario_id: 'u-admin' }),
]

function Host({ costo, usuarioId = null, alCambiar }: {
  costo: number | null
  usuarioId?: string | null
  alCambiar?: (v: LineaCargo[]) => void
}) {
  const [lineas, setLineas] = useState<LineaCargo[]>([])
  return (
    <CargoEmpleados
      costo={costo}
      usuarioId={usuarioId}
      value={lineas}
      onChange={v => { setLineas(v); alCambiar?.(v) }}
    />
  )
}

const montos = () => screen.queryAllByLabelText(/^monto a cargo/i).map(i => (i as HTMLInputElement).value)
const selects = () => screen.queryAllByLabelText(/^empleado \d/i) as HTMLSelectElement[]
const opciones = (s: HTMLSelectElement) => within(s).getAllByRole('option').map(o => o.textContent)
const sumar = (user: ReturnType<typeof userEvent.setup>) =>
  user.click(screen.getByRole('button', { name: /\+ empleado/i }))

describe('CargoEmpleados', () => {
  it('arranca sin líneas y con el botón para sumar un empleado', () => {
    empleados.data = EMPLEADOS
    render(<Host costo={1000} />)

    expect(screen.getByText('A cargo de empleados')).toBeInTheDocument()
    expect(selects()).toHaveLength(0)
    expect(screen.getByRole('button', { name: /\+ empleado/i })).toBeEnabled()
  })

  it('«+ Empleado» agrega una línea con todo el costo', async () => {
    empleados.data = EMPLEADOS
    const user = userEvent.setup()
    render(<Host costo={1000} />)

    await sumar(user)

    expect(selects()).toHaveLength(1)
    expect(montos()).toEqual(['1.000'])
  })

  it('reparte el costo en partes iguales entre todas las líneas, el resto a la primera', async () => {
    empleados.data = EMPLEADOS
    const user = userEvent.setup()
    render(<Host costo={1000} />)

    await sumar(user)
    await sumar(user)
    await sumar(user)

    expect(montos()).toEqual(['333,34', '333,33', '333,33'])
  })

  it('al quitar una línea vuelve a repartir mientras nadie tocó un monto', async () => {
    empleados.data = EMPLEADOS
    const user = userEvent.setup()
    render(<Host costo={1000} />)
    await sumar(user)
    await sumar(user)
    expect(montos()).toEqual(['500', '500'])

    await user.click(screen.getByRole('button', { name: /quitar empleado 2/i }))

    expect(montos()).toEqual(['1.000'])
  })

  it('con un monto tocado a mano ya no reparte', async () => {
    empleados.data = EMPLEADOS
    const user = userEvent.setup()
    render(<Host costo={1000} />)
    await sumar(user)

    const campo = screen.getByLabelText(/^monto a cargo/i)
    await user.clear(campo)
    await user.type(campo, '400')
    await sumar(user)

    expect(montos()).toEqual(['400', ''])
  })

  it('si el costo cambia y nadie tocó nada, los montos lo siguen', async () => {
    empleados.data = EMPLEADOS
    const user = userEvent.setup()
    const { rerender } = render(<Host costo={1000} />)
    await sumar(user)
    expect(montos()).toEqual(['1.000'])

    // El Host conserva su estado: sólo cambia el costo.
    rerender(<Host costo={600} />)

    expect(await screen.findByDisplayValue('600')).toBeInTheDocument()
  })

  it.each([[null], [0]])('con costo %s el monto queda vacío', async costo => {
    empleados.data = EMPLEADOS
    const user = userEvent.setup()
    render(<Host costo={costo} />)

    await sumar(user)
    await sumar(user)

    expect(montos()).toEqual(['', ''])
  })

  it('ofrece sólo activos, sin el propio usuario y sin los ya elegidos en otra línea', async () => {
    empleados.data = EMPLEADOS
    const user = userEvent.setup()
    render(<Host costo={900} usuarioId="u-admin" />)
    await sumar(user)
    await sumar(user)

    expect(opciones(selects()[0])).toEqual(['Elegí un empleado', 'Ana Gómez', 'Beto Ríos', 'Carla Paz'])

    await user.selectOptions(selects()[0], 'Ana Gómez')

    expect(opciones(selects()[0])).toEqual(['Elegí un empleado', 'Ana Gómez', 'Beto Ríos', 'Carla Paz'])
    expect(opciones(selects()[1])).toEqual(['Elegí un empleado', 'Beto Ríos', 'Carla Paz'])
  })

  it('no deja sumar más líneas que empleados para elegir', async () => {
    empleados.data = [emp({ id: 1, nombre: 'Ana Gómez' })]
    const user = userEvent.setup()
    render(<Host costo={100} />)

    await sumar(user)

    expect(screen.getByRole('button', { name: /\+ empleado/i })).toBeDisabled()
  })

  it('avisa si la suma pasa el costo, sin bloquear', async () => {
    empleados.data = EMPLEADOS
    const user = userEvent.setup()
    const alCambiar = vi.fn()
    render(<Host costo={1000} alCambiar={alCambiar} />)
    await sumar(user)
    expect(screen.queryByText(/cargás más que el costo/i)).toBeNull()

    const campo = screen.getByLabelText(/^monto a cargo/i)
    await user.clear(campo)
    await user.type(campo, '1500')

    const aviso = screen.getByText(/cargás más que el costo de la mercadería/i)
    expect(aviso).toHaveTextContent('$')
    expect(aviso).toHaveTextContent('1.000')
    expect(screen.getByRole('button', { name: /\+ empleado/i })).toBeEnabled()
    expect(alCambiar).toHaveBeenLastCalledWith([{ empleado_id: null, monto: '1.500' }])
  })

  it('sin costo conocido no avisa nada por pasarse', async () => {
    empleados.data = EMPLEADOS
    const user = userEvent.setup()
    render(<Host costo={null} />)
    await sumar(user)

    await user.type(screen.getByLabelText(/^monto a cargo/i), '99999')

    expect(screen.queryByText(/cargás más que el costo/i)).toBeNull()
  })
})
