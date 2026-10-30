/**
 * ModalCuentaEmpleado (entrega 3 de gastos): la cuenta corriente del empleado. Las queries y
 * mutations se mockean (módulo `usePersonalQuery`) y los dos modales anidados se reemplazan por
 * stubs: lo que se prueba es qué muestra la cuenta y qué le manda a cada uno.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { CuentaEmpleado, Empleado, MovimientoEmpleado } from '../../types/personal'
import { formatPrecio } from '../../utils/formatters'

/** El DOM normaliza el espacio duro que trae `formatPrecio` después del `$`. */
const plata = (n: number): string => formatPrecio(n).replace(/\s/g, ' ')

const mockRevertir = vi.fn()
const mockRegistrar = vi.fn()
const mockGuardarArreglo = vi.fn()
const mockNotify = { success: vi.fn(), error: vi.fn() }
const estado = vi.hoisted(() => ({
  cuenta: null as unknown as CuentaEmpleado,
  isLoading: false,
  error: null as Error | null,
}))

vi.mock('../../hooks/queries/usePersonalQuery', () => ({
  useCuentaEmpleadoQuery: () => ({
    data: estado.cuenta, isLoading: estado.isLoading, error: estado.error, refetch: vi.fn(),
  }),
  useGuardarArregloMutation: () => ({ mutateAsync: mockGuardarArreglo }),
  useRegistrarMovimientoEmpleadoMutation: () => ({ mutateAsync: mockRegistrar }),
  useRevertirMovimientoEmpleadoMutation: () => ({ mutateAsync: mockRevertir }),
}))

vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => mockNotify,
}))

// Los stubs exponen un botón que llama al `onSave` recibido con un payload de ejemplo.
const MOVIMIENTO_EJEMPLO = { tipo: 'adelanto', monto: 20000, fecha: '2026-10-29', observacion: null } as const
const ARREGLO_EJEMPLO = { vigente_desde: '2026-10-26', sueldo: 300000, frecuencia: 'semanal', comisiona: true } as const

vi.mock('./ModalMovimientoEmpleado', () => ({
  default: ({ onSave }: { onSave: (m: typeof MOVIMIENTO_EJEMPLO) => Promise<void> }) => (
    <div data-testid="stub-movimiento">
      modal movimiento
      <button type="button" onClick={() => { void onSave(MOVIMIENTO_EJEMPLO) }}>guardar movimiento</button>
    </div>
  ),
}))
vi.mock('./ModalArregloEmpleado', () => ({
  default: ({ onSave }: { onSave: (a: typeof ARREGLO_EJEMPLO) => Promise<void> }) => (
    <div data-testid="stub-arreglo">
      modal arreglo
      <button type="button" onClick={() => { void onSave(ARREGLO_EJEMPLO) }}>guardar arreglo</button>
    </div>
  ),
}))

import ModalCuentaEmpleado from './ModalCuentaEmpleado'

const ANTERIOR = { id: 4, vigente_desde: '2025-02-03', vigente_hasta: '2026-09-30', sueldo: 250000, frecuencia: 'semanal', comisiona: false } as const
const VIGENTE = { id: 5, vigente_desde: '2026-10-01', vigente_hasta: null, sueldo: 280000, frecuencia: 'semanal', comisiona: false } as const

const EMPLEADO: Empleado = {
  id: 42, nombre: 'Martín Sosa', puesto: 'transportista', sucursal_id: 1, de_las_dos: false,
  cuil: '20301234567', fecha_ingreso: '2025-02-03', telefono: null, activo: true, fecha_baja: null,
  usuario: { id: 'u-2', nombre: 'msosa' },
  cliente: { id: 10, nombre_fantasia: 'Martín Sosa (empleado)', activo: true },
  vehiculo: { id: 7, patente: 'AC456EF', descripcion: 'Partner' },
  arreglo: { ...VIGENTE }, arranque: '2025-02-03', saldo: 13500, es_propio: false,
}

