/**
 * ModalCerrarRendicion (entrega 2 de gastos): el cierre muestra los gastos pagados con la plata
 * del día, trabaja en borrador y manda sólo los cambios. La lógica pura está en
 * `utils/rendicionGastos`; acá se prueba el cableado.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const quien = vi.hoisted(() => ({ esAdmin: true, usuarioId: 'u-admin' }))
const propsStub = vi.hoisted(() => ({ ultimas: null as Record<string, unknown> | null }))
const empleadosStub = vi.hoisted(() => ({
  lista: [] as Array<{ id: number; nombre: string; usuario_id: string | null; vehiculo_id: number | null; activo: boolean }>,
}))

vi.mock('../../hooks/queries/usePersonalQuery', () => ({
  useEmpleadosParaElegirQuery: () => ({ data: empleadosStub.lista }),
}))

vi.mock('../../hooks/usePropsModalGasto', () => ({
  usePropsModalGasto: () => ({
    rubros: [
      { id: 1, nombre: 'Combustible', grupo: 'vehiculos' },
      { id: 3, nombre: 'Librería', grupo: 'administracion' },
    ],
    vehiculos: [{ id: 3, sucursal_id: 1, patente: 'AC456EF', descripcion: 'Partner', activo: true }],
    sucursalActual: { id: 1, nombre: 'Tucumán' },
    sucursalesUsuario: [{ id: 1, nombre: 'Tucumán' }],
    sucursalesActivas: [{ id: 1, nombre: 'Tucumán' }],
    esAdmin: quien.esAdmin,
    usuarioId: quien.usuarioId,
    tieneTodasLasSucursales: false,
    onCrearRubro: undefined,
  }),
}))

// El modal del gasto se reemplaza por un stub que muestra sus props y guarda un payload fijo.
const PAYLOAD_NUEVO = {
  fecha: '2026-10-28', rubro_id: 3, monto_total: 4000, comprobante: 'ticket', sucursal_id: 1,
  compartido: false, mes_imputado: '2026-10-01', repartir_meses: 1, origen_pago: 'rendicion',
  rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-28',
}
vi.mock('./ModalGasto', () => ({
  default: (props: {
    desdeCierre?: unknown; vehiculoInicialId?: number | null; borrador?: { id?: number } | null; gasto?: { id: number } | null
    onSave: (p: unknown) => Promise<void>; onClose: () => void
  }) => {
    propsStub.ultimas = props as unknown as Record<string, unknown>
    return (
      <div data-testid="modal-gasto">
        <span data-testid="desde-cierre">{JSON.stringify(props.desdeCierre)}</span>
        <span data-testid="vehiculo-inicial">{JSON.stringify(props.vehiculoInicialId === undefined ? 'sin dato' : props.vehiculoInicialId)}</span>
        <span data-testid="borrador">{props.borrador ? JSON.stringify(props.borrador) : 'sin borrador'}</span>
        <button
          type="button"
          onClick={async () => {
            await props.onSave(props.borrador
              ? { ...props.borrador, monto_total: 70000 }
              : PAYLOAD_NUEVO)
            props.onClose()
          }}
        >
          Guardar desde el stub
        </button>
      </div>
    )
  },
}))

import ModalCerrarRendicion, { type ModalCerrarRendicionProps } from './ModalCerrarRendicion'
import type { GastoDeRendicion } from '../../types/gastos'

const NOTA_PIE =
  'Si lo pagó con plata propia, no va acá: se carga como gasto de «Un empleado» y se le devuelve con el sueldo.'

/** El `updated_at` de un gasto, con microsegundos y huso como lo devuelve Postgres. */
const visto = (id: number): string => `2026-10-28T13:05:${String(id).padStart(2, '0')}.123456+00:00`

const gastoDeRendicion = (id: number, monto: number, extra: Partial<GastoDeRendicion> = {}): GastoDeRendicion => ({
  id, sucursal_id: 1, compartido: false, fecha: '2026-10-28', rubro_id: 1, monto_total: monto,
  comprobante: 'factura_a', comprobante_numero: '0005-00012345', alicuota_iva: 21, iva: 0, percepcion_iva: 0,
  percepcion_iibb: 0, otros_impuestos: 0, neto: monto, costo: monto, vehiculo_id: 3, litros: 38.5,
  mes_imputado: '2026-10-01', repartir_meses: 1, mes_fin: '2026-10-01', origen_pago: 'rendicion',
  rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-28', empleado_id: null, observacion: null,
  creado_por: 'u-admin', anulado_at: null, created_at: '2026-10-28T10:00:00Z',
  rubro: { id: 1, nombre: 'Combustible', grupo: 'vehiculos' },
  vehiculo: { id: 3, patente: 'AC456EF', descripcion: 'Partner' },
  km_tablero: 184230, updated_at: visto(id), ...extra,
})

