/**
 * ModalResolverRendicion (gastos 6): el admin resuelve una disconformidad y, si quiere, imputa la
 * diferencia en líneas (deuda de un empleado, robo o pérdida, gasto que no se cargó). Las reglas
 * puras están en `utils/faltantesRendicion`; acá se prueba el cableado y lo que el modal congela.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { useState } from 'react'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { formatPrecio } from '../../utils/formatters'

const quien = vi.hoisted(() => ({ usuarioId: 'u-admin' }))
const empleadosStub = vi.hoisted(() => ({
  lista: [] as Array<{ id: number; nombre: string; usuario_id: string | null; vehiculo_id: number | null; activo: boolean }>,
  cargando: false,
  error: false,
  recargar: vi.fn(),
}))
const propsStub = vi.hoisted(() => ({ ultimas: null as Record<string, unknown> | null }))

vi.mock('../../hooks/queries/usePersonalQuery', () => ({
  useEmpleadosParaElegirQuery: () => ({
    data: empleadosStub.cargando || empleadosStub.error ? undefined : empleadosStub.lista,
    isLoading: empleadosStub.cargando,
    isError: empleadosStub.error,
    refetch: empleadosStub.recargar,
  }),
}))

vi.mock('../../hooks/usePropsModalGasto', () => ({
  usePropsModalGasto: () => ({
    rubros: [
      { id: 1, nombre: 'Combustible', grupo: 'vehiculos' },
      { id: 3, nombre: 'Peajes y estacionamiento', grupo: 'vehiculos' },
    ],
    vehiculos: [{ id: 3, sucursal_id: 1, patente: 'AC456EF', descripcion: 'Partner', activo: true }],
    sucursalActual: { id: 1, nombre: 'Tucumán' },
    sucursalesUsuario: [{ id: 1, nombre: 'Tucumán' }],
    sucursalesActivas: [{ id: 1, nombre: 'Tucumán' }],
    esAdmin: true,
    usuarioId: quien.usuarioId,
    tieneTodasLasSucursales: false,
    onCrearRubro: undefined,
  }),
}))

// El modal del gasto se reemplaza por un stub que muestra sus props y guarda un payload fijo.
const PAYLOAD_GASTO = {
  fecha: '2026-10-28', rubro_id: 3, monto_total: 500, comprobante: 'ninguno', sucursal_id: 1,
  compartido: false, mes_imputado: '2026-10-01', repartir_meses: 1, origen_pago: 'rendicion',
  rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-28',
}
vi.mock('./ModalGasto', () => ({
  default: (props: {
    desdeCierre?: unknown; avisoDeGuardado?: string; vehiculoInicialId?: number | null; borrador?: { id?: number } | null
    onSave: (p: unknown) => Promise<void>; onClose: () => void
  }) => {
    propsStub.ultimas = props as unknown as Record<string, unknown>
    return (
      <div data-testid="modal-gasto">
        <span data-testid="desde-cierre">{JSON.stringify(props.desdeCierre)}</span>
        <span data-testid="aviso-guardado">{props.avisoDeGuardado}</span>
        <span data-testid="borrador">{props.borrador ? JSON.stringify(props.borrador) : 'sin borrador'}</span>
        <button
          type="button"
          onClick={async () => {
            await props.onSave(props.borrador ? { ...props.borrador, monto_total: 700 } : PAYLOAD_GASTO)
            props.onClose()
          }}
        >
          Guardar desde el stub
        </button>
      </div>
    )
  },
}))

import ModalResolverRendicion, { type ModalResolverRendicionProps } from './ModalResolverRendicion'
import { MENSAJE_SIN_EMPLEADOS, MENSAJE_SUPERA } from '../../utils/faltantesRendicion'
import type { GastoDeRendicion } from '../../types/gastos'

/** formatPrecio separa con espacios no cortables; el texto del DOM los normaliza. */
const normal = (s: string): string => s.replace(/\s/g, ' ')

