/**
 * ModalGasto (entrega 1 de gastos): arranca con lo mínimo y el resto aparece
 * según lo que se elige. Los valores numéricos son los del plan: 50.000 con
 * factura A al 21% dan IVA 8.677,69 y neto 41.322,31.
 */
import { describe, it, expect, vi, beforeEach, type Mock } from 'vitest'
import { fireEvent, render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
// La lectura de km del gasto vive en `vehiculo_km`: el modal la pide con un hook que acá se
// reemplaza por el valor que se quiera.
const kmDelGasto = vi.hoisted(() => ({ data: null as number | null, isLoading: false, isError: false }))
/** Los ids con que el modal pidió la lectura: `null` es "no consultar" (el hook queda deshabilitado). */
const kmPedidos = vi.hoisted(() => [] as Array<number | null>)
vi.mock('../../hooks/queries/useGastosQuery', () => ({
  useKmDelGastoQuery: (gastoId: number | null) => {
    kmPedidos.push(gastoId)
    return kmDelGasto
  },
}))

beforeEach(() => {
  kmPedidos.length = 0
  kmDelGasto.data = null
  kmDelGasto.isLoading = false
  kmDelGasto.isError = false
})

import ModalGasto, { modalGastoSchema, type ModalGastoProps } from './ModalGasto'
import type { GuardarGastoPayload, RubroGasto, Vehiculo } from '../../types/gastos'
import { payloadDeGasto } from '../../utils/rendicionGastos'
import type { EmpleadoParaElegir } from '../../types/personal'

const rubro = (r: Partial<RubroGasto> & Pick<RubroGasto, 'id' | 'nombre' | 'grupo'>): RubroGasto => ({
  palabras_busqueda: null,
  pide_litros_km: false,
  reparto_sugerido_meses: null,
  sugiere_mes_anterior: false,
  activo: true,
  ...r,
})

const RUBROS: RubroGasto[] = [
  rubro({ id: 1, nombre: 'Combustible', grupo: 'vehiculos', pide_litros_km: true, palabras_busqueda: 'nafta gasoil gnc' }),
  rubro({ id: 2, nombre: 'Seguro', grupo: 'vehiculos', reparto_sugerido_meses: 12 }),
  rubro({ id: 3, nombre: 'Librería', grupo: 'administracion', palabras_busqueda: 'papeleria' }),
  rubro({ id: 4, nombre: 'Ingresos brutos', grupo: 'impuestos', sugiere_mes_anterior: true }),
]

const VEHICULOS: Vehiculo[] = [
  { id: 7, sucursal_id: 1, patente: 'AC456EF', descripcion: 'Partner', activo: true },
  { id: 8, sucursal_id: 1, patente: 'AB123CD', descripcion: 'Hilux', activo: true },
]

const TUCUMAN = { id: 1, nombre: 'Tucumán' }
const TACO_POZO = { id: 2, nombre: 'Taco Pozo' }

type OnSave = ModalGastoProps['onSave']

function renderModal(props: Partial<ModalGastoProps> = {}) {
  const onSave: Mock<OnSave> = (props.onSave as Mock<OnSave>) ?? vi.fn<OnSave>(() => Promise.resolve())
  const onClose: Mock<() => void> = vi.fn()
  render(
    <ModalGasto
      rubros={RUBROS}
      vehiculos={VEHICULOS}
      sucursalActual={TUCUMAN}
      sucursalesUsuario={[TUCUMAN]}
      sucursalesActivas={[TUCUMAN, TACO_POZO]}
      esAdmin
      onSave={onSave}
      onClose={onClose}
      {...props}
    />,
  )
  return { onSave, onClose, user: userEvent.setup() }
}

async function elegirRubro(user: ReturnType<typeof userEvent.setup>, nombre: string) {
  await user.click(screen.getByLabelText(/^Rubro/))
  await user.click(screen.getByRole('option', { name: new RegExp(nombre) }))
}

const poner = (etiqueta: RegExp | string, valor: string) =>
  fireEvent.change(screen.getByLabelText(etiqueta), { target: { value: valor } })

describe('ModalGasto — lo mínimo', () => {
  it('arranca con rubro, monto, fecha y los seis botones de comprobante', () => {
    renderModal()

    expect(screen.getByText('Registrar gasto')).toBeInTheDocument()
    expect(screen.getByLabelText(/^Rubro/)).toBeInTheDocument()
    expect(screen.getByLabelText(/Monto total/)).toBeInTheDocument()
    expect(screen.getByLabelText(/^Fecha/)).toBeInTheDocument()
    for (const nombre of ['Factura A', 'Factura B', 'Factura C', 'Recibo', 'Ticket', 'Sin comprobante']) {
      expect(screen.getByRole('button', { name: nombre })).toBeInTheDocument()
    }
    expect(screen.getByRole('button', { name: 'Guardar gasto' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Cancelar' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: '+ Agregar observación' })).toBeInTheDocument()

    expect(screen.queryByText(/IVA/)).not.toBeInTheDocument()
    expect(screen.queryByText(/Vehículo/)).not.toBeInTheDocument()
    expect(screen.queryByText(/litros/i)).not.toBeInTheDocument()
  })

  it('Librería no ofrece vehículo ni litros', async () => {
    const { user } = renderModal()
    await elegirRubro(user, 'Librería')

    expect(screen.queryByLabelText(/Vehículo/)).not.toBeInTheDocument()
    expect(screen.queryByText(/litros/i)).not.toBeInTheDocument()
  })

  it('el rubro se busca por las palabras parecidas y sin tildes', async () => {
    const { user } = renderModal()
    await user.click(screen.getByLabelText(/^Rubro/))
    await user.type(screen.getByLabelText(/^Rubro/), 'NAFTA')

    expect(screen.getByRole('option', { name: /Combustible/ })).toBeInTheDocument()
    expect(screen.queryByRole('option', { name: /Seguro/ })).not.toBeInTheDocument()
  })
})

describe('ModalGasto — factura A', () => {
  it('calcula el IVA y el neto, y ofrece la letra M', async () => {
    const { user } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Factura A' }))
    poner(/Monto total/, '50000')

    expect(screen.getByLabelText('IVA')).toHaveValue('8677,69')
    expect(screen.getByText(/Neto\s+\$\s*41\.322,31/)).toBeInTheDocument()
    expect(screen.getByRole('group', { name: 'Letra A · M' })).toBeInTheDocument()
    for (const a of ['21%', '10,5%', '27%']) {
      expect(screen.getByRole('button', { name: a })).toBeInTheDocument()
    }
  })

  it('cambia la alícuota y recalcula', async () => {
    const { user } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Factura A' }))
    poner(/Monto total/, '1000')
    await user.click(screen.getByRole('button', { name: '10,5%' }))

    expect(screen.getByLabelText('IVA')).toHaveValue('95,02')
  })

  it('el IVA editado a mano no se pisa al cambiar el total', async () => {
    const { user } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Factura A' }))
    poner(/Monto total/, '50000')
    poner('IVA', '8000')
    poner(/Monto total/, '60000')

    expect(screen.getByLabelText('IVA')).toHaveValue('8000')
  })

  it('las percepciones y otros impuestos bajan el IVA sugerido', async () => {
    const { user } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Factura A' }))
    poner(/Monto total/, '50000')
    await user.click(screen.getByRole('button', { name: '+ percepciones e impuestos' }))
    poner('Percepción de IVA', '1000')
    poner('Otros impuestos', '2000')

    expect(screen.getByLabelText('IVA')).toHaveValue('8157,02')
    expect(screen.getByText(/Neto\s+\$\s*38\.842,98/)).toBeInTheDocument()
  })

  it('avisa que una factura a nombre de otra empresa se carga sin comprobante', async () => {
    const { user } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Factura A' }))

    expect(screen.getByText(/cargala como Sin comprobante/)).toBeInTheDocument()
  })

  it('Factura B ofrece el número de comprobante y no el IVA', async () => {
    const { user } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Factura B' }))

    expect(screen.queryByLabelText('IVA')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: '+ número de comprobante' })).toBeInTheDocument()
  })
})

describe('ModalGasto — rubros que cambian el formulario', () => {
  it('Combustible pide vehículo y ofrece litros y km', async () => {
    const { user } = renderModal()
    await elegirRubro(user, 'Combustible')

    expect(screen.getByLabelText(/Vehículo/)).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: '+ litros y km del tablero' }))
    expect(screen.getByLabelText('Litros')).toBeInTheDocument()
    expect(screen.getByLabelText('Km del tablero')).toBeInTheDocument()
  })

  it('Seguro abre el reparto en 12 meses', async () => {
    const { user } = renderModal()
    await elegirRubro(user, 'Seguro')
    await user.click(screen.getByRole('button', { name: 'Recibo' }))
    poner(/Monto total/, '1320000')
    poner(/^Fecha/, '2026-10-28')

    expect(screen.getByRole('checkbox', { name: 'Repartir en' })).toBeChecked()
    expect(screen.getByLabelText('Meses del reparto')).toHaveValue('12')
    expect(
      screen.getByText(/110\.000,00 por mes al resultado, de octubre 2026 a septiembre 2027/),
    ).toBeInTheDocument()
  })

  it('Ingresos brutos propone el mes anterior', async () => {
    const { user } = renderModal()
    poner(/^Fecha/, '2026-10-28')
    await elegirRubro(user, 'Ingresos brutos')

    expect(screen.getByText(/Va al resultado de/)).toHaveTextContent('Va al resultado de septiembre 2026')
    expect(screen.getByText('Este rubro corresponde al mes anterior al del pago.')).toBeInTheDocument()
  })

  it('el mes se cambia con las flechas', async () => {
    const { user } = renderModal()
    poner(/^Fecha/, '2026-10-28')
    await user.click(screen.getByRole('button', { name: 'cambiar' }))
    await user.click(screen.getByRole('button', { name: 'Mes siguiente' }))

    expect(screen.getByText(/Va al resultado de/)).toHaveTextContent('noviembre 2026')
  })
})