function renderCierre(props: Partial<ModalCerrarRendicionProps> = {}) {
  const onConfirmar = vi.fn<ModalCerrarRendicionProps['onConfirmar']>(() => Promise.resolve())
  const onClose = vi.fn()
  render(
    <ModalCerrarRendicion
      fecha="2026-10-28"
      transportistaId="tr-1"
      transportistaNombre="Tito Transportista"
      totalCobrado={1500000}
      totalEntregado={1500000}
      totalEntregas={1200000}
      totalCtasCte={300000}
      totalEfectivo={1245300}
      gastos={[]}
      guardando={false}
      onConfirmar={onConfirmar}
      onClose={onClose}
      {...props}
    />,
  )
  return { onConfirmar, onClose, user: userEvent.setup() }
}

beforeEach(() => {
  quien.esAdmin = true
  quien.usuarioId = 'u-admin'
  propsStub.ultimas = null
  empleadosStub.lista = []
})

describe('ModalCerrarRendicion — efectivo a entregar', () => {
  it('muestra el efectivo cobrado, los gastos y lo que se entrega', () => {
    renderCierre({ gastos: [gastoDeRendicion(7, 50000)] })

    expect(screen.getByText('Cobrado en efectivo')).toBeInTheDocument()
    expect(screen.getByText('Gastos pagados con esa plata (1)')).toBeInTheDocument()
    const entregar = screen.getByText('A entregar').parentElement!
    expect(entregar).toHaveTextContent(/1\.195\.300,00/)
  })

  it('con gastos de más, A entregar va en rojo y avisa', () => {
    renderCierre({ totalEfectivo: 0, gastos: [gastoDeRendicion(7, 5000)] })

    expect(screen.getByText('Los gastos superan el efectivo cobrado.')).toBeInTheDocument()
    const monto = within(screen.getByText('A entregar').parentElement!).getByText(/5\.000,00/)
    expect(monto).toHaveClass('text-red-600')
  })

  it('sin gastos dice "Sin gastos pagados con esta plata"', () => {
    renderCierre()
    expect(screen.getByText('Sin gastos pagados con esta plata')).toBeInTheDocument()
    expect(screen.getByText(NOTA_PIE)).toBeInTheDocument()
  })

  it('cada fila dice rubro, vehículo, comprobante, litros y monto', () => {
    renderCierre({ gastos: [gastoDeRendicion(7, 50000)] })

    expect(screen.getByText('Combustible · Partner AC456EF')).toBeInTheDocument()
    expect(screen.getByText(/Factura A 0005-00012345 · 38,5 litros/)).toBeInTheDocument()
  })
})

/**
 * Guarda desde el stub y espera a que el editor se cierre: el stub cierra después de un `await`,
 * y bajo carga la aserción inmediata corría antes del cierre (#1348).
 */
async function guardarDesdeElStub(user: ReturnType<typeof userEvent.setup>) {
  await user.click(await screen.findByRole('button', { name: 'Guardar desde el stub' }))
  await waitFor(() => expect(screen.queryByTestId('modal-gasto')).not.toBeInTheDocument())
}

