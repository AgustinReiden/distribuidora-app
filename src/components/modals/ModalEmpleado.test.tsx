/**
 * ModalEmpleado (entrega 3 de gastos): alta y edición del empleado. El alta pide además el
 * primer arreglo y, si hace falta, el saldo con que arranca; la edición muestra el arreglo
 * vigente sin tocarlo.
 */
import { describe, it, expect, vi, type Mock } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalEmpleado, { modalEmpleadoSchema, type ModalEmpleadoProps } from './ModalEmpleado'
import { formatPrecio } from '../../utils/formatters'
import type { Empleado } from '../../types/personal'

const TUCUMAN = { id: 1, nombre: 'Tucumán' }
const TACO_POZO = { id: 2, nombre: 'Taco Pozo' }

const USUARIOS = [
  { id: 'u-1', nombre: 'Pablo Ríos' },
  { id: 'u-2', nombre: 'Martín Sosa' },
]
const CLIENTES = [
  { id: 10, nombre_fantasia: 'Kiosco Norte', activo: true },
  { id: 11, nombre_fantasia: 'Almacén Sur', activo: true },
  { id: 12, nombre_fantasia: 'Despensa Vieja', activo: false },
]
const VEHICULOS = [
  { id: 7, patente: 'AC456EF', descripcion: 'Partner' },
  { id: 8, patente: 'AB123CD', descripcion: 'Hilux' },
]

const EMPLEADO: Empleado = {
  id: 42, nombre: 'Martín Sosa', puesto: 'transportista', sucursal_id: 1, de_las_dos: false,
  cuil: '20301234567', fecha_ingreso: '2025-02-03', telefono: '381 555-0101', activo: true, fecha_baja: null,
  usuario: { id: 'u-2', nombre: 'Martín Sosa' }, cliente: null, vehiculo: null,
  arreglo: { id: 5, vigente_desde: '2026-10-01', vigente_hasta: null, sueldo: 280000, frecuencia: 'semanal', comisiona: false },
  arranque: '2026-10-01', saldo: 0, es_propio: false,
}

type OnSave = ModalEmpleadoProps['onSave']

function renderModal(props: Partial<ModalEmpleadoProps> = {}) {
  const onSave: Mock<OnSave> = (props.onSave as Mock<OnSave>) ?? vi.fn<OnSave>(() => Promise.resolve())
  const onClose: Mock<() => void> = vi.fn()
  render(
    <ModalEmpleado
      empleado={null}
      sucursalActual={TUCUMAN}
      sucursalesUsuario={[TUCUMAN]}
      tieneTodasLasSucursales={false}
      usuarios={USUARIOS}
      clientes={CLIENTES}
      vehiculos={VEHICULOS}
      ocupados={{ usuarios: new Set(), clientes: new Set() }}
      hoy="2026-10-29"
      onSave={onSave}
      onClose={onClose}
      {...props}
    />,
  )
  return { onSave, onClose, user: userEvent.setup() }
}

type U = ReturnType<typeof userEvent.setup>

async function cargarAlta(user: U, nombre = 'Luis Prios', puesto = 'Transportista') {
  await user.type(screen.getByLabelText(/^Nombre y apellido/), nombre)
  await user.click(screen.getByRole('button', { name: puesto }))
}