describe('ModalGasto — sucursal y compartido', () => {
  it('admin de una sola sucursal: casilla de compartido con la otra, y aviso amarillo', async () => {
    const { user } = renderModal()

    await user.click(screen.getByRole('checkbox', { name: 'Es compartido con Taco Pozo' }))

    const aviso = screen.getByRole('alert')
    expect(aviso).toHaveTextContent('Gasto compartido entre Tucumán y Taco Pozo')
    expect(aviso).toHaveTextContent('lo ven los admins de las dos')
  })

  it('compartido con factura A suma el aviso del crédito fiscal', async () => {
    const { user } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Factura A' }))
    await user.click(screen.getByRole('checkbox', { name: 'Es compartido con Taco Pozo' }))

    expect(screen.getByRole('alert')).toHaveTextContent(
      'El crédito fiscal queda en Tucumán: cargala desde la sucursal a cuyo nombre está la factura.',
    )
  })

  it('admin de las dos: botones Tucumán, Taco Pozo y Compartido', async () => {
    const { user } = renderModal({ sucursalesUsuario: [TUCUMAN, TACO_POZO] })

    const grupo = screen.getByRole('group', { name: 'Sucursal' })
    for (const n of ['Tucumán', 'Taco Pozo', 'Compartido']) {
      expect(within(grupo).getByRole('button', { name: n })).toBeInTheDocument()
    }
    await user.click(within(grupo).getByRole('button', { name: 'Compartido' }))
    expect(screen.getByRole('alert')).toHaveTextContent('Gasto compartido')
  })

  it('encargado: ni compartido ni crear rubro', async () => {
    const { user } = renderModal({ esAdmin: false })

    expect(screen.queryByText(/compartido/i)).not.toBeInTheDocument()
    expect(screen.getByText('Tucumán')).toBeInTheDocument()
    await user.click(screen.getByLabelText(/^Rubro/))
    await user.type(screen.getByLabelText(/^Rubro/), 'Gomería')
    expect(screen.queryByText(/Crear rubro/)).not.toBeInTheDocument()
  })
})

describe('ModalGasto — crear rubro', () => {
  it('el admin crea el rubro desde el buscador, elige el grupo y lo usa', async () => {
    const nuevo = rubro({ id: 99, nombre: 'Gomería', grupo: 'vehiculos' })
    const onCrearRubro = vi.fn(() => Promise.resolve(nuevo))
    const { user } = renderModal({ onCrearRubro })

    await user.click(screen.getByLabelText(/^Rubro/))
    await user.type(screen.getByLabelText(/^Rubro/), 'Gomería')
    await user.click(screen.getByRole('option', { name: '+ Crear rubro "Gomería"' }))
    await user.click(screen.getByRole('button', { name: 'Vehículos' }))
    await user.click(screen.getByRole('button', { name: 'Agregar y usar' }))

    expect(onCrearRubro).toHaveBeenCalledWith('Gomería', 'vehiculos')
    expect(await screen.findByDisplayValue('Gomería')).toBeInTheDocument()
    // Quedó elegido: el grupo Vehículos ofrece el vehículo.
    expect(screen.getByLabelText(/Vehículo/)).toBeInTheDocument()
  })
})

describe('ModalGasto — guardar', () => {
  it('manda el payload exacto de un combustible con factura A, vehículo, litros y km', async () => {
    const { user, onSave } = renderModal()
    poner(/^Fecha/, '2026-10-28')
    await elegirRubro(user, 'Combustible')
    await user.click(screen.getByRole('button', { name: 'Factura A' }))
    poner(/Monto total/, '50000')
    await user.click(screen.getByLabelText(/Vehículo/))
    await user.click(screen.getByRole('option', { name: /AC456EF/ }))
    await user.click(screen.getByRole('button', { name: '+ litros y km del tablero' }))
    poner('Litros', '38,5')
    poner('Km del tablero', '184230')

    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    const esperado: GuardarGastoPayload = {
      fecha: '2026-10-28',
      rubro_id: 1,
      monto_total: 50000,
      comprobante: 'factura_a',
      comprobante_numero: null,
      alicuota_iva: 21,
      iva: 8677.69,
      percepcion_iva: 0,
      percepcion_iibb: 0,
      otros_impuestos: 0,
      sucursal_id: 1,
      compartido: false,
      vehiculo_id: 7,
      litros: 38.5,
      km_tablero: 184230,
      mes_imputado: '2026-10-01',
      repartir_meses: 1,
      origen_pago: 'oficina',
      rendicion_transportista_id: null,
      rendicion_fecha: null,
      empleado_id: null,
      observacion: null,
    }
    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave).toHaveBeenCalledWith(esperado)
  })

  it('un ticket va sin desglose y la letra M viaja como factura_m', async () => {
    const { user, onSave } = renderModal()
    poner(/^Fecha/, '2026-10-28')
    await elegirRubro(user, 'Librería')
    poner(/Monto total/, '8500')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))
    expect(onSave.mock.calls[0][0]).toMatchObject({
      comprobante: 'ticket', alicuota_iva: null, iva: 0, vehiculo_id: null,
    })
    // GAS-1: un rubro que no pide litros ni km no manda esas claves.
    expect(onSave.mock.calls[0][0]).not.toHaveProperty('litros')
    expect(onSave.mock.calls[0][0]).not.toHaveProperty('km_tablero')

    await user.click(screen.getByRole('button', { name: 'Factura A' }))
    await user.click(within(screen.getByRole('group', { name: 'Letra A · M' })).getByRole('button', { name: 'M' }))
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))
    expect(onSave.mock.calls[1][0]).toMatchObject({ comprobante: 'factura_m', iva: 1475.21 })
  })

  it('sin rubro o con monto 0 no guarda y dice por qué', async () => {
    const { user, onSave } = renderModal()
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))
    expect(onSave).not.toHaveBeenCalled()
    expect(screen.getByText('Elegí un rubro')).toBeInTheDocument()

    await elegirRubro(user, 'Librería')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))
    expect(onSave).not.toHaveBeenCalled()
    expect(screen.getByText('El monto tiene que ser mayor a cero')).toBeInTheDocument()
  })

  it('una factura A con IVA igual al total no guarda', async () => {
    const { user, onSave } = renderModal()
    await elegirRubro(user, 'Librería')
    await user.click(screen.getByRole('button', { name: 'Factura A' }))
    poner(/Monto total/, '1000')
    poner('IVA', '1000')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave).not.toHaveBeenCalled()
    expect(screen.getByText('Con factura A o M el neto tiene que ser mayor a cero')).toBeInTheDocument()
  })

  it('el rechazo del server se muestra y el modal no se cierra', async () => {
    const onSave = vi.fn<OnSave>(() => Promise.reject(new Error('Sólo un admin puede cargar un gasto compartido')))
    const { user, onClose } = renderModal({ onSave })
    await elegirRubro(user, 'Librería')
    poner(/Monto total/, '8500')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(await screen.findByText('Sólo un admin puede cargar un gasto compartido')).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
  })

  it('al guardar bien se cierra', async () => {
    const { user, onClose } = renderModal()
    await elegirRubro(user, 'Librería')
    poner(/Monto total/, '8500')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    await screen.findByRole('button', { name: 'Guardar gasto' })
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})