const visto = (id: number): string => `2026-10-28T13:05:${String(id).padStart(2, '0')}.123456+00:00`

const gasto = (id: number): GastoDeRendicion => ({
  id, sucursal_id: 1, compartido: false, fecha: '2026-10-28', rubro_id: 1, monto_total: 10000,
  comprobante: 'factura_a', comprobante_numero: null, alicuota_iva: 21, iva: 0, percepcion_iva: 0,
  percepcion_iibb: 0, otros_impuestos: 0, neto: 10000, costo: 10000, vehiculo_id: 3, litros: null,
  mes_imputado: '2026-10-01', repartir_meses: 1, mes_fin: '2026-10-01', origen_pago: 'rendicion',
  rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-28', empleado_id: null, observacion: null,
  creado_por: 'u-admin', anulado_at: null, created_at: '2026-10-28T10:00:00Z',
  rubro: { id: 1, nombre: 'Combustible', grupo: 'vehiculos' },
  vehiculo: { id: 3, patente: 'AC456EF', descripcion: 'Partner' },
  km_tablero: null, updated_at: visto(id),
})

function renderResolver(props: Partial<ModalResolverRendicionProps> = {}) {
  const onResolver = vi.fn<ModalResolverRendicionProps['onResolver']>(() => Promise.resolve())
  const onClose = vi.fn()
  const elemento = (extra: Partial<ModalResolverRendicionProps> = {}) => (
    <ModalResolverRendicion
      fecha="2026-10-28"
      transportistaId="tr-1"
      transportistaNombre="Tito Transportista"
      observacionesPrevias="Faltan $5.000"
      aEntregar={50000}
      gastos={[gasto(7)]}
      totalPagosPersonal={0}
      guardando={false}
      onResolver={onResolver}
      onClose={onClose}
      {...props}
      {...extra}
    />
  )
  const { rerender } = render(elemento())
  return {
    onResolver, onClose, user: userEvent.setup(),
    /** Lo que hace la vista cuando un refetch trae otras props mientras el modal sigue abierto. */
    conPropsNuevas: (extra: Partial<ModalResolverRendicionProps>) => rerender(elemento(extra)),
  }
}

const empleado = (id: number, nombre: string, extra: Partial<(typeof empleadosStub.lista)[number]> = {}) => (
  { id, nombre, usuario_id: null, vehiculo_id: null, activo: true, ...extra }
)

const BOTON_RESOLVER = { name: 'Marcar como resuelta' }

beforeEach(() => {
  quien.usuarioId = 'u-admin'
  propsStub.ultimas = null
  empleadosStub.cargando = false
  empleadosStub.error = false
  empleadosStub.recargar.mockReset()
  empleadosStub.lista = [
    empleado(1, 'Marcos Delgado', { usuario_id: 'tr-1' }),
    empleado(2, 'Ana Gómez'),
    empleado(3, 'El propio admin', { usuario_id: 'u-admin' }),
  ]
})

describe('ModalResolverRendicion — sin líneas', () => {
  it('resuelve con el texto, lineas: [] y lo visto al abrir', async () => {
    const { user, onResolver } = renderResolver({ totalPagosPersonal: 100000 })

    expect(screen.getByRole('button', BOTON_RESOLVER)).toBeDisabled()
    await user.type(screen.getByLabelText(/¿Cómo se resolvió\?/), '  Se cobró al día siguiente  ')
    await user.click(screen.getByRole('button', BOTON_RESOLVER))

    expect(onResolver).toHaveBeenCalledWith('Se cobró al día siguiente', {
      lineas: [],
      vistos: [{ id: 7, updated_at: visto(7) }],
      pagos_personal_visto: 100000,
    })
  })

  it('un refetch de gastos con el modal abierto no cambia los vistos que se mandan', async () => {
    const { user, onResolver, conPropsNuevas } = renderResolver({ totalPagosPersonal: 100000 })

    conPropsNuevas({ gastos: [gasto(7), gasto(8)], totalPagosPersonal: 250000 })
    await user.type(screen.getByLabelText(/¿Cómo se resolvió\?/), 'ok')
    await user.click(screen.getByRole('button', BOTON_RESOLVER))

    expect(onResolver.mock.calls[0][1].vistos).toEqual([{ id: 7, updated_at: visto(7) }])
    expect(onResolver.mock.calls[0][1].pagos_personal_visto).toBe(100000)
  })

  it('sin líneas no muestra la cuenta', () => {
    renderResolver()
    expect(screen.queryByText(/imputado/)).toBeNull()
  })
})

