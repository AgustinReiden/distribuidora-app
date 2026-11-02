/**
 * ModalLiquidar (entrega 4 de gastos): liquidar el período pendiente más viejo de un empleado.
 * La vista previa y la mutation se mockean (módulo `usePersonalQuery`); lo que se prueba es qué
 * muestra el modal, cómo se mueve «A pagar» con el sueldo, y qué le manda al server.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { VistaPreviaLiquidacion } from '../../types/personal'
import { formatPrecio } from '../../utils/formatters'

/** El DOM normaliza el espacio duro que trae `formatPrecio` después del `$`. */
const plata = (n: number): string => formatPrecio(n).replace(/\s/g, ' ')

const mockLiquidar = vi.fn()
const mockRefetch = vi.fn()
const mockNotify = { success: vi.fn(), error: vi.fn() }
const estado = vi.hoisted(() => ({
  vista: null as VistaPreviaLiquidacion | null,
  isLoading: false,
  isError: false,
}))

vi.mock('../../hooks/queries/usePersonalQuery', () => ({
  useVistaPreviaLiquidacionQuery: () => ({
    data: estado.vista, isLoading: estado.isLoading, isError: estado.isError, refetch: mockRefetch,
  }),
  useLiquidarEmpleadoMutation: () => ({ mutateAsync: mockLiquidar }),
}))

vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => mockNotify,
}))

import ModalLiquidar, { modalLiquidarSchema } from './ModalLiquidar'

const HOY = '2026-10-30'

const VISTA: VistaPreviaLiquidacion = {
  periodo: { desde: '2026-10-26', hasta: '2026-11-01', frecuencia: 'semanal', mas_vencidos: 0 },
  puede_liquidar: true,
  en_curso: false,
  sueldo: { propuesto: 650000, arreglo_desde: '2026-09-01' },
  comisiones: {
    total: 368600,
    base: 18430000,
    detalle: [
      { pedido_id: 8701, fecha: '2026-10-26', entregado_el: '2026-10-27', cliente: 'Kiosco Luis', base: 10000000, comision: 200000 },
      { pedido_id: 8702, fecha: '2026-10-27', entregado_el: '2026-10-28', cliente: 'Almacén Sur', base: 8430000, comision: 168600 },
    ],
  },
  ajustes: {
    total: -1240,
    detalle: [{ pedido_id: 8655, motivo: 'Cambió la boleta del pedido', base: -62000, comision: -1240 }],
  },
  movimientos: [
    { id: 1, fecha: '2026-10-28', tipo: 'mercaderia', monto: -22800, observacion: null, pedido_id: 8701, gasto: null, revierte_id: null, por_el_mismo: false },
  ],
  saldo_anterior: 0,
  saldo_actual: -22800,
  a_pagar: 994560,
  avisos: [],
}

const EMPLEADO = { id: 7, nombre: 'Lucía Herrera', puesto: 'preventista', sucursal_id: 1, de_las_dos: false } as const
const TRANSPORTISTAS = [{ id: 'u-9', nombre: 'Martín Sosa' }, { id: 'u-10', nombre: 'Pablo Ríos' }]

function cargar(cambios: Partial<VistaPreviaLiquidacion> = {}) {
  estado.vista = { ...VISTA, ...cambios }
}

function renderModal(empleado: Partial<typeof EMPLEADO> = {}) {
  const onClose = vi.fn()
  render(
    <ModalLiquidar
      empleado={{ ...EMPLEADO, ...empleado }}
      nombreSucursal={id => (id === 1 ? 'Tucumán' : `Sucursal ${id}`)}
      transportistas={TRANSPORTISTAS}
      hoy={HOY}
      onClose={onClose}
    />,
  )
  return { onClose, user: userEvent.setup() }
}

const campoSueldo = () => screen.getByLabelText('Sueldo fijo') as HTMLInputElement
const campoPago = () => screen.getByLabelText('Monto que se le paga') as HTMLInputElement
const aPagarMostrado = () => screen.getByTestId('a-pagar').textContent?.replace(/\s/g, ' ')