describe('ModalGasto — edición', () => {
  it('trae los campos cargados, conserva el id y el mes y titula "Editar gasto"', async () => {
    const gasto = {
      id: 41, sucursal_id: 1, compartido: false, fecha: '2026-10-15', rubro_id: 3, monto_total: 8500,
      comprobante: 'ticket' as const, comprobante_numero: null, alicuota_iva: null, iva: 0, percepcion_iva: 0,
      percepcion_iibb: 0, otros_impuestos: 0, neto: 8500, costo: 8500, vehiculo_id: null, litros: null,
      mes_imputado: '2026-09-01', repartir_meses: 1, mes_fin: '2026-09-01', origen_pago: 'oficina' as const,
      observacion: 'Resmas', creado_por: 'u-1', rendicion_transportista_id: null, rendicion_fecha: null, empleado_id: null, anulado_at: null, created_at: '2026-10-15T10:00:00Z',
    }
    const { user, onSave } = renderModal({ gasto })

    expect(screen.getByText('Editar gasto')).toBeInTheDocument()
    expect(screen.getByLabelText(/Monto total/)).toHaveValue('8500,00')
    expect(screen.getByLabelText(/^Observación/)).toHaveValue('Resmas')
    expect(screen.getByText(/Va al resultado de/)).toHaveTextContent('septiembre 2026')

    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))
    expect(onSave.mock.calls[0][0]).toMatchObject({
      id: 41, rubro_id: 3, monto_total: 8500, mes_imputado: '2026-09-01', observacion: 'Resmas',
    })
  })
})

describe('ModalGasto — km del tablero al editar', () => {
  const combustible = {
    id: 41, sucursal_id: 1, compartido: false, fecha: '2026-10-15', rubro_id: 1, monto_total: 50000,
    comprobante: 'ticket' as const, comprobante_numero: null, alicuota_iva: null, iva: 0, percepcion_iva: 0,
    percepcion_iibb: 0, otros_impuestos: 0, neto: 50000, costo: 50000, vehiculo_id: 7, litros: 38.5,
    mes_imputado: '2026-10-01', repartir_meses: 1, mes_fin: '2026-10-01', origen_pago: 'oficina' as const,
    observacion: null, creado_por: 'u-1', rendicion_transportista_id: null, rendicion_fecha: null, empleado_id: null, anulado_at: null, created_at: '2026-10-15T10:00:00Z',
    rubro: { id: 1, nombre: 'Combustible', grupo: 'vehiculos' as const },
    vehiculo: { id: 7, patente: 'AC456EF', descripcion: 'Partner' },
  }

  it('precarga la lectura de km y la manda en el payload', async () => {
    kmDelGasto.data = 184230
    kmDelGasto.isLoading = false
    const { user, onSave } = renderModal({ gasto: combustible })

    expect(screen.getByLabelText('Km del tablero')).toHaveValue('184230')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ id: 41, litros: 38.5, km_tablero: 184230 })
  })

  it('vaciar el campo manda el payload sin km', async () => {
    kmDelGasto.data = 184230
    kmDelGasto.isLoading = false
    const { user, onSave } = renderModal({ gasto: combustible })
    await user.clear(screen.getByLabelText('Km del tablero'))
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ id: 41, km_tablero: null })
  })

  it('mientras la lectura carga no deja guardar', () => {
    kmDelGasto.data = null
    kmDelGasto.isLoading = true
    renderModal({ gasto: combustible })

    expect(screen.getByRole('button', { name: 'Guardar gasto' })).toBeDisabled()
    kmDelGasto.isLoading = false
  })

  it('un gasto sin lectura de km no inventa uno', async () => {
    kmDelGasto.data = null
    kmDelGasto.isLoading = false
    const { user, onSave } = renderModal({ gasto: combustible })
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ km_tablero: null })
  })
})