describe('ModalEmpleado', () => {
  it('el alta manda el primer arreglo', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '280000')
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))

    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0]).toMatchObject({
      nombre: 'Luis Prios',
      puesto: 'transportista',
      sucursal_id: 1,
      de_las_dos: false,
      cuil: null,
      usuario_id: null,
      cliente_id: null,
      vehiculo_id: null,
      saldo_inicial: null,
      arreglo: { vigente_desde: '2026-10-26', sueldo: 280000, frecuencia: 'semanal', comisiona: false },
    })
    expect(onSave.mock.calls[0][0].id).toBeUndefined()
  })

  it('la fecha sigue a la frecuencia hasta que se la toca a mano', async () => {
    const { user } = renderModal()
    const desde = screen.getByLabelText(/^Se liquida desde/) as HTMLInputElement
    expect(desde.value).toBe('2026-10-26')

    await user.click(screen.getByRole('button', { name: 'Mensual' }))
    expect(desde.value).toBe('2026-10-01')

    fireEvent.change(desde, { target: { value: '2026-10-15' } })
    await user.click(screen.getByRole('button', { name: 'Semanal' }))
    expect(desde.value).toBe('2026-10-15')
  })

  it('saldo al empezar Debe 5000 manda saldo_inicial: -5000', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '280000')
    await user.click(screen.getByRole('button', { name: '+ Saldo al empezar' }))
    await user.type(screen.getByLabelText('Saldo al empezar'), '5000')
    await user.click(screen.getByRole('button', { name: 'Debe' }))
    expect(screen.getByText('Lo que le debían o debía al pasar a la app. Entra como un ajuste.')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))

    expect(onSave.mock.calls[0][0].saldo_inicial).toBe(-5000)
  })

  it('saldo al empezar A su favor manda el monto positivo', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '280000')
    await user.click(screen.getByRole('button', { name: '+ Saldo al empezar' }))
    await user.type(screen.getByLabelText('Saldo al empezar'), '3000')
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))

    expect(onSave.mock.calls[0][0].saldo_inicial).toBe(3000)
  })

  it('sin sueldo y sin comisión no deja guardar, y avisa', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user)
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))

    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('Un arreglo sin sueldo fijo tiene que comisionar')).toBeInTheDocument()
  })

  it('sin sueldo pero comisionando sí deja guardar', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user, 'Ana Vendedora', 'Preventista')
    await user.click(screen.getByRole('checkbox', { name: 'Comisiona' }))
    expect(screen.getByText('El porcentaje no va acá: sale de las reglas de comisión.')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))

    expect(onSave.mock.calls[0][0].arreglo).toEqual({
      vigente_desde: '2026-10-26', sueldo: 0, frecuencia: 'semanal', comisiona: true,
    })
  })

  it('sin nombre ni puesto avisa', async () => {
    const { onSave, user } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))
    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('Falta el nombre y apellido')).toBeInTheDocument()
  })

  it('quien no tiene todas las sucursales no ve "Las dos"', () => {
    renderModal({ sucursalesUsuario: [TUCUMAN], tieneTodasLasSucursales: false })
    expect(screen.queryByRole('button', { name: 'Las dos' })).not.toBeInTheDocument()
    expect(screen.getByText('Sucursal Tucumán')).toBeInTheDocument()
  })

  it('quien tiene todas elige sucursal o "Las dos"', async () => {
    const { onSave, user } = renderModal({ sucursalesUsuario: [TUCUMAN, TACO_POZO], tieneTodasLasSucursales: true })
    await cargarAlta(user)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '100000')

    await user.click(screen.getByRole('button', { name: 'Taco Pozo' }))
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))
    expect(onSave.mock.calls[0][0]).toMatchObject({ sucursal_id: 2, de_las_dos: false })

    await user.click(screen.getByRole('button', { name: 'Las dos' }))
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))
    expect(onSave.mock.calls[1][0]).toMatchObject({ sucursal_id: 1, de_las_dos: true })
  })

  it('un cliente vinculado a otro empleado no se ofrece, y uno inactivo dice "inactivo"', async () => {
    const { user } = renderModal({ ocupados: { usuarios: new Set(['u-1']), clientes: new Set([10]) } })

    await user.click(screen.getByLabelText('Ficha de cliente'))
    expect(screen.queryByRole('option', { name: /Kiosco Norte/ })).not.toBeInTheDocument()
    expect(screen.getByRole('option', { name: /Almacén Sur/ })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Despensa Vieja · inactivo' })).toBeInTheDocument()

    await user.click(screen.getByLabelText('Usuario de la app'))
    expect(screen.queryByRole('option', { name: 'Pablo Ríos' })).not.toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Martín Sosa' })).toBeInTheDocument()
  })

  it('el vínculo se manda en el payload y se puede quitar con "Sin vínculo"', async () => {
    const { onSave, user } = renderModal({ empleado: { ...EMPLEADO, vehiculo: { id: 7, patente: 'AC456EF', descripcion: 'Partner' } } })

    await user.click(screen.getByLabelText('Ficha de cliente'))
    await user.click(screen.getByRole('option', { name: /Almacén Sur/ }))
    await user.click(screen.getByLabelText('Vehículo habitual'))
    await user.click(screen.getByRole('option', { name: 'Sin vínculo' }))
    await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ id: 42, usuario_id: 'u-2', cliente_id: 11, vehiculo_id: null })
  })

  it('el vehículo se busca por patente o por modelo', async () => {
    const { user } = renderModal()
    await user.click(screen.getByLabelText('Vehículo habitual'))
    await user.type(screen.getByLabelText('Vehículo habitual'), 'hilux')
    expect(screen.getByRole('option', { name: /AB123CD/ })).toBeInTheDocument()
    expect(screen.queryByRole('option', { name: /AC456EF/ })).not.toBeInTheDocument()
  })

  it('editar no muestra el primer arreglo y no manda arreglo', async () => {
    const { onSave, user } = renderModal({ empleado: EMPLEADO })

    expect(screen.getByRole('heading', { name: 'Editar empleado' })).toBeInTheDocument()
    expect(screen.queryByText('Primer arreglo')).not.toBeInTheDocument()
    expect(screen.queryByLabelText(/^Sueldo fijo/)).not.toBeInTheDocument()
    expect(screen.getByText('Arreglo vigente')).toBeInTheDocument()
    // El DOM normaliza el espacio duro que Intl pone tras el "$"; el texto esperado, no.
    const esperado = `${formatPrecio(280000)} por semana · no comisiona · desde el 01/10/2026`.replace(/\s/g, ' ')
    expect(screen.getByText(esperado)).toBeInTheDocument()
    expect(screen.getByText('Se cambia desde la ficha, para que conserve desde cuándo vale.')).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))
    const payload = onSave.mock.calls[0][0]
    expect(payload).toMatchObject({ id: 42, nombre: 'Martín Sosa', puesto: 'transportista', cuil: '20301234567' })
    expect(payload.arreglo).toBeUndefined()
    expect(payload.saldo_inicial).toBeUndefined()
  })

  it('al editar, una sucursal que no se toca se conserva', async () => {
    const { onSave, user } = renderModal({
      empleado: { ...EMPLEADO, sucursal_id: 2 },
      sucursalesUsuario: [TUCUMAN, TACO_POZO],
    })
    expect(screen.getByText('Sucursal Taco Pozo')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))
    expect(onSave.mock.calls[0][0]).toMatchObject({ sucursal_id: 2, de_las_dos: false })
  })

  it('la cuenta propia no deja cambiar el usuario', () => {
    renderModal({ empleado: { ...EMPLEADO, es_propio: true } })
    expect(screen.getByLabelText('Usuario de la app')).toBeDisabled()
    expect(screen.getByText('Tu vínculo de usuario lo cambia otro admin.')).toBeInTheDocument()
  })

  it('una cuenta ajena deja cambiar el usuario', () => {
    renderModal({ empleado: EMPLEADO })
    expect(screen.getByLabelText('Usuario de la app')).toBeEnabled()
    expect(screen.queryByText('Tu vínculo de usuario lo cambia otro admin.')).not.toBeInTheDocument()
  })

  it("el CUIL '20-30123456-7' va como '20301234567'", async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user)
    await user.type(screen.getByLabelText('CUIL'), '20-30123456-7')
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '1000')
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))

    expect(onSave.mock.calls[0][0].cuil).toBe('20301234567')
  })

  it('un CUIL de 10 números avisa y no guarda', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user)
    await user.type(screen.getByLabelText('CUIL'), '2030123456')
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '1000')
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))

    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('El CUIL tiene que tener 11 números')).toBeInTheDocument()
  })

  it('si el guardado falla, muestra el mensaje y no cierra', async () => {
    const onSave = vi.fn<OnSave>(() => Promise.reject(new Error('Ese usuario ya está vinculado a otro empleado')))
    const { onClose, user } = renderModal({ onSave })
    await cargarAlta(user)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '1000')
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))

    expect(await screen.findByText('Ese usuario ya está vinculado a otro empleado')).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
  })

  it('al guardar bien, cierra', async () => {
    const { onClose, user } = renderModal()
    await cargarAlta(user)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '1000')
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))
    await vi.waitFor(() => expect(onClose).toHaveBeenCalled())
  })
})

describe('modalEmpleadoSchema', () => {
  const base = {
    nombre: 'Luis', puesto: 'otro', sucursal_id: 1, de_las_dos: false, cuil: null, fecha_ingreso: null,
    telefono: null, usuario_id: null, cliente_id: null, vehiculo_id: null,
  }

  it('el arreglo es obligatorio sólo en el alta', () => {
    expect(modalEmpleadoSchema.safeParse(base).success).toBe(false)
    expect(modalEmpleadoSchema.safeParse({ ...base, id: 3 }).success).toBe(true)
  })

  it('coacciona los ids que llegan como string', () => {
    const r = modalEmpleadoSchema.safeParse({ ...base, id: 3, cliente_id: '11', vehiculo_id: '7' })
    expect(r.success && r.data.cliente_id).toBe(11)
    expect(r.success && r.data.vehiculo_id).toBe(7)
  })
})