describe('ModalResolverRendicion — la línea de empleado', () => {
  it('arranca en el empleado vinculado al transportista', async () => {
    const { user, onResolver } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    await user.click(screen.getByRole('button', { name: 'A cargo del empleado' }))
    expect(screen.getByRole('combobox', { name: 'Empleado' })).toHaveValue('Marcos Delgado')

    await user.type(screen.getByLabelText('Monto'), '3.000')
    await user.type(screen.getByLabelText('Observación (opcional)'), 'Faltó en la caja')
    await user.type(screen.getByLabelText(/¿Cómo se resolvió\?/), 'Se le carga')
    await user.click(screen.getByRole('button', BOTON_RESOLVER))

    expect(onResolver).toHaveBeenCalledWith('Se le carga', {
      lineas: [{ causal: 'empleado', monto: 3000, empleado_id: 1, observacion: 'Faltó en la caja' }],
      vistos: [{ id: 7, updated_at: visto(7) }],
      pagos_personal_visto: 0,
    })
  })

  it('el propio admin no aparece en la lista', async () => {
    const { user } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    await user.click(screen.getByRole('button', { name: 'A cargo del empleado' }))
    await user.click(screen.getByRole('combobox', { name: 'Empleado' }))

    const opciones = await screen.findAllByRole('option')
    expect(opciones.map(o => o.textContent)).toEqual(['Ana Gómez', 'Marcos Delgado'])
  })

  it('sin empleado elegido no deja confirmar', async () => {
    empleadosStub.lista = [empleado(2, 'Ana Gómez')]
    const { user } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    await user.click(screen.getByRole('button', { name: 'A cargo del empleado' }))
    await user.type(screen.getByLabelText('Monto'), '1000')
    await user.type(screen.getByLabelText(/¿Cómo se resolvió\?/), 'ok')

    expect(screen.getByText('Elegí a qué empleado se le carga el faltante')).toBeInTheDocument()
    expect(screen.getByRole('button', BOTON_RESOLVER)).toBeDisabled()
  })

  it('sin empleados activos, la causal se deshabilita con el aviso', async () => {
    empleadosStub.lista = [empleado(2, 'Ana Gómez', { activo: false })]
    const { user } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))

    expect(screen.getByRole('button', { name: 'A cargo del empleado' })).toBeDisabled()
    expect(screen.getByText(MENSAJE_SIN_EMPLEADOS)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Robo o pérdida' })).toBeEnabled()
  })

  it('el aviso de alta sale una sola vez, aunque haya varias líneas', async () => {
    empleadosStub.lista = []
    const { user } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))

    expect(screen.getAllByRole('listitem')).toHaveLength(2)
    expect(screen.getAllByText(MENSAJE_SIN_EMPLEADOS)).toHaveLength(1)
  })

  it('mientras la lista carga, lo dice: la causal se deshabilita y no avisa que no hay empleados', async () => {
    empleadosStub.cargando = true
    const { user } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))

    expect(screen.getByText('Cargando empleados…')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'A cargo del empleado' })).toBeDisabled()
    expect(screen.queryByText(MENSAJE_SIN_EMPLEADOS)).toBeNull()
  })

  it('si la lista falla, lo dice y deja reintentar, sin decir que no hay empleados', async () => {
    empleadosStub.error = true
    const { user } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))

    expect(screen.getByText('No se pudo cargar la lista de empleados.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'A cargo del empleado' })).toBeDisabled()
    expect(screen.queryByText(MENSAJE_SIN_EMPLEADOS)).toBeNull()
    await user.click(screen.getByRole('button', { name: 'Reintentar' }))
    expect(empleadosStub.recargar).toHaveBeenCalledTimes(1)
  })
})