describe('ModalGasto — revisión del front', () => {
  const base = {
    id: 41, sucursal_id: 1, compartido: true, fecha: '2026-10-15', rubro_id: 3, monto_total: 8500,
    comprobante: 'ticket' as const, comprobante_numero: null, alicuota_iva: null, iva: 0, percepcion_iva: 0,
    percepcion_iibb: 0, otros_impuestos: 0, neto: 8500, costo: 8500, vehiculo_id: null, litros: null,
    mes_imputado: '2026-10-01', repartir_meses: 1, mes_fin: '2026-10-01', origen_pago: 'oficina' as const,
    observacion: null, creado_por: 'u-1', rendicion_transportista_id: null, rendicion_fecha: null, empleado_id: null, anulado_at: null, created_at: '2026-10-15T10:00:00Z',
    rubro: { id: 3, nombre: 'Librería', grupo: 'administracion' as const }, vehiculo: null,
  }
  const AMBAS = [TUCUMAN, TACO_POZO]

  it('1. editar un compartido de la sucursal 1 parado en la 2 manda sucursal_id 1, sin pastillas', async () => {
    const { user, onSave } = renderModal({
      gasto: base, sucursalActual: TACO_POZO, sucursalesUsuario: AMBAS,
    })

    expect(screen.queryByRole('group', { name: 'Sucursal' })).not.toBeInTheDocument()
    expect(screen.getByText('Tucumán')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ id: 41, sucursal_id: 1, compartido: true })
  })

  it('1. en el alta, la sucursal actual sigue valiendo para el compartido', async () => {
    const { user, onSave } = renderModal({ sucursalActual: TACO_POZO, sucursalesUsuario: AMBAS })
    poner(/Monto total/, '8500')
    await elegirRubro(user, 'Librería')
    await user.click(within(screen.getByRole('group', { name: 'Sucursal' })).getByRole('button', { name: 'Compartido' }))
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ sucursal_id: 2, compartido: true })
  })

  async function guardarCombustibleConKm(km: string) {
    const ctx = renderModal()
    await elegirRubro(ctx.user, 'Combustible')
    poner(/Monto total/, '50000')
    await ctx.user.click(screen.getByRole('button', { name: '+ litros y km del tablero' }))
    poner('Km del tablero', km)
    await ctx.user.click(screen.getByRole('button', { name: 'Guardar gasto' }))
    return ctx
  }

  it('2. 184.230 manda 184230', async () => {
    const { onSave } = await guardarCombustibleConKm('184.230')
    expect(onSave.mock.calls[0][0]).toMatchObject({ km_tablero: 184230 })
  })

  it('2. 150.000 manda 150000, no 150', async () => {
    const { onSave } = await guardarCombustibleConKm('150.000')
    expect(onSave.mock.calls[0][0]).toMatchObject({ km_tablero: 150000 })
  })

  it('2. los km con coma no se mandan', async () => {
    const { onSave } = await guardarCombustibleConKm('150000,5')
    expect(onSave).not.toHaveBeenCalled()
    expect(screen.getByText('Los km del tablero tienen que ser un número entero')).toBeInTheDocument()
  })

  it('3. si falla la lectura del km no deja guardar y avisa', () => {
    kmDelGasto.isError = true
    const comb = {
      ...base, rubro_id: 1, compartido: false, vehiculo_id: 7, litros: 38.5,
      rubro: { id: 1, nombre: 'Combustible', grupo: 'vehiculos' as const },
      vehiculo: { id: 7, patente: 'AC456EF', descripcion: 'Partner' },
    }
    const { onSave } = renderModal({ gasto: comb })

    expect(screen.getByText('No se pudo leer el km del tablero. Cerrá y volvé a abrir el gasto.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Guardar gasto' })).toBeDisabled()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('4. al elegir otra sucursal el vehículo se limpia y el buscador queda deshabilitado con el aviso', async () => {
    const { user, onSave } = renderModal({ sucursalesUsuario: AMBAS })
    await elegirRubro(user, 'Combustible')
    await user.click(screen.getByLabelText(/Vehículo/))
    await user.click(screen.getByRole('option', { name: /AC456EF/ }))
    expect(screen.getByLabelText(/Vehículo/)).toHaveValue('AC456EF · Partner')

    await user.click(within(screen.getByRole('group', { name: 'Sucursal' })).getByRole('button', { name: 'Taco Pozo' }))

    expect(screen.getByLabelText(/Vehículo/)).toBeDisabled()
    expect(screen.getByLabelText(/Vehículo/)).toHaveValue('')
    expect(screen.getByText(
      'Los vehículos son de Tucumán. Para cargar un gasto de un vehículo de Taco Pozo, cambiá de sucursal.',
    )).toBeInTheDocument()

    poner(/Monto total/, '50000')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))
    expect(onSave.mock.calls[0][0]).toMatchObject({ sucursal_id: 2, vehiculo_id: null })
  })

  it('4. editar un gasto de otra sucursal conserva su vehículo y no deja cambiarlo', async () => {
    const comb = {
      ...base, rubro_id: 1, compartido: false, sucursal_id: 2, vehiculo_id: 9,
      rubro: { id: 1, nombre: 'Combustible', grupo: 'vehiculos' as const },
      vehiculo: { id: 9, patente: 'ZZ999ZZ', descripcion: 'Camión' },
    }
    const { user, onSave } = renderModal({ gasto: comb, sucursalesUsuario: AMBAS })

    expect(screen.getByLabelText(/Vehículo/)).toBeDisabled()
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))
    expect(onSave.mock.calls[0][0]).toMatchObject({ sucursal_id: 2, vehiculo_id: 9 })
  })

  it('5. un vehículo dado de baja se sigue viendo elegido al editar', () => {
    const comb = {
      ...base, rubro_id: 1, compartido: false, vehiculo_id: 9,
      rubro: { id: 1, nombre: 'Combustible', grupo: 'vehiculos' as const },
      vehiculo: { id: 9, patente: 'ZZ999ZZ', descripcion: 'Camión viejo' },
    }
    renderModal({ gasto: comb })

    expect(screen.getByLabelText(/Vehículo/)).toHaveValue('ZZ999ZZ · Camión viejo')
  })

  it('6. el número de comprobante no viaja si el tipo elegido no tiene el campo', async () => {
    const { user, onSave } = renderModal()
    await elegirRubro(user, 'Librería')
    poner(/Monto total/, '8500')
    await user.click(screen.getByRole('button', { name: 'Factura B' }))
    await user.click(screen.getByRole('button', { name: '+ número de comprobante' }))
    fireEvent.change(screen.getByLabelText('Número de comprobante'), { target: { value: '0001-00001234' } })

    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))
    expect(onSave.mock.calls[0][0]).toMatchObject({ comprobante: 'factura_b', comprobante_numero: '0001-00001234' })

    // Se arrepiente y elige Ticket: el campo desaparece y el número que quedó escrito no viaja.
    await user.click(screen.getByRole('button', { name: 'Ticket' }))
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))
    expect(onSave.mock.calls[1][0]).toMatchObject({ comprobante: 'ticket', comprobante_numero: null })
  })
})

describe('ModalGasto — compartir al editar y vehículo oculto por RLS', () => {
  const ajeno = {
    id: 50, sucursal_id: 1, compartido: false, fecha: '2026-10-15', rubro_id: 3, monto_total: 8500,
    comprobante: 'ticket' as const, comprobante_numero: null, alicuota_iva: null, iva: 0, percepcion_iva: 0,
    percepcion_iibb: 0, otros_impuestos: 0, neto: 8500, costo: 8500, vehiculo_id: null, litros: null,
    mes_imputado: '2026-10-01', repartir_meses: 1, mes_fin: '2026-10-01', origen_pago: 'oficina' as const,
    observacion: null, creado_por: 'u-otro', rendicion_transportista_id: null, rendicion_fecha: null, empleado_id: null, anulado_at: null, created_at: '2026-10-15T10:00:00Z',
    rubro: { id: 3, nombre: 'Librería', grupo: 'administracion' as const }, vehiculo: null,
  }

  it('8. un gasto que cargó otro no se puede pasar a compartido', () => {
    renderModal({ gasto: ajeno, usuarioId: 'u-yo' })
    expect(screen.queryByRole('checkbox', { name: /compartido/i })).not.toBeInTheDocument()
  })

  it('8. sí si lo cargó el usuario', () => {
    renderModal({ gasto: { ...ajeno, creado_por: 'u-yo' }, usuarioId: 'u-yo' })
    expect(screen.getByRole('checkbox', { name: 'Es compartido con Taco Pozo' })).toBeInTheDocument()
  })

  it('8. ya compartido: se puede desmarcar aunque lo haya cargado otro', () => {
    renderModal({ gasto: { ...ajeno, compartido: true }, usuarioId: 'u-yo' })
    expect(screen.getByRole('checkbox', { name: 'Es compartido con Taco Pozo' })).toBeChecked()
  })

  it('8. con todas las sucursales se puede pasar a compartido un gasto ajeno', () => {
    renderModal({
      gasto: ajeno, usuarioId: 'u-yo', tieneTodasLasSucursales: true, sucursalesUsuario: [TUCUMAN, TACO_POZO],
    })
    expect(screen.getByRole('checkbox', { name: 'Es compartido con Taco Pozo' })).toBeInTheDocument()
  })

  it('9. si el embed del vehículo llega vacío por RLS, muestra el vehículo de la sucursal y conserva el id', async () => {
    const comb = {
      ...ajeno, rubro_id: 1, compartido: true, sucursal_id: 1, vehiculo_id: 9, vehiculo: null,
      rubro: { id: 1, nombre: 'Combustible', grupo: 'vehiculos' as const },
    }
    const { user, onSave } = renderModal({ gasto: comb, sucursalActual: TACO_POZO, sucursalesUsuario: [TUCUMAN, TACO_POZO] })

    expect(screen.getByLabelText(/Vehículo/)).toHaveValue('Vehículo de Tucumán')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))
    expect(onSave.mock.calls[0][0]).toMatchObject({ sucursal_id: 1, vehiculo_id: 9 })
  })
})

