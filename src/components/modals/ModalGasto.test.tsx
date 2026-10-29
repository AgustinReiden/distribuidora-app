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
const kmDelGasto = vi.hoisted(() => ({ data: null as number | null, isLoading: false }))
vi.mock('../../hooks/queries/useGastosQuery', () => ({
  useKmDelGastoQuery: () => kmDelGasto,
}))

beforeEach(() => {
  kmDelGasto.data = null
  kmDelGasto.isLoading = false
})

import ModalGasto, { modalGastoSchema, type ModalGastoProps } from './ModalGasto'
import type { GuardarGastoPayload, RubroGasto, Vehiculo } from '../../types/gastos'

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
      comprobante: 'ticket', alicuota_iva: null, iva: 0, vehiculo_id: null, litros: null, km_tablero: null,
    })

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
      observacion: 'Resmas', creado_por: 'u-1', anulado_at: null, created_at: '2026-10-15T10:00:00Z',
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
    observacion: null, creado_por: 'u-1', anulado_at: null, created_at: '2026-10-15T10:00:00Z',
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

  it('en esta entrega el origen del pago es sólo la oficina', () => {
    expect(modalGastoSchema.safeParse({ ...base, origen_pago: 'rendicion' }).success).toBe(false)
  })
})
