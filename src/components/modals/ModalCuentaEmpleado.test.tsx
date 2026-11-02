/**
 * ModalCuentaEmpleado (entrega 3 de gastos): la cuenta corriente del empleado. Las queries y
 * mutations se mockean (módulo `usePersonalQuery`) y los dos modales anidados se reemplazan por
 * stubs: lo que se prueba es qué muestra la cuenta y qué le manda a cada uno.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type {
  CuentaEmpleado,
  DetalleLiquidacion,
  Empleado,
  LiquidacionResumen,
  MovimientoEmpleado,
  VistaPreviaLiquidacion,
} from '../../types/personal'
import { formatPrecio } from '../../utils/formatters'

/** El DOM normaliza el espacio duro que trae `formatPrecio` después del `$`. */
const plata = (n: number): string => formatPrecio(n).replace(/\s/g, ' ')

const mockRevertir = vi.fn()
const mockRegistrar = vi.fn()
const mockGuardarArreglo = vi.fn()
const mockAnular = vi.fn()
const mockLiquidacionQuery = vi.fn()
const mockReintentarDetalle = vi.fn()
const propsLiquidar = vi.hoisted(() => ({ current: null as unknown }))
const mockNotify = { success: vi.fn(), error: vi.fn() }
const estado = vi.hoisted(() => ({
  cuenta: null as unknown as CuentaEmpleado,
  isLoading: false,
  error: null as Error | null,
  vista: null as VistaPreviaLiquidacion | null,
  detalle: undefined as DetalleLiquidacion | undefined,
  detalleConError: false,
}))

vi.mock('../../hooks/queries/usePersonalQuery', () => ({
  useCuentaEmpleadoQuery: () => ({
    data: estado.cuenta, isLoading: estado.isLoading, error: estado.error, refetch: vi.fn(),
  }),
  useGuardarArregloMutation: () => ({ mutateAsync: mockGuardarArreglo }),
  useRegistrarMovimientoEmpleadoMutation: () => ({ mutateAsync: mockRegistrar }),
  useRevertirMovimientoEmpleadoMutation: () => ({ mutateAsync: mockRevertir }),
  useVistaPreviaLiquidacionQuery: () => ({ data: estado.vista }),
  useAnularLiquidacionMutation: () => ({ mutateAsync: mockAnular }),
  useLiquidacionQuery: (id: number | null) => {
    mockLiquidacionQuery(id)
    return {
      data: id === null ? undefined : estado.detalle,
      isLoading: false,
      isError: id !== null && estado.detalleConError,
      refetch: mockReintentarDetalle,
    }
  },
}))