describe('ModalGasto — Escape', () => {
  it('con el buscador abierto cierra la lista y no el modal', async () => {
    const { user, onClose } = renderModal()
    await user.click(screen.getByLabelText(/^Rubro/))
    expect(screen.getByRole('listbox')).toBeInTheDocument()

    await user.keyboard('{Escape}')
    expect(onClose).not.toHaveBeenCalled()
    expect(screen.queryByRole('listbox')).not.toBeInTheDocument()

    // Sin lista abierta, Escape cierra como siempre.
    screen.getByLabelText(/Monto total/).focus()
    await user.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalledTimes(1)
  })
})

describe('modalGastoSchema', () => {
  const base = {
    fecha: '2026-10-28', rubro_id: 3, monto_total: 8500, comprobante: 'ticket', comprobante_numero: null,
    alicuota_iva: null, iva: 0, percepcion_iva: 0, percepcion_iibb: 0, otros_impuestos: 0, sucursal_id: 1,
    compartido: false, vehiculo_id: null, litros: null, km_tablero: null, mes_imputado: '2026-10-01',
    repartir_meses: 1, origen_pago: 'oficina', observacion: null,
  }
  const mensajes = (datos: unknown): string[] => {
    const r = modalGastoSchema.safeParse(datos)
    return r.success ? [] : r.error.issues.map(i => i.message)
  }

  it('acepta un gasto mínimo y ids que llegan como string', () => {
    expect(modalGastoSchema.safeParse(base).success).toBe(true)
    expect(modalGastoSchema.safeParse({ ...base, rubro_id: '3', sucursal_id: '1' }).success).toBe(true)
  })

  it('un monto de 0 da el mensaje de monto', () => {
    expect(mensajes({ ...base, monto_total: 0 })).toContain('El monto tiene que ser mayor a cero')
  })

  it('una factura A con neto no positivo da el mensaje del desglose', () => {
    expect(mensajes({ ...base, comprobante: 'factura_a', alicuota_iva: 21, iva: 8500 }))
      .toContain('Con factura A o M el neto tiene que ser mayor a cero')
  })

  it('el reparto va de 1 a 120 meses y el mes es el primero del mes', () => {
    expect(modalGastoSchema.safeParse({ ...base, repartir_meses: 121 }).success).toBe(false)
    expect(modalGastoSchema.safeParse({ ...base, repartir_meses: 0 }).success).toBe(false)
    expect(modalGastoSchema.safeParse({ ...base, mes_imputado: '2026-10-15' }).success).toBe(false)
  })

  it('una rendición pide transportista y día', () => {
    expect(mensajes({ ...base, origen_pago: 'rendicion' }))
      .toContain('Elegí de qué rendición salió la plata: el transportista y el día')
    expect(mensajes({ ...base, origen_pago: 'rendicion', rendicion_transportista_id: 'tr-1', rendicion_fecha: null }))
      .toContain('Elegí de qué rendición salió la plata: el transportista y el día')
    expect(modalGastoSchema.safeParse({
      ...base, origen_pago: 'rendicion', rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-28',
    }).success).toBe(true)
  })

  it('el pago de un empleado pide qué empleado', () => {
    expect(mensajes({ ...base, origen_pago: 'empleado' })).toContain('Elegí qué empleado pagó el gasto')
    expect(mensajes({ ...base, origen_pago: 'empleado', empleado_id: null })).toContain('Elegí qué empleado pagó el gasto')
    expect(modalGastoSchema.safeParse({ ...base, origen_pago: 'empleado', empleado_id: 4 }).success).toBe(true)
    expect(modalGastoSchema.safeParse({ ...base, origen_pago: 'empleado', empleado_id: '4' }).success).toBe(true)
  })
})

describe('ModalGasto — con qué plata se pagó', () => {
  const TRANSPORTISTAS = [
    { id: 'tr-1', nombre: 'Tito Transportista' },
    { id: 'tr-2', nombre: 'Martín Sosa' },
  ]
  const guardar = (user: ReturnType<typeof userEvent.setup>) =>
    user.click(screen.getByRole('button', { name: 'Guardar gasto' }))
  const cargarLibreria = async (user: ReturnType<typeof userEvent.setup>) => {
    await elegirRubro(user, 'Librería')
    poner(/Monto total/, '8500')
  }
  const delGasto = (extra: Record<string, unknown>) => ({
    id: 41, sucursal_id: 1, compartido: false, fecha: '2026-10-28', rubro_id: 3, monto_total: 8500,
    comprobante: 'ticket' as const, comprobante_numero: null, alicuota_iva: null, iva: 0, percepcion_iva: 0,
    percepcion_iibb: 0, otros_impuestos: 0, neto: 8500, costo: 8500, vehiculo_id: null, litros: null,
    mes_imputado: '2026-10-01', repartir_meses: 1, mes_fin: '2026-10-01', origen_pago: 'rendicion' as const,
    rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-27', empleado_id: null,
    observacion: null, creado_por: 'u-1', anulado_at: null, created_at: '2026-10-28T10:00:00Z',
    ...extra,
  })

  it('la plata arranca en la oficina', async () => {
    const { user, onSave } = renderModal({ transportistas: TRANSPORTISTAS })
    expect(screen.getByText(/Con qué plata se pagó/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'La oficina' })).toHaveAttribute('aria-pressed', 'true')
    await cargarLibreria(user)
    await guardar(user)

    expect(onSave.mock.calls[0][0]).toMatchObject({
      origen_pago: 'oficina', rendicion_transportista_id: null, rendicion_fecha: null,
    })
  })

  it('una rendición pide transportista y día', async () => {
    const { user, onSave } = renderModal({ transportistas: TRANSPORTISTAS })
    await cargarLibreria(user)
    poner(/^Fecha/, '2026-10-28')
    await user.click(screen.getByRole('button', { name: 'Una rendición' }))
    await guardar(user)

    expect(onSave).not.toHaveBeenCalled()
    expect(screen.getByText('Elegí de qué rendición salió la plata: el transportista y el día')).toBeInTheDocument()

    await user.click(screen.getByPlaceholderText('Transportista'))
    await user.click(screen.getByRole('option', { name: 'Tito Transportista' }))
    await guardar(user)

    expect(onSave.mock.calls[0][0]).toMatchObject({
      origen_pago: 'rendicion', rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-28',
    })
  })

  it('el día sigue a la fecha hasta que se lo cambia a mano', async () => {
    const { user } = renderModal({ transportistas: TRANSPORTISTAS })
    poner(/^Fecha/, '2026-10-28')
    await user.click(screen.getByRole('button', { name: 'Una rendición' }))
    expect(screen.getByLabelText('Día de la rendición')).toHaveValue('2026-10-28')

    poner(/^Fecha/, '2026-10-27')
    expect(screen.getByLabelText('Día de la rendición')).toHaveValue('2026-10-27')

    poner('Día de la rendición', '2026-10-20')
    poner(/^Fecha/, '2026-10-25')
    expect(screen.getByLabelText('Día de la rendición')).toHaveValue('2026-10-20')
  })

  it('sin transportistas no hay bloque de plata', () => {
    renderModal()
    expect(screen.queryByText(/Con qué plata se pagó/)).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Una rendición' })).not.toBeInTheDocument()
  })

  it('editar un gasto de rendición desde Gastos arranca en "Una rendición" con su transportista', async () => {
    const { user, onSave } = renderModal({ gasto: delGasto({}), transportistas: TRANSPORTISTAS })

    expect(screen.getByRole('button', { name: 'Una rendición' })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByPlaceholderText('Transportista')).toHaveValue('Tito Transportista')
    expect(screen.getByLabelText('Día de la rendición')).toHaveValue('2026-10-27')
    await guardar(user)
    expect(onSave.mock.calls[0][0]).toMatchObject({
      id: 41, origen_pago: 'rendicion', rendicion_transportista_id: 'tr-1', rendicion_fecha: '2026-10-27',
    })
  })

  it('un transportista que no está en la lista se muestra como "Otro usuario"', () => {
    renderModal({ gasto: delGasto({ rendicion_transportista_id: 'tr-baja' }), transportistas: TRANSPORTISTAS })
    expect(screen.getByPlaceholderText('Transportista')).toHaveValue('Otro usuario')
  })
})