const mov = (p: Partial<MovimientoEmpleado>): MovimientoEmpleado => ({
  id: 1, fecha: '2026-10-27', tipo: 'adelanto', monto: 20000, saldo: 0, observacion: null,
  pago_id: null, pedido_id: null, gasto: null, revierte_id: null, revertido: false,
  creado_por_nombre: null, created_at: '2026-10-27T12:00:00Z', ...p,
})

const MERCADERIA = mov({ id: 10, fecha: '2026-10-27', tipo: 'mercaderia', monto: -10000, saldo: -15000, pedido_id: 8840, pago_id: 99 })
const ADELANTO = mov({ id: 11, fecha: '2026-10-26', tipo: 'adelanto', monto: -20000, saldo: -5000, observacion: 'Para el alquiler' })
const REVERTIDO = mov({ id: 12, fecha: '2026-10-20', tipo: 'ajuste', monto: 4000, saldo: 15000, revertido: true, observacion: 'Error de carga' })

function cargar(empleado: Partial<Empleado> = {}, movimientos: MovimientoEmpleado[] = [MERCADERIA, ADELANTO, REVERTIDO]) {
  estado.cuenta = {
    empleado: { ...EMPLEADO, ...empleado },
    arreglos: [{ ...ANTERIOR }, { ...VIGENTE }],
    movimientos,
  }
}

function renderCuenta(onEditar = vi.fn()) {
  const onClose = vi.fn()
  render(
    <ModalCuentaEmpleado
      empleadoId={42}
      nombreSucursal={id => (id === 1 ? 'Tucumán' : `Sucursal ${id}`)}
      hoy="2026-10-29"
      onEditar={onEditar}
      onClose={onClose}
    />,
  )
  return { onEditar, onClose, user: userEvent.setup() }
}

