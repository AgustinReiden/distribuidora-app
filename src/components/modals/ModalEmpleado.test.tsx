/**
 * ModalEmpleado (entrega 3 de gastos): alta y edición del empleado. El alta pide además el
 * primer arreglo y, si hace falta, el saldo con que arranca; la edición muestra el arreglo
 * vigente sin tocarlo.
 */
import { describe, it, expect, vi, beforeEach, type Mock } from 'vitest'
import { asentar, atras } from '../../test/atrasHelpers'
import { fireEvent, render, screen } from '@testing-library/react'
import { reiniciarAtrasModales } from '../../utils/atrasModales'
import userEvent from '@testing-library/user-event'

// m4 (#1392): la comisión sin liquidar de la ficha, que el modal pide sólo si se la cambia de sucursal.
// El motivo lo redacta el server (comision_sin_liquidar_empleado): el modal lo muestra tal cual.
const comision = vi.hoisted(() => ({
  respuesta: { monto: 0, aviso: null, avisoUsuario: null } as
    { monto: number; aviso: string | null; avisoUsuario?: string | null } | undefined,
  pedida: [] as Array<{ empleadoId: number | null; enabled: boolean }>,
}))
vi.mock('../../hooks/queries/usePersonalQuery', () => ({
  useComisionSinLiquidarQuery: (empleadoId: number | null, enabled = true) => {
    comision.pedida.push({ empleadoId, enabled })
    return { data: enabled ? comision.respuesta : undefined }
  },
}))
const AVISO_2000 = 'Tiene $ 2.000,00 de comisión sin liquidar en Tucuman: liquidalo antes de pasarlo de sucursal'
const AVISO_LUNES = 'Tiene $ 2.000,00 de comisión sin liquidar en Tucuman, de esta semana: se puede liquidar desde el lunes 1/12; pasalo de sucursal después'
const AVISO_USUARIO = 'Tiene $ 2.000,00 de comisión sin liquidar en Tucuman: liquidalo antes de cambiarle o sacarle el usuario'

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
  arranque: '2026-10-01', saldo: 0, es_propio: false, periodo: null,
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

  it('«Se liquida desde» lleva el tope de 60 días y lo explica', () => {
    renderModal()
    const desde = screen.getByLabelText(/^Se liquida desde/) as HTMLInputElement
    expect(desde.min).toBe('2026-08-30')
    expect(desde.max).toBe('2026-12-28')
    expect(screen.getByText(/Va hasta 60 días antes o después de hoy\./)).toBeInTheDocument()
  })

  it('un alta con «Se liquida desde» fuera del tope no guarda', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '280000')
    fireEvent.change(screen.getByLabelText(/^Se liquida desde/), { target: { value: '2026-08-29' } })
    // Se envía el formulario sin la validación nativa de `min`/`max`: lo que se prueba es la regla del modal.
    fireEvent.submit(screen.getByRole('button', { name: 'Dar de alta' }).closest('form') as HTMLFormElement)

    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'El arreglo vale desde una fecha entre el 30/08/2026 y el 28/12/2026 (hasta 60 días antes o después de hoy)',
    )
  })

  it('el borde del tope (60 días antes) sí guarda', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '280000')
    fireEvent.change(screen.getByLabelText(/^Se liquida desde/), { target: { value: '2026-08-30' } })
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))
    expect(onSave).toHaveBeenCalledTimes(1)
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

  it('un sueldo en blanco no se guarda como 0: avisa que falta', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user)
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))

    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('Falta el sueldo: poné 0 si es sólo comisión')).toBeInTheDocument()
  })

  it('un sueldo en blanco no se guarda como 0 ni aunque comisione', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user, 'Ana Vendedora', 'Preventista')
    await user.click(screen.getByRole('checkbox', { name: 'Comisiona' }))
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))

    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('Falta el sueldo: poné 0 si es sólo comisión')).toBeInTheDocument()
  })

  it('un sueldo que no se entiende no se guarda y dice cómo escribirlo', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '280,000,5') // B20: tres decimales ya no es ilegible (se guarda con aviso); dos comas, sí
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))

    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('Escribí el monto con números, por ejemplo 280000 (se ve 280.000) o 280000,50')).toBeInTheDocument()
  })

  // B20 (D17, cambió de regla): los miles los pone el campo; «280.000» tipeado sería 280,000.
  it('el sueldo se tipea sin puntos y el campo pone los miles', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '280000')
    expect(screen.getByLabelText(/^Sueldo fijo/)).toHaveValue('280.000')
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))

    expect(onSave.mock.calls[0][0].arreglo).toMatchObject({ sueldo: 280000 })
  })

  it('un saldo al empezar que no se entiende no se guarda y dice cómo escribirlo', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '280000')
    await user.click(screen.getByRole('button', { name: '+ Saldo al empezar' }))
    await user.type(screen.getByLabelText('Saldo al empezar'), '1,234.56')
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))

    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('Escribí el monto con números, por ejemplo 280000 (se ve 280.000) o 280000,50')).toBeInTheDocument()
  })

  it('sueldo 0 y sin comisión no deja guardar, y avisa', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '0')
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))

    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText('Un arreglo sin sueldo fijo tiene que comisionar')).toBeInTheDocument()
  })

  it('sueldo 0 comisionando sí deja guardar', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user, 'Ana Vendedora', 'Preventista')
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '0')
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

  // 1597-b6 (#1597): la fecha de ingreso no puede ser futura, como en guardar_empleado.
  it('una fecha de ingreso futura queda en rojo junto al campo y no guarda', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '280000')
    const ingreso = screen.getByLabelText('Ingresó el') as HTMLInputElement
    // Sin `max` nativo: frenaría también la ficha que ya tenía una fecha futura y no se toca.
    expect(ingreso.max).toBe('')
    fireEvent.change(ingreso, { target: { value: '2026-10-30' } })

    expect(ingreso).toHaveAttribute('aria-invalid', 'true')
    expect(ingreso).toHaveAccessibleDescription('La fecha de ingreso no puede ser futura')
    fireEvent.submit(screen.getByRole('button', { name: 'Dar de alta' }).closest('form') as HTMLFormElement)
    expect(onSave).not.toHaveBeenCalled()
  })

  it('hoy como fecha de ingreso sí guarda', async () => {
    const { onSave, user } = renderModal()
    await cargarAlta(user)
    await user.type(screen.getByLabelText(/^Sueldo fijo/), '280000')
    fireEvent.change(screen.getByLabelText('Ingresó el'), { target: { value: '2026-10-29' } })
    expect(screen.getByLabelText('Ingresó el')).not.toHaveAttribute('aria-invalid')
    await user.click(screen.getByRole('button', { name: 'Dar de alta' }))
    expect(onSave.mock.calls[0][0]).toMatchObject({ fecha_ingreso: '2026-10-29' })
  })

  it('una ficha que ya tenía una fecha de ingreso futura se edita sin tocarla', async () => {
    const { onSave, user } = renderModal({ empleado: { ...EMPLEADO, fecha_ingreso: '2026-11-15' } })
    expect(screen.getByLabelText('Ingresó el')).not.toHaveAttribute('aria-invalid')
    await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))
    expect(onSave.mock.calls[0][0]).toMatchObject({ fecha_ingreso: '2026-11-15' })
  })

  it('el motivo del server sobre la fecha de ingreso se muestra junto al campo', async () => {
    const onSave = vi.fn<OnSave>(() => Promise.reject(new Error('La fecha de ingreso no puede ser futura')))
    const { user } = renderModal({ empleado: EMPLEADO, onSave })
    await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))

    const ingreso = screen.getByLabelText('Ingresó el')
    expect(await screen.findByRole('alert')).toHaveTextContent('La fecha de ingreso no puede ser futura')
    expect(ingreso).toHaveAttribute('aria-invalid', 'true')
    expect(ingreso).toHaveAccessibleDescription('La fecha de ingreso no puede ser futura')
    // Al tocar la fecha, el rojo del server se va.
    fireEvent.change(ingreso, { target: { value: '2025-02-04' } })
    expect(ingreso).not.toHaveAttribute('aria-invalid')
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

  // Com-B5 (decisión del dueño del 25/11): tampoco la ficha de cliente de la cuenta propia.
  it('la cuenta propia no deja cambiar la ficha de cliente, y la conserva al guardar', async () => {
    const { onSave, user } = renderModal({
      empleado: { ...EMPLEADO, es_propio: true, cliente: { id: 10, nombre_fantasia: 'Kiosco Norte', activo: true } },
    })
    expect(screen.getByLabelText('Ficha de cliente')).toBeDisabled()
    expect(screen.getByText('Tu ficha de cliente la cambia otro admin.')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))
    expect(onSave.mock.calls[0][0]).toMatchObject({ cliente_id: 10 })
  })

  it('una cuenta ajena deja cambiar la ficha de cliente', () => {
    renderModal({ empleado: EMPLEADO })
    expect(screen.getByLabelText('Ficha de cliente')).toBeEnabled()
    expect(screen.queryByText('Tu ficha de cliente la cambia otro admin.')).not.toBeInTheDocument()
  })

  // m4 (#1392, decisión del dueño del 25/11): con comisión sin liquidar no se lo cambia de sucursal.
  describe('cambiar de sucursal con comisión sin liquidar', () => {
    beforeEach(() => {
      comision.pedida.length = 0
    })

    it('avisa con el motivo del server, y no guarda', async () => {
      comision.respuesta = { monto: 2000, aviso: AVISO_2000 }
      const { onSave, user } = renderModal({
        empleado: EMPLEADO, sucursalesUsuario: [TUCUMAN, TACO_POZO], tieneTodasLasSucursales: true,
      })
      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
      await user.click(screen.getByRole('button', { name: 'Taco Pozo' }))
      expect(screen.getByRole('alert')).toHaveTextContent(AVISO_2000)
      expect(comision.pedida).toContainEqual({ empleadoId: 42, enabled: true })
      await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))
      expect(onSave).not.toHaveBeenCalled()

      // Volver a la suya saca el aviso y guarda.
      await user.click(screen.getByRole('button', { name: 'Tucumán' }))
      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
      await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))
      expect(onSave).toHaveBeenCalledTimes(1)
    })

    it('a «Las dos» también', async () => {
      comision.respuesta = { monto: 2000, aviso: AVISO_2000 }
      const { onSave, user } = renderModal({
        empleado: EMPLEADO, sucursalesUsuario: [TUCUMAN, TACO_POZO], tieneTodasLasSucursales: true,
      })
      await user.click(screen.getByRole('button', { name: 'Las dos' }))
      expect(screen.getByRole('alert')).toHaveTextContent(AVISO_2000)
      await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))
      expect(onSave).not.toHaveBeenCalled()
    })

    // El período en curso ya se liquidó: el motivo dice desde cuándo se puede liquidar.
    it('con lo pendiente en un período que todavía no empezó, dice desde cuándo', async () => {
      comision.respuesta = { monto: 2000, aviso: AVISO_LUNES }
      const { onSave, user } = renderModal({
        empleado: EMPLEADO, sucursalesUsuario: [TUCUMAN, TACO_POZO], tieneTodasLasSucursales: true,
      })
      await user.click(screen.getByRole('button', { name: 'Taco Pozo' }))
      expect(screen.getByRole('alert')).toHaveTextContent('se puede liquidar desde el lunes 1/12; pasalo de sucursal después')
      await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))
      expect(onSave).not.toHaveBeenCalled()
    })

    it('sin comisión pendiente se pasa', async () => {
      comision.respuesta = { monto: 0, aviso: null }
      const { onSave, user } = renderModal({
        empleado: EMPLEADO, sucursalesUsuario: [TUCUMAN, TACO_POZO], tieneTodasLasSucursales: true,
      })
      await user.click(screen.getByRole('button', { name: 'Taco Pozo' }))
      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
      await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))
      expect(onSave.mock.calls[0][0]).toMatchObject({ sucursal_id: 2, de_las_dos: false })
    })

    it('sin moverlo no pregunta la comisión', () => {
      comision.respuesta = { monto: 2000, aviso: AVISO_2000 }
      renderModal({ empleado: EMPLEADO, sucursalesUsuario: [TUCUMAN, TACO_POZO], tieneTodasLasSucursales: true })
      expect(comision.pedida.every(p => !p.enabled)).toBe(true)
      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    })
  })

  // Decisión del dueño del 26/11: con comisión sin liquidar tampoco se le saca el usuario ni se le pasa otro.
  describe('cambiar o sacar el usuario con comisión sin liquidar', () => {
    beforeEach(() => {
      comision.pedida.length = 0
      comision.respuesta = { monto: 2000, aviso: AVISO_2000, avisoUsuario: AVISO_USUARIO }
    })

    it('sacarle el usuario avisa con el motivo del server, y no guarda', async () => {
      const { onSave, user } = renderModal({ empleado: EMPLEADO })
      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
      await user.click(screen.getByLabelText('Usuario de la app'))
      await user.click(screen.getByRole('option', { name: 'Sin vínculo' }))
      expect(screen.getByRole('alert')).toHaveTextContent(AVISO_USUARIO)
      expect(comision.pedida).toContainEqual({ empleadoId: 42, enabled: true })
      await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))
      expect(onSave).not.toHaveBeenCalled()

      // Volver a su usuario saca el aviso y guarda.
      await user.click(screen.getByLabelText('Usuario de la app'))
      await user.click(screen.getByRole('option', { name: 'Martín Sosa' }))
      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
      await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))
      expect(onSave.mock.calls[0][0]).toMatchObject({ usuario_id: 'u-2' })
    })

    it('pasarle otro usuario también', async () => {
      const { onSave, user } = renderModal({ empleado: EMPLEADO })
      await user.click(screen.getByLabelText('Usuario de la app'))
      await user.click(screen.getByRole('option', { name: 'Pablo Ríos' }))
      expect(screen.getByRole('alert')).toHaveTextContent(AVISO_USUARIO)
      await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))
      expect(onSave).not.toHaveBeenCalled()
    })

    it('sin comisión pendiente se le cambia', async () => {
      comision.respuesta = { monto: 0, aviso: null, avisoUsuario: null }
      const { onSave, user } = renderModal({ empleado: EMPLEADO })
      await user.click(screen.getByLabelText('Usuario de la app'))
      await user.click(screen.getByRole('option', { name: 'Pablo Ríos' }))
      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
      await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))
      expect(onSave.mock.calls[0][0]).toMatchObject({ usuario_id: 'u-1' })
    })

    it('vincularle usuario a una ficha que no tenía no pregunta la comisión', async () => {
      const { onSave, user } = renderModal({ empleado: { ...EMPLEADO, usuario: null } })
      await user.click(screen.getByLabelText('Usuario de la app'))
      await user.click(screen.getByRole('option', { name: 'Pablo Ríos' }))
      expect(comision.pedida.every(p => !p.enabled)).toBe(true)
      expect(screen.queryByRole('alert')).not.toBeInTheDocument()
      await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))
      expect(onSave.mock.calls[0][0]).toMatchObject({ usuario_id: 'u-1' })
    })
  })

  describe('vínculos desde otra sucursal', () => {
    const AYUDA = 'Los vínculos se eligen desde esa sucursal: cambiá de sucursal o cargalos después.'

    it('editar a un empleado de otra sucursal deshabilita los tres vínculos y manda los que ya tenía', async () => {
      const { onSave, user } = renderModal({
        empleado: {
          ...EMPLEADO,
          sucursal_id: 2,
          cliente: { id: 10, nombre_fantasia: 'Kiosco Norte', activo: true },
          vehiculo: { id: 7, patente: 'AC456EF', descripcion: 'Partner' },
        },
        sucursalesUsuario: [TUCUMAN, TACO_POZO],
        tieneTodasLasSucursales: true,
      })

      expect(screen.getByLabelText('Usuario de la app')).toBeDisabled()
      expect(screen.getByLabelText('Ficha de cliente')).toBeDisabled()
      expect(screen.getByLabelText('Vehículo habitual')).toBeDisabled()
      expect(screen.getByText(AYUDA)).toBeInTheDocument()

      await user.click(screen.getByRole('button', { name: 'Guardar cambios' }))
      expect(onSave.mock.calls[0][0]).toMatchObject({
        id: 42, sucursal_id: 2, usuario_id: 'u-2', cliente_id: 10, vehiculo_id: 7,
      })
    })

    it('elegir la otra sucursal en el alta deshabilita los vínculos y no manda ninguno', async () => {
      const { onSave, user } = renderModal({ sucursalesUsuario: [TUCUMAN, TACO_POZO], tieneTodasLasSucursales: true })
      expect(screen.getByLabelText('Usuario de la app')).toBeEnabled()
      expect(screen.queryByText(AYUDA)).not.toBeInTheDocument()

      await cargarAlta(user)
      await user.type(screen.getByLabelText(/^Sueldo fijo/), '100000')
      await user.click(screen.getByLabelText('Vehículo habitual'))
      await user.click(screen.getByRole('option', { name: /AB123CD/ }))

      await user.click(screen.getByRole('button', { name: 'Taco Pozo' }))
      expect(screen.getByLabelText('Usuario de la app')).toBeDisabled()
      expect(screen.getByLabelText('Ficha de cliente')).toBeDisabled()
      expect(screen.getByLabelText('Vehículo habitual')).toBeDisabled()
      expect(screen.getByText(AYUDA)).toBeInTheDocument()

      await user.click(screen.getByRole('button', { name: 'Dar de alta' }))
      expect(onSave.mock.calls[0][0]).toMatchObject({
        sucursal_id: 2, usuario_id: null, cliente_id: null, vehiculo_id: null,
      })
    })

    it('"Las dos" y la sucursal actual dejan elegir vínculos', async () => {
      const { user } = renderModal({ sucursalesUsuario: [TUCUMAN, TACO_POZO], tieneTodasLasSucursales: true })
      await user.click(screen.getByRole('button', { name: 'Taco Pozo' }))
      expect(screen.getByLabelText('Usuario de la app')).toBeDisabled()
      await user.click(screen.getByRole('button', { name: 'Las dos' }))
      expect(screen.getByLabelText('Usuario de la app')).toBeEnabled()
      await user.click(screen.getByRole('button', { name: 'Tucumán' }))
      expect(screen.getByLabelText('Vehículo habitual')).toBeEnabled()
    })
  })

  describe('el usuario propio en el alta', () => {
    it('el alta no ofrece al usuario logueado', async () => {
      const { user } = renderModal({ usuarioPropioId: 'u-1' })
      await user.click(screen.getByLabelText('Usuario de la app'))
      expect(screen.queryByRole('option', { name: 'Pablo Ríos' })).not.toBeInTheDocument()
      expect(screen.getByRole('option', { name: 'Martín Sosa' })).toBeInTheDocument()
    })

    it('la edición sí ofrece al usuario propio (otro admin puede vincularlo)', async () => {
      const { user } = renderModal({ empleado: EMPLEADO, usuarioPropioId: 'u-1' })
      await user.click(screen.getByLabelText('Usuario de la app'))
      expect(screen.getByRole('option', { name: 'Pablo Ríos' })).toBeInTheDocument()
    })
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

// Decisión 4 del dueño (#1603): la X, Escape y el «atrás» del teléfono preguntan «Salir sin guardar» si el
// formulario cambió respecto de como abrió; sin tocar, cierran de una.
describe('ModalEmpleado — salir sin guardar', () => {
  const botonX = () => screen.getByRole('button', { name: /cerrar/i })

  beforeEach(() => {
    reiniciarAtrasModales()
    window.history.replaceState(null, '', '/')
  })

  it('un alta sin tocar, la X, Escape y el «atrás» cierran de una', async () => {
    const { onClose, user } = renderModal()
    await asentar()
    await user.click(botonX())
    expect(onClose).toHaveBeenCalledTimes(1)
    await user.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalledTimes(2)
    await atras()
    expect(onClose).toHaveBeenCalledTimes(3)
    expect(screen.queryByText('Salir sin guardar')).not.toBeInTheDocument()
  })

  it('una edición sin tocar no pregunta', async () => {
    const { onClose, user } = renderModal({ empleado: EMPLEADO })
    await asentar()
    await user.click(botonX())
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it.each([
    ['la X', async (user: ReturnType<typeof userEvent.setup>) => { await user.click(botonX()) }],
    ['Escape', async (user: ReturnType<typeof userEvent.setup>) => { await user.keyboard('{Escape}') }],
    ['el «atrás» del teléfono', async () => { await atras() }],
  ])('con el nombre tipeado, %s pregunta; «Seguir editando» conserva lo tipeado y «Salir igual» cierra', async (_camino, accion) => {
    const { onClose, user } = renderModal()
    await asentar()
    await user.type(screen.getByLabelText(/^Nombre y apellido/), 'Ana Gómez')
    await asentar()

    await accion(user)
    expect(await screen.findByText('Salir sin guardar')).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()

    await user.click(screen.getByRole('button', { name: 'Seguir editando' }))
    await asentar()
    expect(screen.getByLabelText(/^Nombre y apellido/)).toHaveValue('Ana Gómez')
    expect(onClose).not.toHaveBeenCalled()

    await accion(user)
    await user.click(await screen.findByRole('button', { name: 'Salir igual' }))
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('al editar y volver al valor de antes, ya no hay cambios y no pregunta', async () => {
    const { onClose, user } = renderModal({ empleado: EMPLEADO })
    await asentar()
    const telefono = screen.getByLabelText(/^Teléfono/)
    await user.type(telefono, '9')
    await user.type(telefono, '{Backspace}')
    await asentar()
    await user.click(botonX())
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})