describe('ModalCerrarRendicion — agregar, quitar y confirmar', () => {
  it('agregar suma al borrador sin ir al server', async () => {
    const { user, onConfirmar } = renderCierre({ gastos: [gastoDeRendicion(7, 50000)] })

    await user.click(screen.getByRole('button', { name: /Agregar gasto/ }))
    expect(await screen.findByTestId('desde-cierre')).toHaveTextContent(
      JSON.stringify({ transportistaId: 'tr-1', transportistaNombre: 'Tito Transportista', fecha: '2026-10-28' }),
    )
    expect(screen.getByTestId('borrador')).toHaveTextContent('sin borrador')

    await guardarDesdeElStub(user)

    expect(screen.getByText('Librería')).toBeInTheDocument()
    expect(screen.getByText('Gastos pagados con esa plata (2)')).toBeInTheDocument()
    expect(within(screen.getByText('A entregar').parentElement!).getByText(/1\.191\.300,00/)).toBeInTheDocument()
    expect(onConfirmar).not.toHaveBeenCalled()
  })

  it('quitar uno guardado lo tacha y lo saca del total; deshacer lo devuelve', async () => {
    const { user } = renderCierre({ gastos: [gastoDeRendicion(7, 50000)] })

    await user.click(screen.getByRole('button', { name: 'Quitar gasto de Combustible' }))
    expect(screen.getByText('Se quita al confirmar')).toBeInTheDocument()
    expect(screen.getByText('Gastos pagados con esa plata (0)')).toBeInTheDocument()
    expect(within(screen.getByText('A entregar').parentElement!).getByText(/1\.245\.300,00/)).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Deshacer' }))
    expect(screen.queryByText('Se quita al confirmar')).not.toBeInTheDocument()
    expect(screen.getByText('Gastos pagados con esa plata (1)')).toBeInTheDocument()
  })

  it('quitar un borrador lo saca de la lista', async () => {
    const { user } = renderCierre()
    await user.click(screen.getByRole('button', { name: /Agregar gasto/ }))
    await guardarDesdeElStub(user)
    await user.click(screen.getByRole('button', { name: 'Quitar gasto de Librería' }))

    expect(screen.queryByText('Librería')).not.toBeInTheDocument()
    expect(screen.queryByText('Se quita al confirmar')).not.toBeInTheDocument()
  })

  it('confirmar manda los cambios: lo editado, lo nuevo y lo quitado', async () => {
    const siete = gastoDeRendicion(7, 50000)
    const ocho = gastoDeRendicion(8, 12000)
    const { user, onConfirmar } = renderCierre({ gastos: [siete, ocho] })

    // Editar el 7: el stub devuelve el borrador con 70000 y el modal lo marca como editado.
    await user.click(screen.getAllByRole('button', { name: 'Editar gasto de Combustible' })[0])
    expect(await screen.findByTestId('borrador')).toHaveTextContent('"id":7')
    expect((propsStub.ultimas as { gasto: { id: number } }).gasto.id).toBe(7)
    await guardarDesdeElStub(user)
    // Quitar el 8.
    await user.click(screen.getAllByRole('button', { name: 'Quitar gasto de Combustible' })[1])
    // Agregar uno nuevo.
    await user.click(screen.getByRole('button', { name: /Agregar gasto/ }))
    await guardarDesdeElStub(user)

    await user.click(screen.getByRole('button', { name: 'Confirmar rendición' }))

    expect(onConfirmar).toHaveBeenCalledTimes(1)
    const [estado, observaciones, cambios] = onConfirmar.mock.calls[0]
    expect(estado).toBe('confirmada')
    expect(observaciones).toBeNull()
    expect(cambios.vistos).toEqual([{ id: 7, updated_at: visto(7) }, { id: 8, updated_at: visto(8) }])
    expect(cambios.quitar).toEqual([8])
    expect(cambios.guardar).toHaveLength(2)
    expect(cambios.guardar[0]).toMatchObject({ id: 7, monto_total: 70000, origen_pago: 'rendicion' })
    expect(cambios.guardar[1]).toMatchObject({ monto_total: 4000, rubro_id: 3 })
    expect(cambios.guardar[1].id).toBeUndefined()
  })

  it('editar un gasto cuyo rubro no trae el flag conserva litros y km en la fila y en lo que se confirma', async () => {
    // El rubro de `obtener_gastos_rendiciones` no trae `pide_litros_km`.
    const { user, onConfirmar } = renderCierre({ gastos: [gastoDeRendicion(7, 50000)] })
    await user.click(screen.getByRole('button', { name: 'Editar gasto de Combustible' }))
    await guardarDesdeElStub(user)

    expect(screen.getByText(/Factura A 0005-00012345 · 38,5 litros/)).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Confirmar rendición' }))
    expect(onConfirmar.mock.calls[0][2].guardar[0]).toMatchObject({ id: 7, monto_total: 70000, litros: 38.5, km_tablero: 184230 })
  })

  it('sin tocar nada, confirmar manda los gastos como vistos y nada más', async () => {
    const { user, onConfirmar } = renderCierre({ gastos: [gastoDeRendicion(7, 50000)] })
    await user.click(screen.getByRole('button', { name: 'Confirmar rendición' }))

    expect(onConfirmar).toHaveBeenCalledWith('confirmada', null, {
      vistos: [{ id: 7, updated_at: visto(7) }], guardar: [], quitar: [],
    })
  })

  it('cancelar no confirma', async () => {
    const { user, onConfirmar, onClose } = renderCierre({ gastos: [gastoDeRendicion(7, 50000)] })
    await user.click(screen.getByRole('button', { name: 'Cancelar' }))

    expect(onClose).toHaveBeenCalledTimes(1)
    expect(onConfirmar).not.toHaveBeenCalled()
  })
})