describe('ModalCuentaEmpleado', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    estado.isLoading = false
    estado.error = null
    mockRevertir.mockResolvedValue(undefined)
    mockRegistrar.mockResolvedValue(undefined)
    mockGuardarArreglo.mockResolvedValue(undefined)
    cargar()
  })

  it('el encabezado muestra nombre, puesto, sucursal, CUIL, ingreso y vínculos', async () => {
    const { onEditar, user } = renderCuenta()
    const dialogo = screen.getByRole('dialog', { name: 'Cuenta del empleado' })
    expect(within(dialogo).getByText('Martín Sosa', { selector: 'h3, h2' })).toBeInTheDocument()
    expect(within(dialogo).getByText('Transportista')).toBeInTheDocument()
    expect(within(dialogo).getByText('Tucumán')).toBeInTheDocument()
    expect(within(dialogo).getByText('CUIL 20-30123456-7 · ingresó el 03/02/2025')).toBeInTheDocument()
    expect(within(dialogo).getByText('Usuario msosa')).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Editar vínculos' }))
    expect(onEditar).toHaveBeenCalledWith(expect.objectContaining({ id: 42 }))
  })

  it('el CUIL y el ingreso salen sólo si hay dato', () => {
    cargar({ cuil: null, fecha_ingreso: '2025-02-03' })
    renderCuenta()
    expect(screen.getByText('Ingresó el 03/02/2025')).toBeInTheDocument()
    expect(screen.queryByText(/CUIL/)).not.toBeInTheDocument()
  })

  it('saldo a favor: con 13500 dice "A su favor: la empresa le debe"', () => {
    cargar({ saldo: 13500 }, [])
    renderCuenta()
    expect(screen.getByText('Saldo de la cuenta')).toBeInTheDocument()
    expect(screen.getByText('A su favor: la empresa le debe')).toBeInTheDocument()
    expect(screen.getByText(plata(13500))).toBeInTheDocument()
  })

  it('saldo en contra y al día', () => {
    cargar({ saldo: -15000 }, [])
    renderCuenta()
    expect(screen.getByText('Debe: le debe a la empresa')).toBeInTheDocument()
    expect(screen.getByText(plata(15000))).toBeInTheDocument()
  })

  it('saldo cero dice "Al día"', () => {
    cargar({ saldo: 0 }, [])
    renderCuenta()
    expect(screen.getByText('Al día')).toBeInTheDocument()
  })

  it('el arreglo vigente y el anterior', () => {
    renderCuenta()
    expect(screen.getByText('Arreglo vigente')).toBeInTheDocument()
    expect(screen.getByText('por semana')).toBeInTheDocument()
    expect(screen.getByText('No comisiona · desde el 01/10/2026')).toBeInTheDocument()
    expect(screen.getByText(/^Antes: .* por semana, del 03\/02\/2025 al 30\/09\/2026$/)).toBeInTheDocument()
  })

  it('los movimientos muestran concepto, importe y saldo', () => {
    renderCuenta()
    const fila = screen.getByText('Mercadería').closest('tr') as HTMLElement
    expect(within(fila).getByText('Pedido #8840 · pagado con adelanto de sueldo')).toBeInTheDocument()
    expect(within(fila).getByText(`−${plata(10000)}`)).toBeInTheDocument()
    expect(within(fila).getByText(plata(-15000))).toBeInTheDocument()
    expect(within(fila).getByText('27/10/2026')).toBeInTheDocument()
  })

  it('sin movimientos dice "Sin movimientos todavía."', () => {
    cargar({}, [])
    renderCuenta()
    expect(screen.getByText('Sin movimientos todavía.')).toBeInTheDocument()
  })

  it('un movimiento revertido lleva el badge "Revertido" y no se puede revertir', () => {
    renderCuenta()
    const fila = screen.getByText('Ajuste a favor').closest('tr') as HTMLElement
    expect(within(fila).getByText('Revertido')).toBeInTheDocument()
    expect(within(fila).queryByRole('button', { name: /^Revertir/ })).not.toBeInTheDocument()
  })

  it('una mercadería no tiene "Revertir"; un adelanto sí', () => {
    renderCuenta()
    const filaMercaderia = screen.getByText('Mercadería').closest('tr') as HTMLElement
    expect(within(filaMercaderia).queryByRole('button', { name: /Revertir/ })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Revertir Adelanto en efectivo del 26/10' })).toBeInTheDocument()
  })

  it('una reversión no se puede volver a revertir', () => {
    cargar({}, [mov({ id: 20, tipo: 'adelanto', monto: 20000, revierte_id: 11, observacion: 'Se cargó de más' })])
    renderCuenta()
    expect(screen.getByText('Revierte un adelanto en efectivo')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Revertir/ })).not.toBeInTheDocument()
  })

  it('revertir pide motivo y llama la mutation con { movimientoId, motivo }', async () => {
    const { user } = renderCuenta()
    await user.click(screen.getByRole('button', { name: 'Revertir Adelanto en efectivo del 26/10' }))

    // Sin motivo no manda.
    await user.click(screen.getByRole('button', { name: 'Revertir' }))
    expect(mockRevertir).not.toHaveBeenCalled()

    await user.type(screen.getByLabelText(/^Por qué se revierte/), '  Se cargó dos veces  ')
    await user.click(screen.getByRole('button', { name: 'Revertir' }))

    expect(mockRevertir).toHaveBeenCalledWith({ movimientoId: 11, motivo: 'Se cargó dos veces' })
    expect(mockNotify.success).toHaveBeenCalled()
  })

  it('Cancelar cierra el motivo sin revertir', async () => {
    const { user } = renderCuenta()
    await user.click(screen.getByRole('button', { name: 'Revertir Adelanto en efectivo del 26/10' }))
    await user.click(screen.getByRole('button', { name: 'Cancelar' }))
    expect(screen.queryByLabelText(/^Por qué se revierte/)).not.toBeInTheDocument()
    expect(mockRevertir).not.toHaveBeenCalled()
  })

  it('si revertir falla muestra el error en la fila', async () => {
    mockRevertir.mockRejectedValue(new Error('Ya estaba revertido'))
    const { user } = renderCuenta()
    await user.click(screen.getByRole('button', { name: 'Revertir Adelanto en efectivo del 26/10' }))
    await user.type(screen.getByLabelText(/^Por qué se revierte/), 'Error')
    await user.click(screen.getByRole('button', { name: 'Revertir' }))
    expect(await screen.findByText('Ya estaba revertido')).toBeInTheDocument()
  })

  it('la cuenta propia no tiene Movimiento, Cambiar arreglo ni Revertir', () => {
    cargar({ es_propio: true })
    renderCuenta()
    expect(screen.getByText('Es tu cuenta: los movimientos y el arreglo los carga otro admin.')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Movimiento' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Cambiar arreglo' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^Revertir/ })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Editar vínculos' })).toBeInTheDocument()
  })

  it('un empleado inactivo no tiene Cambiar arreglo', () => {
    cargar({ activo: false })
    renderCuenta()
    expect(screen.queryByRole('button', { name: 'Cambiar arreglo' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Movimiento' })).toBeInTheDocument()
  })

  it('Movimiento abre el modal anidado dentro del diálogo', async () => {
    const { user } = renderCuenta()
    expect(screen.queryByTestId('stub-movimiento')).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Movimiento' }))
    const dialogo = screen.getByRole('dialog', { name: 'Cuenta del empleado' })
    expect(within(dialogo).getByTestId('stub-movimiento')).toBeInTheDocument()
  })

  it('Cambiar arreglo abre el modal anidado dentro del diálogo', async () => {
    const { user } = renderCuenta()
    await user.click(screen.getByRole('button', { name: 'Cambiar arreglo' }))
    const dialogo = screen.getByRole('dialog', { name: 'Cuenta del empleado' })
    expect(within(dialogo).getByTestId('stub-arreglo')).toBeInTheDocument()
  })

  it('lo que guarda el modal de movimiento llega a la mutation con { empleadoId, movimiento }', async () => {
    const { user } = renderCuenta()
    await user.click(screen.getByRole('button', { name: 'Movimiento' }))
    await user.click(screen.getByRole('button', { name: 'guardar movimiento' }))
    expect(mockRegistrar).toHaveBeenCalledWith({ empleadoId: 42, movimiento: MOVIMIENTO_EJEMPLO })
    expect(mockNotify.success).toHaveBeenCalledWith('Movimiento registrado')
  })

  it('lo que guarda el modal de arreglo llega a la mutation con { empleadoId, arreglo }', async () => {
    const { user } = renderCuenta()
    await user.click(screen.getByRole('button', { name: 'Cambiar arreglo' }))
    await user.click(screen.getByRole('button', { name: 'guardar arreglo' }))
    expect(mockGuardarArreglo).toHaveBeenCalledWith({ empleadoId: 42, arreglo: ARREGLO_EJEMPLO })
    expect(mockNotify.success).toHaveBeenCalledWith('Arreglo guardado')
  })

  it("la pestaña Arreglos muestra 'hasta el 30/09/2026' y 'vigente'", async () => {
    const { user } = renderCuenta()
    await user.click(screen.getByRole('tab', { name: 'Arreglos' }))
    expect(screen.getByText('hasta el 30/09/2026')).toBeInTheDocument()
    expect(screen.getByText('vigente')).toBeInTheDocument()
    expect(screen.getByText(/^\$\s?250\.000,00 por semana · no comisiona · desde el 03\/02\/2025$/)).toBeInTheDocument()
  })

  it('el pie explica el signo del saldo', () => {
    renderCuenta()
    expect(screen.getByText(/^Saldo positivo: la empresa le debe\. Negativo: él le debe a la empresa\./)).toBeInTheDocument()
  })

  it('mientras carga muestra el estado de carga', () => {
    estado.isLoading = true
    estado.cuenta = undefined as unknown as CuentaEmpleado
    renderCuenta()
    expect(screen.getByText('Cargando cuenta…')).toBeInTheDocument()
  })
})