describe('ModalGasto — abierto desde el cierre de una rendición', () => {
  const CIERRE = { transportistaId: 'tr-2', transportistaNombre: 'Martín Sosa', fecha: '2026-10-28' }
  const TRANSPORTISTAS = [{ id: 'tr-2', nombre: 'Martín Sosa' }]

  it('la plata es fija: sin el bloque, con la línea de la rendición y el botón de agregar', async () => {
    const { user, onSave } = renderModal({ desdeCierre: CIERRE, transportistas: TRANSPORTISTAS })

    expect(screen.queryByText(/Con qué plata se pagó/)).not.toBeInTheDocument()
    const linea = screen.getByText((_, el) =>
      el?.tagName === 'P' && Boolean(el.textContent?.includes('Con la plata de la rendición de Martín Sosa del 28/10')))
    expect(linea).toHaveTextContent('Se descuenta del efectivo que entrega.')
    expect(screen.getByText('Se guarda cuando confirmes el cierre.')).toBeInTheDocument()
    expect(screen.getByLabelText(/^Fecha/)).toHaveValue('2026-10-28')

    await elegirRubro(user, 'Librería')
    poner(/Monto total/, '8500')
    await user.click(screen.getByRole('button', { name: 'Agregar a la rendición' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({
      fecha: '2026-10-28', origen_pago: 'rendicion', rendicion_transportista_id: 'tr-2', rendicion_fecha: '2026-10-28',
    })
  })

  it('con borrador: precarga el monto, el rubro y los km sin pedir la lectura al server', async () => {
    const borrador: GuardarGastoPayload = {
      id: 7, fecha: '2026-10-28', rubro_id: 1, monto_total: 50000, comprobante: 'ticket', sucursal_id: 1,
      compartido: false, vehiculo_id: 7, litros: 38.5, km_tablero: 184230, mes_imputado: '2026-10-01',
      repartir_meses: 1, origen_pago: 'rendicion', rendicion_transportista_id: 'tr-2', rendicion_fecha: '2026-10-28',
      observacion: null,
    }
    const gasto = {
      id: 7, sucursal_id: 1, compartido: false, fecha: '2026-10-28', rubro_id: 1, monto_total: 50000,
      comprobante: 'ticket' as const, comprobante_numero: null, alicuota_iva: null, iva: 0, percepcion_iva: 0,
      percepcion_iibb: 0, otros_impuestos: 0, neto: 50000, costo: 50000, vehiculo_id: 7, litros: 38.5,
      mes_imputado: '2026-10-01', repartir_meses: 1, mes_fin: '2026-10-01', origen_pago: 'rendicion' as const,
      rendicion_transportista_id: 'tr-2', rendicion_fecha: '2026-10-28', empleado_id: null, observacion: null, creado_por: 'u-1',
      anulado_at: null, created_at: '2026-10-28T10:00:00Z',
    }
    const { user, onSave } = renderModal({ desdeCierre: CIERRE, gasto, borrador: { ...borrador, monto_total: 52000 } })

    expect(screen.getByLabelText(/Monto total/)).toHaveValue('52000,00')
    expect(screen.getByLabelText(/^Rubro/)).toHaveValue('Combustible')
    expect(screen.getByLabelText('Km del tablero')).toHaveValue('184230')
    // El hook se llama siempre, pero con null: queda deshabilitado y no va a `vehiculo_km`.
    expect(kmPedidos.every(id => id === null)).toBe(true)
    expect(screen.getByText('Editar gasto')).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Aplicar cambios' }))
    expect(onSave.mock.calls[0][0]).toMatchObject({ id: 7, km_tablero: 184230, monto_total: 52000 })
  })
})

describe('ModalGasto — un empleado pagó con su plata', () => {
  const TRANSPORTISTAS = [{ id: 'tr-1', nombre: 'Tito Transportista' }]
  const EMPLEADOS: EmpleadoParaElegir[] = [
    { id: 4, nombre: 'Martín Sosa', usuario_id: 'u-mar', vehiculo_id: null, activo: true },
    { id: 5, nombre: 'Laura Paz', usuario_id: 'u-1', vehiculo_id: null, activo: true },
    { id: 6, nombre: 'Pablo Baja', usuario_id: null, vehiculo_id: null, activo: false },
  ]
  const guardar = (user: ReturnType<typeof userEvent.setup>) =>
    user.click(screen.getByRole('button', { name: 'Guardar gasto' }))
  const cargarLibreria = async (user: ReturnType<typeof userEvent.setup>) => {
    await elegirRubro(user, 'Librería')
    poner(/Monto total/, '8500')
  }
  const delGasto = (extra: Record<string, unknown>) => ({
    id: 41, sucursal_id: 1, compartido: false, fecha: '2026-10-28', rubro_id: 3, monto_total: 8500,
    comprobante: 'ticket' as const, comprobante_numero: null, alicuota_iva: null, iva: 0, percepcion_iva: 0,
    percepcion_iibb: 0, otros_impuestos: 0, neto: 8500, costo: 8500, vehiculo_id: null, litros: null,
    mes_imputado: '2026-10-01', repartir_meses: 1, mes_fin: '2026-10-01', origen_pago: 'empleado' as const,
    rendicion_transportista_id: null, rendicion_fecha: null, empleado_id: 4,
    observacion: null, creado_por: 'u-1', anulado_at: null, created_at: '2026-10-28T10:00:00Z',
    ...extra,
  })

  it('Un empleado pide el empleado, y con Martín el payload lleva su id', async () => {
    const { user, onSave } = renderModal({ transportistas: TRANSPORTISTAS, empleados: EMPLEADOS, usuarioId: 'u-1' })
    await cargarLibreria(user)
    await user.click(screen.getByRole('button', { name: 'Un empleado' }))
    await guardar(user)

    expect(onSave).not.toHaveBeenCalled()
    expect(screen.getByText('Elegí qué empleado pagó el gasto')).toBeInTheDocument()
    expect(screen.getByText('Queda a su favor en su cuenta y se le devuelve con el sueldo.')).toBeInTheDocument()

    await user.click(screen.getByPlaceholderText('Empleado'))
    await user.click(screen.getByRole('option', { name: 'Martín Sosa' }))
    await guardar(user)

    expect(onSave).toHaveBeenCalledTimes(1)
    expect(onSave.mock.calls[0][0]).toMatchObject({
      origen_pago: 'empleado', empleado_id: 4, rendicion_transportista_id: null, rendicion_fecha: null,
    })
  })

  it('la grilla de la plata pasa a tres columnas y no ofrece transportista ni día', async () => {
    const { user } = renderModal({ transportistas: TRANSPORTISTAS, empleados: EMPLEADOS })
    const grupo = screen.getByRole('group', { name: /Con qué plata se pagó/ })
    expect(grupo.className).toContain('grid-cols-3')
    await user.click(screen.getByRole('button', { name: 'Un empleado' }))

    expect(screen.queryByPlaceholderText('Transportista')).not.toBeInTheDocument()
    expect(screen.queryByLabelText('Día de la rendición')).not.toBeInTheDocument()
  })

  it('no se ofrece el empleado propio ni los dados de baja', async () => {
    const { user } = renderModal({ transportistas: TRANSPORTISTAS, empleados: EMPLEADOS, usuarioId: 'u-1' })
    await user.click(screen.getByRole('button', { name: 'Un empleado' }))
    await user.click(screen.getByPlaceholderText('Empleado'))

    expect(screen.getByRole('option', { name: 'Martín Sosa' })).toBeInTheDocument()
    expect(screen.queryByRole('option', { name: 'Laura Paz' })).not.toBeInTheDocument()
    expect(screen.queryByRole('option', { name: 'Pablo Baja' })).not.toBeInTheDocument()
  })

  it('al editar, el empleado actual se ve aunque esté de baja, y se conserva', async () => {
    const { user, onSave } = renderModal({
      gasto: delGasto({ empleado_id: 6 }), transportistas: TRANSPORTISTAS, empleados: EMPLEADOS, usuarioId: 'u-1',
    })

    expect(screen.getByRole('button', { name: 'Un empleado' })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByPlaceholderText('Empleado')).toHaveValue('Pablo Baja')
    await guardar(user)
    expect(onSave.mock.calls[0][0]).toMatchObject({ id: 41, origen_pago: 'empleado', empleado_id: 6 })
  })

  it('un empleado que no está en la lista se muestra como "Otro empleado"', () => {
    renderModal({ gasto: delGasto({ empleado_id: 99 }), transportistas: TRANSPORTISTAS, empleados: EMPLEADOS })
    expect(screen.getByPlaceholderText('Empleado')).toHaveValue('Otro empleado')
  })

  it('volver a la oficina manda empleado_id null', async () => {
    const { user, onSave } = renderModal({
      gasto: delGasto({}), transportistas: TRANSPORTISTAS, empleados: EMPLEADOS,
    })
    await user.click(screen.getByRole('button', { name: 'La oficina' }))
    await guardar(user)

    expect(onSave.mock.calls[0][0]).toMatchObject({
      origen_pago: 'oficina', empleado_id: null, rendicion_transportista_id: null, rendicion_fecha: null,
    })
  })

  it('sin `empleados` no está "Un empleado"', () => {
    renderModal({ transportistas: TRANSPORTISTAS })
    expect(screen.queryByRole('button', { name: 'Un empleado' })).not.toBeInTheDocument()
  })

  it('desde el cierre tampoco está, aunque lleguen los empleados', () => {
    renderModal({
      desdeCierre: { transportistaId: 'tr-1', transportistaNombre: 'Tito Transportista', fecha: '2026-10-28' },
      transportistas: TRANSPORTISTAS,
      empleados: EMPLEADOS,
    })
    expect(screen.queryByRole('button', { name: 'Un empleado' })).not.toBeInTheDocument()
  })
})

describe('ModalGasto — GAS-1: litros y km al editar', () => {
  const delGasto = (extra: Record<string, unknown>) => ({
    id: 41, sucursal_id: 1, compartido: false, fecha: '2026-10-15', rubro_id: 1, monto_total: 50000,
    comprobante: 'ticket' as const, comprobante_numero: null, alicuota_iva: null, iva: 0, percepcion_iva: 0,
    percepcion_iibb: 0, otros_impuestos: 0, neto: 50000, costo: 50000, vehiculo_id: 7, litros: 38.5,
    mes_imputado: '2026-10-01', repartir_meses: 1, mes_fin: '2026-10-01', origen_pago: 'oficina' as const,
    rendicion_transportista_id: null, rendicion_fecha: null, empleado_id: null,
    observacion: null, creado_por: 'u-1', anulado_at: null, created_at: '2026-10-15T10:00:00Z',
    rubro: { id: 1, nombre: 'Combustible', grupo: 'vehiculos' as const, pide_litros_km: true },
    vehiculo: { id: 7, patente: 'AC456EF', descripcion: 'Partner' },
    ...extra,
  })
  // El rubro dado de baja no viene en la lista de activos: sólo en el embed del gasto.
  const SIN_COMBUSTIBLE = RUBROS.filter(r => r.id !== 1)

  it('editar una carga de un rubro dado de baja que pide litros manda sus litros y su km_tablero', async () => {
    kmDelGasto.data = 184230
    const { user, onSave } = renderModal({ gasto: delGasto({}), rubros: SIN_COMBUSTIBLE })

    expect(screen.getByLabelText('Litros')).toHaveValue('38,50')
    expect(screen.getByLabelText('Km del tablero')).toHaveValue('184230')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ id: 41, litros: 38.5, km_tablero: 184230 })
  })

  // "Editar cierre": el gasto viene de `obtener_gastos_rendiciones`, cuyo rubro no trae el flag.
  const SIN_FLAG = { id: 1, nombre: 'Combustible', grupo: 'vehiculos' as const }

  it('un rubro que no dice si pide litros manda los litros y el km guardados: nada se borra', async () => {
    kmDelGasto.data = 184230
    const { user, onSave } = renderModal({ gasto: delGasto({ rubro: SIN_FLAG }), rubros: SIN_COMBUSTIBLE })

    // Lo guardado sigue a la vista, no se esconde por no saber.
    expect(screen.getByLabelText('Litros')).toHaveValue('38,50')
    expect(screen.getByLabelText('Km del tablero')).toHaveValue('184230')
    poner(/Monto total/, '60000')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    // `_guardar_gasto` lee la clave ausente como NULL y borra la lectura: viajan los valores actuales.
    expect(onSave.mock.calls[0][0]).toMatchObject({ id: 41, rubro_id: 1, monto_total: 60000, litros: 38.5, km_tablero: 184230 })
  })

  it('"Editar cierre": el borrador que trae litros y km los conserva al editar sólo el monto', async () => {
    const original = delGasto({ rubro: SIN_FLAG, origen_pago: 'rendicion' as const, rendicion_transportista_id: 't-1', rendicion_fecha: '2026-10-15' })
    const borrador = payloadDeGasto({ ...original, km_tablero: 184230 })
    const { user, onSave } = renderModal({
      gasto: original, borrador, rubros: SIN_COMBUSTIBLE,
      desdeCierre: { transportistaId: 't-1', transportistaNombre: 'Luis', fecha: '2026-10-15' },
    })

    expect(screen.getByLabelText('Litros')).toHaveValue('38,50')
    expect(screen.getByLabelText('Km del tablero')).toHaveValue('184230')
    poner(/Monto total/, '70000')
    await user.click(screen.getByRole('button', { name: 'Aplicar cambios' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ id: 41, monto_total: 70000, litros: 38.5, km_tablero: 184230 })
  })

  it('un rubro sin flag cuyo gasto tiene litros pero no es de vehículos también los conserva', async () => {
    kmDelGasto.data = null
    const raro = delGasto({
      rubro_id: 3, vehiculo_id: null, vehiculo: null, litros: 20,
      rubro: { id: 3, nombre: 'Librería', grupo: 'administracion' as const },
    })
    const { user, onSave } = renderModal({ gasto: raro, rubros: RUBROS.filter(r => r.id !== 3) })
    poner(/Monto total/, '60000')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ id: 41, litros: 20, km_tablero: null })
  })

  it('un rubro sin flag y un gasto sin litros ni km (nada que borrar) no manda esas claves', async () => {
    kmDelGasto.data = null
    const { user, onSave } = renderModal({ gasto: delGasto({ rubro: SIN_FLAG, litros: null }), rubros: SIN_COMBUSTIBLE })
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    const payload = onSave.mock.calls[0][0]
    expect(payload).not.toHaveProperty('litros')
    expect(payload).not.toHaveProperty('km_tablero')
  })

  it('un rubro sin flag sí manda los litros si el usuario los corrige', async () => {
    kmDelGasto.data = 184230
    const { user, onSave } = renderModal({ gasto: delGasto({ rubro: SIN_FLAG }), rubros: SIN_COMBUSTIBLE })
    await user.clear(screen.getByLabelText('Litros'))
    await user.type(screen.getByLabelText('Litros'), '40')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ id: 41, litros: 40, km_tablero: 184230 })
  })

  it('un rubro que no los pide no manda esas claves', async () => {
    const libreria = delGasto({
      rubro_id: 3, vehiculo_id: null, vehiculo: null, litros: null,
      rubro: { id: 3, nombre: 'Librería', grupo: 'administracion' as const, pide_litros_km: false },
    })
    const { user, onSave } = renderModal({ gasto: libreria, rubros: RUBROS.filter(r => r.id !== 3) })
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    const payload = onSave.mock.calls[0][0]
    expect(payload).toMatchObject({ id: 41, rubro_id: 3 })
    expect(payload).not.toHaveProperty('litros')
    expect(payload).not.toHaveProperty('km_tablero')
  })

  it('cambiar de Combustible a un rubro que no los pide borra litros y km de forma explícita', async () => {
    kmDelGasto.data = 10000
    const { user, onSave } = renderModal({ gasto: delGasto({ litros: 40 }) })
    await elegirRubro(user, 'Librería')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ id: 41, rubro_id: 3, litros: null, km_tablero: null })
  })

  it('cambiar de rubro con litros pero sin lectura de km también borra los dos', async () => {
    kmDelGasto.data = null
    const { user, onSave } = renderModal({ gasto: delGasto({ litros: 40 }) })
    await elegirRubro(user, 'Librería')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ litros: null, km_tablero: null })
  })

  it('una edición que nunca tuvo litros ni km no manda esas claves aunque cambie de rubro', async () => {
    kmDelGasto.data = null
    const { user, onSave } = renderModal({ gasto: delGasto({ litros: null, vehiculo_id: null, vehiculo: null }) })
    await elegirRubro(user, 'Librería')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    const payload = onSave.mock.calls[0][0]
    expect(payload).not.toHaveProperty('litros')
    expect(payload).not.toHaveProperty('km_tablero')
  })

  it('un alta de un rubro que no los pide no manda esas claves', async () => {
    const { user, onSave } = renderModal()
    await elegirRubro(user, 'Librería')
    poner(/Monto total/, '8500')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    const payload = onSave.mock.calls[0][0]
    expect(payload).not.toHaveProperty('litros')
    expect(payload).not.toHaveProperty('km_tablero')
  })

  it('vaciar los litros y el km de un rubro que los pide manda null explícito', async () => {
    kmDelGasto.data = 184230
    const { user, onSave } = renderModal({ gasto: delGasto({}), rubros: SIN_COMBUSTIBLE })
    await user.clear(screen.getByLabelText('Litros'))
    await user.clear(screen.getByLabelText('Km del tablero'))
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ litros: null, km_tablero: null })
  })

  it('con `rubrosCargando` no deja guardar', () => {
    renderModal({ rubrosCargando: true })
    expect(screen.getByRole('button', { name: 'Guardar gasto' })).toBeDisabled()
  })

  it('sin `rubrosCargando` el botón está habilitado', () => {
    renderModal({ rubrosCargando: false })
    expect(screen.getByRole('button', { name: 'Guardar gasto' })).toBeEnabled()
  })
})