describe('ModalCerrarRendicion — permisos', () => {
  it('el encargado no tiene Editar ni Quitar en un gasto del admin, y puede confirmar igual', async () => {
    quien.esAdmin = false
    quien.usuarioId = 'u-encargado'
    const { user, onConfirmar } = renderCierre({
      gastos: [gastoDeRendicion(7, 50000, { creado_por: 'u-admin' }), gastoDeRendicion(8, 9000, { creado_por: 'u-encargado' })],
    })

    // Del admin, ninguna acción; del encargado, las dos.
    expect(screen.getAllByRole('button', { name: /Editar gasto de/ })).toHaveLength(1)
    expect(screen.getAllByRole('button', { name: /Quitar gasto de/ })).toHaveLength(1)

    await user.click(screen.getByRole('button', { name: 'Confirmar rendición' }))
    expect(onConfirmar).toHaveBeenCalledWith('confirmada', null, {
      vistos: [{ id: 7, updated_at: visto(7) }, { id: 8, updated_at: visto(8) }], guardar: [], quitar: [],
    })
  })
})

describe('ModalCerrarRendicion — el vehículo habitual del chofer', () => {
  const EMPLEADOS = [
    { id: 1, nombre: 'Otro Chofer', usuario_id: 'tr-9', vehiculo_id: 8, activo: true },
    { id: 2, nombre: 'Tito Transportista', usuario_id: 'tr-1', vehiculo_id: 3, activo: true },
  ]

  it('Agregar gasto precarga el vehículo habitual del chofer', async () => {
    empleadosStub.lista = EMPLEADOS
    const { user } = renderCierre()
    await user.click(screen.getByRole('button', { name: /Agregar gasto/ }))

    expect(await screen.findByTestId('vehiculo-inicial')).toHaveTextContent('3')
    // `desdeCierre` no gana ninguna clave.
    expect(screen.getByTestId('desde-cierre')).toHaveTextContent(
      JSON.stringify({ transportistaId: 'tr-1', transportistaNombre: 'Tito Transportista', fecha: '2026-10-28' }),
    )
  })

  it('Editar no lo pasa', async () => {
    empleadosStub.lista = EMPLEADOS
    const { user } = renderCierre({ gastos: [gastoDeRendicion(7, 50000)] })
    await user.click(screen.getByRole('button', { name: 'Editar gasto de Combustible' }))

    expect(await screen.findByTestId('vehiculo-inicial')).toHaveTextContent('sin dato')
    expect((propsStub.ultimas as { vehiculoInicialId?: number | null }).vehiculoInicialId).toBeUndefined()
  })

  it('sin empleado vinculado al chofer, va null', async () => {
    empleadosStub.lista = [EMPLEADOS[0]]
    const { user } = renderCierre()
    await user.click(screen.getByRole('button', { name: /Agregar gasto/ }))

    expect(await screen.findByTestId('vehiculo-inicial')).toHaveTextContent('null')
  })

  it('un empleado dado de baja no cuenta', async () => {
    empleadosStub.lista = [{ ...EMPLEADOS[1], activo: false }]
    const { user } = renderCierre()
    await user.click(screen.getByRole('button', { name: /Agregar gasto/ }))

    expect(await screen.findByTestId('vehiculo-inicial')).toHaveTextContent('null')
  })

  it('la nota del pie dice «Un empleado»', () => {
    renderCierre()
    expect(screen.getByText(NOTA_PIE)).toBeInTheDocument()
  })
})