describe('ModalResolverRendicion — robo o pérdida y gasto que no se cargó', () => {
  it('robo o pérdida manda sólo monto y observación', async () => {
    const { user, onResolver } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    await user.click(screen.getByRole('button', { name: 'Robo o pérdida' }))
    await user.type(screen.getByLabelText('Monto'), '1000')
    await user.type(screen.getByLabelText(/¿Cómo se resolvió\?/), 'Se lo robaron')
    await user.click(screen.getByRole('button', BOTON_RESOLVER))

    expect(onResolver.mock.calls[0][1].lineas).toEqual([{ causal: 'robo_perdida', monto: 1000, observacion: null }])
  })

  it('un gasto cargado se suma con su monto y se puede editar', async () => {
    const { user, onResolver } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    await user.click(screen.getByRole('button', { name: 'Gasto que no se cargó' }))
    await user.click(screen.getByRole('button', { name: 'Cargar el gasto' }))
    expect(await screen.findByTestId('desde-cierre')).toHaveTextContent(
      JSON.stringify({ transportistaId: 'tr-1', transportistaNombre: 'Tito Transportista', fecha: '2026-10-28' }),
    )
    await user.click(screen.getByRole('button', { name: 'Guardar desde el stub' }))
    await waitFor(() => expect(screen.queryByTestId('modal-gasto')).not.toBeInTheDocument())

    expect(screen.getByText(normal(`Peajes y estacionamiento · ${formatPrecio(500)}`))).toBeInTheDocument()
    expect(screen.getByText(/queda/)).toHaveTextContent(normal(`imputado ${formatPrecio(500)}`))

    // Editar reabre el gasto con su borrador.
    await user.click(screen.getByRole('button', { name: /Editar/ }))
    expect(await screen.findByTestId('borrador')).toHaveTextContent('"monto_total":500')
    await user.click(screen.getByRole('button', { name: 'Guardar desde el stub' }))
    await waitFor(() => expect(screen.queryByTestId('modal-gasto')).not.toBeInTheDocument())
    expect(screen.getByText(normal(`Peajes y estacionamiento · ${formatPrecio(700)}`))).toBeInTheDocument()

    await user.type(screen.getByLabelText(/¿Cómo se resolvió\?/), 'Pagó un peaje')
    await user.click(screen.getByRole('button', BOTON_RESOLVER))

    expect(onResolver.mock.calls[0][1].lineas).toEqual([
      { causal: 'gasto_no_cargado', monto: 700, gasto: { ...PAYLOAD_GASTO, monto_total: 700 } },
    ])
  })

  it('una línea de gasto sin el gasto cargado no deja confirmar y dice que falta el gasto', async () => {
    const { user } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    await user.click(screen.getByRole('button', { name: 'Gasto que no se cargó' }))
    await user.type(screen.getByLabelText(/¿Cómo se resolvió\?/), 'ok')

    expect(screen.getByRole('button', BOTON_RESOLVER)).toBeDisabled()
    expect(screen.getByText('Cargá el gasto de cada línea de gasto')).toBeInTheDocument()
    expect(screen.queryByText('Cada línea lleva un monto mayor a 0')).toBeNull()
  })

  it('una línea de empleado sin empleado ni monto dice que falta el empleado, no el monto', async () => {
    empleadosStub.lista = [empleado(2, 'Ana Gómez')]
    const { user } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    await user.click(screen.getByRole('button', { name: 'A cargo del empleado' }))

    expect(screen.getByText('Elegí a qué empleado se le carga el faltante')).toBeInTheDocument()
  })

  it('la ventana del gasto dice cuándo se guarda de verdad', async () => {
    const { user } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    await user.click(screen.getByRole('button', { name: 'Gasto que no se cargó' }))
    await user.click(screen.getByRole('button', { name: 'Cargar el gasto' }))

    expect(await screen.findByTestId('aviso-guardado')).toHaveTextContent(
      'Se guarda cuando marques la rendición como resuelta.',
    )
  })
})