describe('ModalGasto — el vehículo habitual precargado', () => {
  const PARTNER = { id: 3, sucursal_id: 1, patente: 'AC456EF', descripcion: 'Partner', activo: true }

  it('con `vehiculoInicialId` y un rubro de Vehículos, el payload lleva vehiculo_id 3', async () => {
    const { user, onSave } = renderModal({ vehiculos: [PARTNER], vehiculoInicialId: 3 })
    poner(/^Fecha/, '2026-10-28')
    await elegirRubro(user, 'Seguro')
    poner(/Monto total/, '50000')

    expect(screen.getByLabelText(/Vehículo/)).toHaveValue('AC456EF · Partner')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ vehiculo_id: 3 })
  })

  it('con Librería, no lleva el vehículo', async () => {
    const { user, onSave } = renderModal({ vehiculos: [PARTNER], vehiculoInicialId: 3 })
    poner(/^Fecha/, '2026-10-28')
    await elegirRubro(user, 'Librería')
    poner(/Monto total/, '8500')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(screen.queryByLabelText(/Vehículo/)).not.toBeInTheDocument()
    expect(onSave.mock.calls[0][0]).toMatchObject({ vehiculo_id: null })
  })

  it('si el vehículo habitual no está en la lista, arranca sin vehículo', async () => {
    const { user, onSave } = renderModal({ vehiculoInicialId: 99 })
    poner(/^Fecha/, '2026-10-28')
    await elegirRubro(user, 'Seguro')
    poner(/Monto total/, '50000')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ vehiculo_id: null })
  })

  it('el borrador manda sobre el vehículo habitual', async () => {
    const borrador: GuardarGastoPayload = {
      id: 7, fecha: '2026-10-28', rubro_id: 2, monto_total: 50000, comprobante: 'ticket', sucursal_id: 1,
      compartido: false, vehiculo_id: 8, mes_imputado: '2026-10-01', repartir_meses: 1,
      origen_pago: 'oficina', observacion: null,
    }
    const { user, onSave } = renderModal({ vehiculoInicialId: 7, borrador })
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ vehiculo_id: 8 })
  })
})