vi.mock('../../hooks/queries/useUsuariosQuery', () => ({
  useTransportistasQuery: () => ({ data: [{ id: 'u-9', nombre: 'Pablo Ríos', rol: 'transportista' }] }),
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

vi.mock('./ModalLiquidar', () => ({
  default: (props: { onClose: () => void }) => {
    propsLiquidar.current = props
    return <div data-testid="stub-liquidar">modal liquidar</div>
  },
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
  arreglo: { ...VIGENTE }, arranque: '2025-02-03', saldo: 13500, es_propio: false, periodo: null,
}

const mov = (p: Partial<MovimientoEmpleado>): MovimientoEmpleado => ({
  id: 1, fecha: '2026-10-27', tipo: 'adelanto', monto: 20000, saldo: 0, observacion: null,
  pago_id: null, pedido_id: null, gasto: null, revierte_id: null, revertido: false,
  creado_por_nombre: null, created_at: '2026-10-27T12:00:00Z', liquidacion: null, rendicion: null, ...p,
})

const MERCADERIA = mov({ id: 10, fecha: '2026-10-27', tipo: 'mercaderia', monto: -10000, saldo: -15000, pedido_id: 8840, pago_id: 99 })
const ADELANTO = mov({ id: 11, fecha: '2026-10-26', tipo: 'adelanto', monto: -20000, saldo: -5000, observacion: 'Para el alquiler' })
const REVERTIDO = mov({ id: 12, fecha: '2026-10-20', tipo: 'ajuste', monto: 4000, saldo: 15000, revertido: true, observacion: 'Error de carga' })

function cargar(empleado: Partial<Empleado> = {}, movimientos: MovimientoEmpleado[] = [MERCADERIA, ADELANTO, REVERTIDO]) {
  estado.cuenta = {
    empleado: { ...EMPLEADO, ...empleado },
    arreglos: [{ ...ANTERIOR }, { ...VIGENTE }],
    movimientos,
    liquidaciones: [],
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
    estado.vista = null
    estado.detalle = undefined
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

  it("un arreglo futuro dice 'empieza el ...' y 'vigente' es sólo el del empleado", async () => {
    const FUTURO = { id: 6, vigente_desde: '2026-11-02', vigente_hasta: null, sueldo: 320000, frecuencia: 'semanal', comisiona: false } as const
    estado.cuenta = {
      empleado: { ...EMPLEADO },
      arreglos: [{ ...ANTERIOR }, { ...VIGENTE, vigente_hasta: null }, { ...FUTURO }],
      movimientos: [],
      liquidaciones: [],
    }
    const { user } = renderCuenta()
    await user.click(screen.getByRole('tab', { name: 'Arreglos' }))
    expect(screen.getAllByText('vigente')).toHaveLength(1)
    expect(screen.getByText('empieza el 02/11/2026')).toBeInTheDocument()
    expect(screen.getByText('hasta el 30/09/2026')).toBeInTheDocument()
  })

  it('un refetch en segundo plano que falla no reemplaza la cuenta que ya se ve', () => {
    estado.error = new Error('Sin conexión')
    renderCuenta()
    expect(screen.getByText('Saldo de la cuenta')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /reintentar/i })).not.toBeInTheDocument()
  })

  it('sin cuenta y con error muestra el estado de error', () => {
    estado.error = new Error('Sin conexión')
    estado.cuenta = undefined as unknown as CuentaEmpleado
    renderCuenta()
    expect(screen.queryByText('Saldo de la cuenta')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: /reintentar/i })).toBeInTheDocument()
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


const VISTA: VistaPreviaLiquidacion = {
  periodo: { desde: '2026-10-26', hasta: '2026-11-01', frecuencia: 'semanal', mas_vencidos: 0 },
  puede_liquidar: true,
  en_curso: true,
  sueldo: { propuesto: 280000, arreglo_desde: '2026-10-01' },
  comisiones: { total: 0, base: 0, detalle: [] },
  ajustes: { total: 0, detalle: [] },
  movimientos: [],
  saldo_anterior: 13500,
  saldo_actual: 13500,
  a_pagar: 293500,
  avisos: [],
}

const liquidacion = (o: Partial<LiquidacionResumen> = {}): LiquidacionResumen => ({
  id: 31,
  desde: '2026-10-19',
  hasta: '2026-10-25',
  frecuencia: 'semanal',
  sueldo: 280000,
  comision: 90000,
  ajuste: 0,
  a_pagar: 370000,
  pagado: 370000,
  fecha_pago: '2026-10-24',
  rendicion: null,
  anulada_at: null,
  motivo_anulacion: null,
  creado_por_nombre: 'Agustín',
  es_la_ultima: true,
  ...o,
})

describe('ModalCuentaEmpleado: liquidaciones', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    estado.isLoading = false
    estado.error = null
    estado.vista = { ...VISTA }
    estado.detalle = undefined
    estado.detalleConError = false
    mockAnular.mockResolvedValue(undefined)
    cargar()
  })

  it('muestra la próxima liquidación y el estimado', () => {
    renderCuenta()
    expect(screen.getByText(
      `Próxima liquidación: Semana 26/10 al 01/11. A pagar, estimado: ${plata(293500)}.`,
    )).toBeInTheDocument()
  })

  it('un estimado negativo dice que queda debiendo', () => {
    estado.vista = { ...VISTA, a_pagar: -5000 }
    renderCuenta()
    expect(screen.getByText(
      `Próxima liquidación: Semana 26/10 al 01/11. Queda debiendo, estimado: ${plata(5000)}.`,
    )).toBeInTheDocument()
  })

  it("'Liquidar semana' abre el modal anidado dentro del diálogo", async () => {
    const { user } = renderCuenta()
    expect(screen.queryByTestId('stub-liquidar')).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Liquidar semana' }))
    const dialogo = screen.getByRole('dialog', { name: 'Cuenta del empleado' })
    expect(within(dialogo).getByTestId('stub-liquidar')).toBeInTheDocument()
  })

  it('el modal de liquidar recibe el empleado, las sucursales y los choferes', async () => {
    const { user } = renderCuenta()
    await user.click(screen.getByRole('button', { name: 'Liquidar semana' }))
    expect(propsLiquidar.current).toMatchObject({
      empleado: { id: 42, nombre: 'Martín Sosa', puesto: 'transportista', sucursal_id: 1, de_las_dos: false },
      hoy: '2026-10-29',
      transportistas: [{ id: 'u-9', nombre: 'Pablo Ríos' }],
    })
  })

  it("una mensual dice 'Liquidar mes'", () => {
    estado.vista = { ...VISTA, periodo: { ...VISTA.periodo, desde: '2026-10-01', hasta: '2026-10-31', frecuencia: 'mensual' } }
    renderCuenta()
    expect(screen.getByRole('button', { name: 'Liquidar mes' })).toBeInTheDocument()
    expect(screen.getByText(/^Próxima liquidación: Octubre 2026\./)).toBeInTheDocument()
  })

  it('sin puede_liquidar no hay botón, y sí el texto', () => {
    estado.vista = { ...VISTA, puede_liquidar: false }
    renderCuenta()
    expect(screen.queryByRole('button', { name: /^Liquidar/ })).not.toBeInTheDocument()
    expect(screen.getByText(/^Próxima liquidación:/)).toBeInTheDocument()
  })

  it('sin vista previa (nada para liquidar) no hay texto ni botón', () => {
    estado.vista = null
    renderCuenta()
    expect(screen.queryByText(/^Próxima liquidación:/)).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^Liquidar/ })).not.toBeInTheDocument()
  })

  it('la cuenta propia no tiene Liquidar ni Anular', async () => {
    cargar({ es_propio: true })
    estado.cuenta.liquidaciones = [liquidacion()]
    estado.vista = { ...VISTA, puede_liquidar: false }
    const { user } = renderCuenta()
    expect(screen.queryByRole('button', { name: /^Liquidar/ })).not.toBeInTheDocument()
    await user.click(screen.getByRole('tab', { name: 'Liquidaciones' }))
    expect(screen.queryByRole('button', { name: /^Anular/ })).not.toBeInTheDocument()
  })

  it('las pestañas van Movimientos, Liquidaciones y Arreglos', () => {
    renderCuenta()
    expect(screen.getAllByRole('tab').map(t => t.textContent)).toEqual(['Movimientos', 'Liquidaciones', 'Arreglos'])
  })

  it('la pestaña Liquidaciones muestra período, pagado y sueldo', async () => {
    estado.cuenta.liquidaciones = [liquidacion()]
    const { user } = renderCuenta()
    await user.click(screen.getByRole('tab', { name: 'Liquidaciones' }))

    expect(screen.getByText('Semana 19/10 al 25/10')).toBeInTheDocument()
    expect(screen.getByText(`Pagado ${plata(370000)} el 24/10/2026`)).toBeInTheDocument()
    expect(screen.getByText(`Sueldo ${plata(280000)} · Comisión ${plata(90000)}`)).toBeInTheDocument()
  })

  it('con ajuste lo suma a la línea del sueldo', async () => {
    estado.cuenta.liquidaciones = [liquidacion({ ajuste: -1240 })]
    const { user } = renderCuenta()
    await user.click(screen.getByRole('tab', { name: 'Liquidaciones' }))
    expect(screen.getByText(`Sueldo ${plata(280000)} · Comisión ${plata(90000)} · Ajuste ${plata(-1240)}`)).toBeInTheDocument()
  })

  it("pagó menos: 'de {a_pagar}'", async () => {
    estado.cuenta.liquidaciones = [liquidacion({ pagado: 200000 })]
    const { user } = renderCuenta()
    await user.click(screen.getByRole('tab', { name: 'Liquidaciones' }))
    expect(screen.getByText(`Pagado ${plata(200000)} el 24/10/2026 de ${plata(370000)}`)).toBeInTheDocument()
  })

  it('pagada con una rendición lo dice', async () => {
    estado.cuenta.liquidaciones = [liquidacion({ rendicion: { transportista_nombre: 'Martín Sosa', fecha: '2026-10-24' } })]
    const { user } = renderCuenta()
    await user.click(screen.getByRole('tab', { name: 'Liquidaciones' }))
    expect(screen.getByText(
      `Pagado ${plata(370000)} el 24/10/2026 · de la rendición de Martín Sosa del 24/10`,
    )).toBeInTheDocument()
  })

  it('sin liquidaciones dice que todavía no se le liquidó nada', async () => {
    const { user } = renderCuenta()
    await user.click(screen.getByRole('tab', { name: 'Liquidaciones' }))
    expect(screen.getByText('Todavía no se le liquidó nada.')).toBeInTheDocument()
  })

  it("'Anular' sólo en la última, pide motivo y llama la mutation con { liquidacionId, motivo }", async () => {
    estado.cuenta.liquidaciones = [
      liquidacion({ id: 32, desde: '2026-10-26', hasta: '2026-11-01', es_la_ultima: true }),
      liquidacion({ id: 31, es_la_ultima: false }),
    ]
    const { user } = renderCuenta()
    await user.click(screen.getByRole('tab', { name: 'Liquidaciones' }))
    expect(screen.getAllByRole('button', { name: /^Anular/ })).toHaveLength(1)

    await user.click(screen.getByRole('button', { name: /^Anular/ }))
    expect(screen.getByText(
      'Se revierten sus movimientos y sus pedidos vuelven a quedar sin liquidar. Si el pago salió de una rendición ya cerrada, ese pago queda.',
    )).toBeInTheDocument()

    // Sin motivo no manda.
    await user.click(screen.getByRole('button', { name: 'Anular liquidación' }))
    expect(mockAnular).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toHaveTextContent('Escribí por qué se anula')

    await user.type(screen.getByLabelText(/^Por qué se anula/), '  Faltó una boleta  ')
    await user.click(screen.getByRole('button', { name: 'Anular liquidación' }))

    expect(mockAnular).toHaveBeenCalledWith({ liquidacionId: 32, motivo: 'Faltó una boleta' })
    expect(mockNotify.success).toHaveBeenCalledWith('Liquidación anulada')
  })

  it('si anular falla muestra el error y deja el motivo abierto', async () => {
    mockAnular.mockRejectedValue(new Error('Esa liquidación ya está anulada'))
    estado.cuenta.liquidaciones = [liquidacion()]
    const { user } = renderCuenta()
    await user.click(screen.getByRole('tab', { name: 'Liquidaciones' }))
    await user.click(screen.getByRole('button', { name: /^Anular/ }))
    await user.type(screen.getByLabelText(/^Por qué se anula/), 'Error')
    await user.click(screen.getByRole('button', { name: 'Anular liquidación' }))
    expect(await screen.findByText('Esa liquidación ya está anulada')).toBeInTheDocument()
    expect(screen.getByLabelText(/^Por qué se anula/)).toBeInTheDocument()
  })

  it('Cancelar cierra el motivo sin anular', async () => {
    estado.cuenta.liquidaciones = [liquidacion()]
    const { user } = renderCuenta()
    await user.click(screen.getByRole('tab', { name: 'Liquidaciones' }))
    await user.click(screen.getByRole('button', { name: /^Anular/ }))
    await user.click(screen.getByRole('button', { name: 'Cancelar' }))
    expect(screen.queryByLabelText(/^Por qué se anula/)).not.toBeInTheDocument()
    expect(mockAnular).not.toHaveBeenCalled()
  })

  it("una anulada dice 'Anulada' y su motivo, sin 'Anular'", async () => {
    estado.cuenta.liquidaciones = [
      liquidacion({ anulada_at: '2026-10-26T10:00:00Z', motivo_anulacion: 'Faltó una boleta', es_la_ultima: false }),
    ]
    const { user } = renderCuenta()
    await user.click(screen.getByRole('tab', { name: 'Liquidaciones' }))
    expect(screen.getByText('Anulada')).toBeInTheDocument()
    expect(screen.getByText('Faltó una boleta')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^Anular/ })).not.toBeInTheDocument()
  })

  it("'Ver detalle' pide useLiquidacionQuery con su id y muestra sueldo, pedidos y ajustes", async () => {
    estado.cuenta.liquidaciones = [liquidacion()]
    estado.detalle = {
      ...liquidacion(),
      sueldo_propuesto: 300000,
      motivo_sueldo: 'Faltó un día',
      pedidos: [{ pedido_id: 8701, fecha: '2026-10-20', entregado_el: '2026-10-21', cliente: 'Kiosco Luis', base: 4500000, comision: 90000 }],
      ajustes: [{ pedido_id: 8655, motivo: 'Cambió la boleta del pedido', base: -62000, comision: -1240 }],
    }
    const { user } = renderCuenta()
    await user.click(screen.getByRole('tab', { name: 'Liquidaciones' }))
    expect(mockLiquidacionQuery).toHaveBeenLastCalledWith(null)

    await user.click(screen.getByRole('button', { name: 'Ver detalle' }))

    expect(mockLiquidacionQuery).toHaveBeenLastCalledWith(31)
    expect(screen.getByText(`Sueldo ${plata(280000)} (el arreglo daba ${plata(300000)}): Faltó un día`)).toBeInTheDocument()
    expect(screen.getByText('#8701')).toBeInTheDocument()
    expect(screen.getByText('Kiosco Luis')).toBeInTheDocument()
    expect(screen.getByText('Cambió la boleta del pedido · pedido #8655')).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Ocultar detalle' }))
    expect(screen.queryByText('#8701')).not.toBeInTheDocument()
  })

  it("'Ver detalle' con la query en error ofrece reintentar, no 'Cargando detalle…' para siempre", async () => {
    estado.cuenta.liquidaciones = [liquidacion()]
    estado.detalleConError = true
    const { user } = renderCuenta()
    await user.click(screen.getByRole('tab', { name: 'Liquidaciones' }))
    await user.click(screen.getByRole('button', { name: 'Ver detalle' }))

    expect(screen.queryByText('Cargando detalle…')).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Reintentar' }))
    expect(mockReintentarDetalle).toHaveBeenCalled()
  })

  it('un pago suelto tiene Revertir, y uno de una liquidación no', () => {
    cargar({}, [
      mov({ id: 40, tipo: 'pago', monto: -50000, fecha: '2026-10-27' }),
      mov({
        id: 41, tipo: 'pago', monto: -370000, fecha: '2026-10-24',
        liquidacion: { id: 31, desde: '2026-10-19', hasta: '2026-10-25', frecuencia: 'semanal', pedidos: 3, anulada: false },
      }),
    ])
    renderCuenta()
    expect(screen.getAllByRole('button', { name: /^Revertir/ })).toHaveLength(1)
    expect(screen.getByRole('button', { name: 'Revertir Pago del 27/10' })).toBeInTheDocument()
  })

  it('el pie dice que el sueldo y las comisiones entran al liquidar', () => {
    renderCuenta()
    expect(screen.getByText(/ El sueldo y las comisiones entran al liquidar\.$/)).toBeInTheDocument()
  })
})