describe('ModalResolverRendicion — la cuenta y el tope', () => {
  it('la cuenta muestra a entregar, imputado y queda', async () => {
    const { user } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    await user.click(screen.getByRole('button', { name: 'Robo o pérdida' }))
    await user.type(screen.getByLabelText('Monto'), '3000')

    expect(screen.getByText(/^A entregar/)).toHaveTextContent(
      normal(`A entregar ${formatPrecio(50000)} · imputado ${formatPrecio(3000)} · queda ${formatPrecio(47000)}`),
    )
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('suma varias líneas', async () => {
    const { user } = renderResolver()

    for (const monto of ['3000', '2000']) {
      await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
      const lineas = screen.getAllByRole('listitem')
      const ultima = lineas[lineas.length - 1]
      await user.click(within(ultima).getByRole('button', { name: 'Robo o pérdida' }))
      await user.type(within(ultima).getByLabelText('Monto'), monto)
    }

    expect(screen.getByText(/^A entregar/)).toHaveTextContent(normal(`imputado ${formatPrecio(5000)} · queda ${formatPrecio(45000)}`))
  })

  it('imputar más de lo que había avisa y no deja confirmar', async () => {
    const { user, onResolver } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    await user.click(screen.getByRole('button', { name: 'Robo o pérdida' }))
    await user.type(screen.getByLabelText('Monto'), '50.000,01')
    await user.type(screen.getByLabelText(/¿Cómo se resolvió\?/), 'ok')

    expect(screen.getByRole('alert')).toHaveTextContent(MENSAJE_SUPERA)
    expect(screen.getByRole('button', BOTON_RESOLVER)).toBeDisabled()
    expect(onResolver).not.toHaveBeenCalled()
  })

  it('imputar exactamente lo que había sí deja confirmar', async () => {
    const { user } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    await user.click(screen.getByRole('button', { name: 'Robo o pérdida' }))
    await user.type(screen.getByLabelText('Monto'), '50000')
    await user.type(screen.getByLabelText(/¿Cómo se resolvió\?/), 'ok')

    expect(screen.queryByRole('alert')).toBeNull()
    expect(screen.getByRole('button', BOTON_RESOLVER)).toBeEnabled()
  })

  it('monto 0 o ilegible no deja confirmar', async () => {
    const { user } = renderResolver()

    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    await user.click(screen.getByRole('button', { name: 'Robo o pérdida' }))
    await user.type(screen.getByLabelText(/¿Cómo se resolvió\?/), 'ok')
    const monto = screen.getByLabelText('Monto')

    await user.type(monto, '0')
    expect(screen.getByText('Cada línea lleva un monto mayor a 0')).toBeInTheDocument()
    expect(screen.getByRole('button', BOTON_RESOLVER)).toBeDisabled()

    await user.clear(monto)
    await user.type(monto, 'mil pesos')
    expect(screen.getByRole('button', BOTON_RESOLVER)).toBeDisabled()
  })

  it('una línea sin causal no deja confirmar, y quitarla lo habilita', async () => {
    const { user } = renderResolver()

    await user.type(screen.getByLabelText(/¿Cómo se resolvió\?/), 'ok')
    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    expect(screen.getByText('Elegí la causal de cada línea')).toBeInTheDocument()
    expect(screen.getByRole('button', BOTON_RESOLVER)).toBeDisabled()

    await user.click(screen.getByRole('button', { name: 'Quitar la línea 1' }))
    expect(screen.getByRole('button', BOTON_RESOLVER)).toBeEnabled()
  })
})

describe('ModalResolverRendicion — mientras se manda', () => {
  it('nada se edita: causal, monto, observación, quitar, agregar y texto quedan deshabilitados', async () => {
    let terminar: () => void = () => {}
    const pendiente = new Promise<void>(resolve => { terminar = resolve })
    const onResolver = vi.fn<ModalResolverRendicionProps['onResolver']>(() => pendiente)
    function Contenedor() {
      const [guardando, setGuardando] = useState(false)
      return (
        <ModalResolverRendicion
          fecha="2026-10-28" transportistaId="tr-1" transportistaNombre="Tito Transportista"
          observacionesPrevias={null} aEntregar={50000} gastos={[gasto(7)]} totalPagosPersonal={0}
          guardando={guardando}
          onResolver={async (o, r) => { setGuardando(true); await onResolver(o, r); setGuardando(false) }}
          onClose={vi.fn()}
        />
      )
    }
    render(<Contenedor />)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    await user.click(screen.getByRole('button', { name: 'Robo o pérdida' }))
    await user.type(screen.getByLabelText('Monto'), '1000')
    await user.type(screen.getByLabelText('Observación (opcional)'), 'obs')
    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    const segunda = screen.getAllByRole('listitem')[1]
    await user.click(within(segunda).getByRole('button', { name: 'Gasto que no se cargó' }))
    await user.click(within(segunda).getByRole('button', { name: 'Cargar el gasto' }))
    await user.click(await screen.findByRole('button', { name: 'Guardar desde el stub' }))
    await waitFor(() => expect(screen.queryByTestId('modal-gasto')).not.toBeInTheDocument())
    await user.type(screen.getByLabelText(/¿Cómo se resolvió\?/), 'ok')

    await user.click(screen.getByRole('button', BOTON_RESOLVER))
    await waitFor(() => expect(onResolver).toHaveBeenCalledTimes(1))

    expect(screen.getByLabelText('Monto')).toBeDisabled()
    expect(screen.getByLabelText('Observación (opcional)')).toBeDisabled()
    expect(screen.getByLabelText(/¿Cómo se resolvió\?/)).toBeDisabled()
    expect(screen.getAllByRole('button', { name: 'Robo o pérdida' })[0]).toBeDisabled()
    expect(screen.getAllByRole('button', { name: 'A cargo del empleado' })[0]).toBeDisabled()
    expect(screen.getAllByRole('button', { name: 'Gasto que no se cargó' })[0]).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Quitar la línea 1' })).toBeDisabled()
    expect(screen.getByRole('button', { name: /Editar/ })).toBeDisabled()
    expect(screen.getByRole('button', { name: /Agregar línea/ })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Cancelar' })).toBeDisabled()
    // Lo que se mandó es lo que había al confirmar.
    expect(onResolver.mock.calls[0][1].lineas).toEqual([
      { causal: 'robo_perdida', monto: 1000, observacion: 'obs' },
      { causal: 'gasto_no_cargado', monto: 500, gasto: PAYLOAD_GASTO },
    ])

    terminar()
    await waitFor(() => expect(screen.getByLabelText('Monto')).toBeEnabled())
  })
})

describe('ModalResolverRendicion — teclado', () => {
  it('Enter en un campo no confirma', async () => {
    const { user, onResolver } = renderResolver()

    await user.type(screen.getByLabelText(/¿Cómo se resolvió\?/), 'ok')
    await user.click(screen.getByRole('button', { name: /Agregar línea/ }))
    await user.click(screen.getByRole('button', { name: 'Robo o pérdida' }))
    await user.type(screen.getByLabelText('Monto'), '1000{Enter}')
    await user.type(screen.getByLabelText('Observación (opcional)'), 'algo{Enter}')

    expect(onResolver).not.toHaveBeenCalled()
  })
})