describe('ModalGasto — importes tipeados con puntos de miles', () => {
  const MENSAJE = 'Escribí el monto con números, por ejemplo 280.000 o 280.000,50'

  it('280.000 en el monto es doscientos ochenta mil, no 280', async () => {
    const { user, onSave } = renderModal()
    await elegirRubro(user, 'Librería')
    poner(/Monto total/, '280.000')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ monto_total: 280000 })
  })

  it('280.000,50 en el monto es 280000,50', async () => {
    const { user, onSave } = renderModal()
    await elegirRubro(user, 'Librería')
    poner(/Monto total/, '280.000,50')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave.mock.calls[0][0]).toMatchObject({ monto_total: 280000.5 })
  })

  it('un monto que no se entiende no se guarda y dice cómo escribirlo', async () => {
    const { user, onSave } = renderModal()
    await elegirRubro(user, 'Librería')
    poner(/Monto total/, '280,000')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText(MENSAJE)).toBeInTheDocument()
  })

  it('una percepción que no se entiende no se guarda', async () => {
    const { user, onSave } = renderModal()
    await elegirRubro(user, 'Librería')
    await user.click(screen.getByRole('button', { name: 'Factura A' }))
    poner(/Monto total/, '50000')
    await user.click(screen.getByRole('button', { name: '+ percepciones e impuestos' }))
    poner('Percepción de IVA', '1,5.0')
    await user.click(screen.getByRole('button', { name: 'Guardar gasto' }))

    expect(onSave).not.toHaveBeenCalled()
    expect(await screen.findByText(MENSAJE)).toBeInTheDocument()
  })
})