describe('ModalLiquidar', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    estado.isLoading = false
    estado.isError = false
    mockLiquidar.mockResolvedValue(31)
    cargar()
  })

  it('muestra sueldo, comisiones, ajuste, movimiento, saldo anterior y a pagar', () => {
    renderModal()
    const dialogo = screen.getByRole('dialog', { name: 'Liquidar a Lucía Herrera' })
    expect(within(dialogo).getByText('Preventista · Tucumán · se le paga por semana')).toBeInTheDocument()
    expect(within(dialogo).getByText('Semana 26/10 al 01/11 · 26/10 al 01/11')).toBeInTheDocument()

    expect(campoSueldo().value).toBe('650.000,00')
    expect(within(dialogo).getByText('Arreglo vigente desde el 01/09/2026')).toBeInTheDocument()

    expect(within(dialogo).getByText(
      `2 pedidos entregados sin liquidar · base ${plata(18430000)} ·`,
      { exact: false },
    )).toBeInTheDocument()
    expect(within(dialogo).getByText(`+${plata(368600)}`)).toBeInTheDocument()

    expect(within(dialogo).getByText('Ajuste de comisión')).toBeInTheDocument()
    expect(within(dialogo).getByText('Cambió la boleta del pedido · pedido #8655')).toBeInTheDocument()
    expect(within(dialogo).getByText(`−${plata(1240)}`)).toBeInTheDocument()

    expect(within(dialogo).getByText('Mercadería')).toBeInTheDocument()
    expect(within(dialogo).getByText(`−${plata(22800)}`)).toBeInTheDocument()

    expect(within(dialogo).getByText('Saldo anterior')).toBeInTheDocument()
    expect(within(dialogo).getByText('Sin saldo pendiente')).toBeInTheDocument()

    // 650.000 + 368.600 − 1.240 − 22.800
    expect(aPagarMostrado()).toBe(plata(994560))
    expect(campoPago().value).toBe('994.560,00')
  })

  it('un saldo anterior distinto de cero lo muestra en lugar de "Sin saldo pendiente"', () => {
    cargar({ saldo_anterior: 5000 })
    renderModal()
    expect(screen.queryByText('Sin saldo pendiente')).not.toBeInTheDocument()
    expect(screen.getByText(plata(5000))).toBeInTheDocument()
  })

  it('corregir el sueldo mueve A pagar y el monto, y pide el motivo', async () => {
    const { user } = renderModal()
    expect(screen.queryByLabelText(/Por qué cambia el sueldo/)).not.toBeInTheDocument()

    await user.clear(campoSueldo())
    await user.type(campoSueldo(), '50000')

    // 50.000 + 368.600 − 1.240 − 22.800
    expect(aPagarMostrado()).toBe(plata(394560))
    expect(campoPago().value).toBe('394.560,00')
    expect(screen.getByLabelText(/Por qué cambia el sueldo/)).toBeInTheDocument()
  })

  it('sin motivo no deja; con motivo manda sueldo y motivo_sueldo', async () => {
    const { user } = renderModal()
    await user.clear(campoSueldo())
    await user.type(campoSueldo(), '50000')

    await user.click(screen.getByRole('button', { name: 'Confirmar y registrar el pago' }))
    expect(screen.getByRole('alert')).toHaveTextContent('Escribí por qué cambia el sueldo')
    expect(mockLiquidar).not.toHaveBeenCalled()

    await user.type(screen.getByLabelText(/Por qué cambia el sueldo/), 'Faltó dos días')
    await user.click(screen.getByRole('button', { name: 'Confirmar y registrar el pago' }))

    expect(mockLiquidar).toHaveBeenCalledWith({
      empleadoId: 7,
      liquidacion: expect.objectContaining({ sueldo: 50000, motivo_sueldo: 'Faltó dos días', pago: 394560, a_pagar_esperado: 394560 }),
    })
  })

  it('sin cambios manda motivo_sueldo: null', async () => {
    const { user } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Confirmar y registrar el pago' }))
    expect(mockLiquidar).toHaveBeenCalledWith({
      empleadoId: 7,
      liquidacion: expect.objectContaining({ sueldo: 650000, motivo_sueldo: null }),
    })
  })

  it("'arreglo_cambia' y 'periodo_parcial' avisan que se revise el sueldo", () => {
    cargar({ avisos: ['arreglo_cambia', 'periodo_parcial'] })
    renderModal()
    expect(screen.getByText('El arreglo cambia en este período: revisá el sueldo.')).toBeInTheDocument()
    expect(screen.getByText('Entró o se fue en este período: revisá el sueldo.')).toBeInTheDocument()
  })

  it("'comisiona_sin_usuario' avisa", () => {
    cargar({ avisos: ['comisiona_sin_usuario'] })
    renderModal()
    expect(screen.getByText('Comisiona, pero no tiene un usuario vinculado: no se le pueden calcular pedidos.')).toBeInTheDocument()
  })

  it('ver pedidos despliega la tabla', async () => {
    const { user } = renderModal()
    expect(screen.queryByRole('table')).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'ver pedidos' }))

    const tabla = screen.getByRole('table')
    expect(within(tabla).getAllByRole('columnheader').map(c => c.textContent))
      .toEqual(['Pedido', 'Entregado', 'Cliente', 'Base', 'Comisión'])
    expect(within(tabla).getByText('#8701')).toBeInTheDocument()
    expect(within(tabla).getByText('Kiosco Luis')).toBeInTheDocument()
    expect(within(tabla).getByText('27/10/2026')).toBeInTheDocument()
    expect(within(tabla).getByText(plata(168600))).toBeInTheDocument()
  })

  it('confirmar manda el período, el pago, la fecha y a_pagar_esperado, avisa y cierra', async () => {
    const { user, onClose } = renderModal()

    await user.click(screen.getByRole('button', { name: 'Confirmar y registrar el pago' }))

    expect(mockLiquidar).toHaveBeenCalledWith({
      empleadoId: 7,
      liquidacion: {
        desde: '2026-10-26',
        hasta: '2026-11-01',
        sueldo: 650000,
        motivo_sueldo: null,
        pago: 994560,
        fecha_pago: HOY,
        a_pagar_esperado: 994560,
        origen_pago: 'oficina',
        rendicion_transportista_id: null,
        rendicion_fecha: null,
      },
    })
    expect(mockNotify.success).toHaveBeenCalledWith('Liquidación registrada')
    expect(onClose).toHaveBeenCalled()
  })

  it('pagar menos manda ese monto', async () => {
    const { user } = renderModal()
    await user.clear(campoPago())
    await user.type(campoPago(), '500000')
    await user.click(screen.getByRole('button', { name: 'Confirmar y registrar el pago' }))
    expect(mockLiquidar).toHaveBeenCalledWith({
      empleadoId: 7,
      liquidacion: expect.objectContaining({ pago: 500000, a_pagar_esperado: 994560 }),
    })
  })

  it('tocar el monto deja de seguir a A pagar', async () => {
    const { user } = renderModal()
    await user.clear(campoPago())
    await user.type(campoPago(), '500000')

    await user.clear(campoSueldo())
    await user.type(campoSueldo(), '0')
    await user.type(screen.getByLabelText(/Por qué cambia el sueldo/), 'No trabajó')

    expect(campoPago().value).toBe('500000')
    expect(aPagarMostrado()).toBe(plata(344560))
  })

  it('más de lo que toca no deja, con el mensaje del server', async () => {
    const { user } = renderModal()
    await user.clear(campoPago())
    await user.type(campoPago(), '994561')
    await user.click(screen.getByRole('button', { name: 'Confirmar y registrar el pago' }))

    expect(screen.getByRole('alert')).toHaveTextContent(
      'No se le puede pagar más de lo que le toca: si le adelantás plata, cargá un adelanto',
    )
    expect(mockLiquidar).not.toHaveBeenCalled()
  })

  it("'280.000' se lee como 280000, y un texto ilegible avisa", async () => {
    const { user } = renderModal()
    await user.clear(campoPago())
    await user.type(campoPago(), '280.000')
    await user.click(screen.getByRole('button', { name: 'Confirmar y registrar el pago' }))
    expect(mockLiquidar).toHaveBeenCalledWith({
      empleadoId: 7,
      liquidacion: expect.objectContaining({ pago: 280000 }),
    })

    mockLiquidar.mockClear()
    await user.clear(campoPago())
    await user.type(campoPago(), 'doscientos')
    await user.click(screen.getByRole('button', { name: 'Confirmar y registrar el pago' }))
    expect(screen.getByRole('alert')).toHaveTextContent('Escribí el monto con números')
    expect(mockLiquidar).not.toHaveBeenCalled()
  })

  it('con la rendición pide transportista y día, y manda el origen, el chofer y el día', async () => {
    const { user } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Con la plata de una rendición' }))

    expect(screen.queryByLabelText('Fecha del pago')).not.toBeInTheDocument()
    expect(screen.getByLabelText('Día de la rendición')).toHaveValue(HOY)
    expect(screen.getByText(/El encargado y el chofer ven sólo el total pagado al personal/)).toBeInTheDocument()

    // Sin chofer no deja.
    await user.click(screen.getByRole('button', { name: 'Confirmar y registrar el pago' }))
    expect(screen.getByRole('alert'))
      .toHaveTextContent('Elegí de qué rendición sale la plata: el transportista y el día')
    expect(mockLiquidar).not.toHaveBeenCalled()

    await user.click(screen.getByRole('combobox', { name: 'Transportista' }))
    await user.click(screen.getByRole('option', { name: 'Martín Sosa' }))
    await user.click(screen.getByRole('button', { name: 'Confirmar y registrar el pago' }))

    expect(mockLiquidar).toHaveBeenCalledWith({
      empleadoId: 7,
      liquidacion: expect.objectContaining({
        origen_pago: 'rendicion',
        rendicion_transportista_id: 'u-9',
        rendicion_fecha: HOY,
        fecha_pago: HOY,
      }),
    })
  })

  it('con la oficina pide la fecha del pago, que no puede ser futura', async () => {
    const { user } = renderModal()
    const fecha = screen.getByLabelText('Fecha del pago') as HTMLInputElement
    expect(fecha.value).toBe(HOY)
    expect(fecha.max).toBe(HOY)

    await user.clear(fecha)
    await user.type(fecha, '2026-10-29')
    await user.click(screen.getByRole('button', { name: 'Confirmar y registrar el pago' }))
    expect(mockLiquidar).toHaveBeenCalledWith({
      empleadoId: 7,
      liquidacion: expect.objectContaining({ fecha_pago: '2026-10-29' }),
    })
  })

  it('con pago 0 no pregunta con qué plata, y manda la oficina', async () => {
    const { user } = renderModal()
    expect(screen.getByText('Con qué plata se paga')).toBeInTheDocument()

    await user.clear(campoPago())
    await user.type(campoPago(), '0')

    expect(screen.queryByText('Con qué plata se paga')).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Confirmar y registrar el pago' }))
    expect(mockLiquidar).toHaveBeenCalledWith({
      empleadoId: 7,
      liquidacion: expect.objectContaining({ pago: 0, origen_pago: 'oficina', rendicion_transportista_id: null, rendicion_fecha: null }),
    })
  })

  it("con A pagar negativo dice 'Queda debiendo' y el monto queda en 0", () => {
    cargar({ saldo_actual: -900000, sueldo: { propuesto: 100000, arreglo_desde: '2026-09-01' } })
    renderModal()

    expect(screen.getByText('Queda debiendo')).toBeInTheDocument()
    // 100.000 + 368.600 − 1.240 − 900.000
    expect(aPagarMostrado()).toBe(plata(432640))
    expect(campoPago()).toBeDisabled()
    expect(campoPago().value).toBe('0,00')
  })

  it('con en_curso lo avisa', () => {
    cargar({ en_curso: true })
    renderModal()
    expect(screen.getByText('Este período todavía no terminó: lo que se entregue después entra en el siguiente.'))
      .toBeInTheDocument()
  })

  it('con mas_vencidos lo avisa', () => {
    cargar({ periodo: { ...VISTA.periodo, mas_vencidos: 2 } })
    renderModal()
    expect(screen.getByText('Quedan 2 períodos más sin liquidar.')).toBeInTheDocument()
  })

  it('un movimiento por_el_mismo lleva el badge', () => {
    cargar({
      movimientos: [{ ...VISTA.movimientos[0], por_el_mismo: true }],
    })
    renderModal()
    expect(screen.getByText('Lo cargó su propio usuario')).toBeInTheDocument()
  })

  it('un error del server se muestra, no cierra y vuelve a pedir la vista previa', async () => {
    mockLiquidar.mockRejectedValue({
      message: 'Algo cambió desde que abriste la liquidación: revisá los números antes de confirmar',
    })
    const { user, onClose } = renderModal()

    await user.click(screen.getByRole('button', { name: 'Confirmar y registrar el pago' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Algo cambió desde que abriste la liquidación')
    expect(onClose).not.toHaveBeenCalled()
    expect(mockRefetch).toHaveBeenCalled()
  })

  it('la información de que las comisiones quedan fijas va sólo con pedidos', () => {
    renderModal()
    expect(screen.getByText(/las comisiones de esos 2 pedidos quedan fijas/)).toBeInTheDocument()
  })

  it('sin pedidos no hay fila de comisiones ni información', () => {
    cargar({ comisiones: { total: 0, base: 0, detalle: [] } })
    renderModal()
    expect(screen.queryByText('Comisiones')).not.toBeInTheDocument()
    expect(screen.queryByText(/quedan fijas/)).not.toBeInTheDocument()
  })

  it('null dice "No hay nada para liquidar."', () => {
    estado.vista = null
    renderModal()
    expect(screen.getByText('No hay nada para liquidar.')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Confirmar y registrar el pago' })).not.toBeInTheDocument()
  })

  it('cargando muestra el estado de carga', () => {
    estado.vista = null
    estado.isLoading = true
    renderModal()
    expect(screen.getByText('Cargando liquidación…')).toBeInTheDocument()
  })

  it('un error de la query muestra el estado de error con Reintentar', async () => {
    estado.vista = null
    estado.isError = true
    const { user } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Reintentar' }))
    expect(mockRefetch).toHaveBeenCalled()
  })

  it('Cancelar cierra sin liquidar', async () => {
    const { user, onClose } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Cancelar' }))
    expect(onClose).toHaveBeenCalled()
    expect(mockLiquidar).not.toHaveBeenCalled()
  })

  it('el schema repite las reglas del server', () => {
    const base = {
      sueldo: '650.000,00',
      motivo_sueldo: '',
      pago: '994.560,00',
      fecha_pago: HOY,
      origen_pago: 'oficina' as const,
      rendicion_transportista_id: null,
      rendicion_fecha: null,
      hoy: HOY,
      propuesto: 650000,
      vista: VISTA,
    }
    expect(modalLiquidarSchema.safeParse(base).success).toBe(true)
    expect(modalLiquidarSchema.safeParse({ ...base, sueldo: '-5' }).success).toBe(false)
    expect(modalLiquidarSchema.safeParse({ ...base, sueldo: '' }).success).toBe(false)
    expect(modalLiquidarSchema.safeParse({ ...base, pago: '999.999' }).success).toBe(false)
    expect(modalLiquidarSchema.safeParse({ ...base, fecha_pago: '2026-10-31' }).success).toBe(false)
  })
})
