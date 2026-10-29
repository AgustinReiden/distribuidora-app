import { describe, it, expect, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalFichaVehiculo, { lecturaKmSchema } from './ModalFichaVehiculo'
import type { Gasto, Vehiculo } from '../../types/gastos'
import type { LecturaKm } from '../../utils/vehiculos'

const VEHICULO: Vehiculo = { id: 7, sucursal_id: 1, patente: 'AC456EF', descripcion: 'Partner', activo: true }
const MES = '2026-10-01'

const carga = (id: number, fecha: string, litros: number, costo: number): Gasto => ({
  id, sucursal_id: 1, compartido: false, fecha, rubro_id: 1, monto_total: costo, comprobante: 'ticket',
  comprobante_numero: null, alicuota_iva: null, iva: 0, percepcion_iva: 0, percepcion_iibb: 0,
  otros_impuestos: 0, neto: costo, costo, vehiculo_id: 7, litros, mes_imputado: '2026-10-01',
  repartir_meses: 1, mes_fin: '2026-10-01', origen_pago: 'oficina', observacion: null, creado_por: 'u',
  rendicion_transportista_id: null, rendicion_fecha: null, anulado_at: null, created_at: fecha, rubro: { id: 1, nombre: 'Combustible', grupo: 'vehiculos' },
})

const GASTOS = [carga(1, '2026-10-01', 38.5, 40000), carga(2, '2026-10-10', 40, 42000), carga(3, '2026-10-20', 42, 44000)]
const LECTURAS: LecturaKm[] = [
  { fecha: '2026-10-01', km: 184230, origen: 'carga', gasto_id: 1 },
  { fecha: '2026-10-10', km: 184630, origen: 'carga', gasto_id: 2 },
  { fecha: '2026-10-20', km: 185030, origen: 'carga', gasto_id: 3 },
]

function renderFicha(props: { gastos?: Gasto[]; lecturas?: LecturaKm[]; onRegistrarKm?: (f: string, k: number) => Promise<void> } = {}) {
  const onRegistrarKm = props.onRegistrarKm ?? vi.fn(() => Promise.resolve())
  const onClose = vi.fn()
  render(
    <ModalFichaVehiculo
      vehiculo={VEHICULO}
      gastos={props.gastos ?? GASTOS}
      lecturas={props.lecturas ?? LECTURAS}
      loading={false}
      mes={MES}
      onRegistrarKm={onRegistrarKm}
      onClose={onClose}
    />,
  )
  return { onRegistrarKm, onClose, user: userEvent.setup() }
}

describe('ModalFichaVehiculo', () => {
  it('con cargas y lecturas muestra el rendimiento y el costo por km', () => {
    renderFicha()
    expect(screen.getByText('9,8 km/l')).toBeInTheDocument()
    expect(screen.getByText('Costo por km')).toBeInTheDocument()
    expect(screen.getByText(/Gasto de octubre 2026/)).toBeInTheDocument()
  })

  it('sin cargas no muestra km por litro ni costo por km', () => {
    renderFicha({ gastos: [], lecturas: [] })
    expect(screen.queryByText(/km\/l/)).not.toBeInTheDocument()
    expect(screen.queryByText('Costo por km')).not.toBeInTheDocument()
    expect(screen.getByText('Todavía no hay cargas con litros.')).toBeInTheDocument()
    expect(screen.getByText('Todavía no hay lecturas de km.')).toBeInTheDocument()
  })

  it('lista las cargas con fecha, litros, km y monto', () => {
    renderFicha()
    const cargas = screen.getByRole('region', { name: 'Cargas de combustible' })
    expect(cargas).toHaveTextContent('10/10/2026')
    expect(cargas).toHaveTextContent('184.630')
    expect(cargas).toHaveTextContent(/42\.000,00/)
  })

  it('+ Registrar km manda la fecha y los km como número entero', async () => {
    const { user, onRegistrarKm } = renderFicha()
    await user.click(screen.getByRole('button', { name: '+ Registrar km' }))
    fireEvent.change(screen.getByLabelText('Fecha'), { target: { value: '2026-10-28' } })
    await user.type(screen.getByLabelText('Km del tablero'), '185.400')
    await user.click(screen.getByRole('button', { name: 'Guardar lectura' }))

    expect(onRegistrarKm).toHaveBeenCalledTimes(1)
    const [fecha, km] = (onRegistrarKm as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(fecha).toBe('2026-10-28')
    expect(km).toBe(185400)
    expect(Number.isInteger(km)).toBe(true)
  })

  it('km vacíos o con decimales no se mandan', async () => {
    const { user, onRegistrarKm } = renderFicha()
    await user.click(screen.getByRole('button', { name: '+ Registrar km' }))
    await user.click(screen.getByRole('button', { name: 'Guardar lectura' }))
    expect(onRegistrarKm).not.toHaveBeenCalled()

    await user.type(screen.getByLabelText('Km del tablero'), '185400,5')
    await user.click(screen.getByRole('button', { name: 'Guardar lectura' }))
    expect(onRegistrarKm).not.toHaveBeenCalled()
    expect(screen.getByText('Los km del tablero tienen que ser un número entero')).toBeInTheDocument()
  })

  it('el rechazo del server se muestra', async () => {
    const { user } = renderFicha({ onRegistrarKm: vi.fn(() => Promise.reject(new Error('Sólo un admin puede registrar km'))) })
    await user.click(screen.getByRole('button', { name: '+ Registrar km' }))
    await user.type(screen.getByLabelText('Km del tablero'), '185400')
    await user.click(screen.getByRole('button', { name: 'Guardar lectura' }))

    expect(await screen.findByText('Sólo un admin puede registrar km')).toBeInTheDocument()
  })
})

describe('lecturaKmSchema', () => {
  it('acepta de 0 a 9.999.999 enteros', () => {
    expect(lecturaKmSchema.safeParse({ fecha: '2026-10-28', km: '184230' }).success).toBe(true)
    expect(lecturaKmSchema.safeParse({ fecha: '2026-10-28', km: 10000000 }).success).toBe(false)
    expect(lecturaKmSchema.safeParse({ fecha: '2026-10-28', km: -1 }).success).toBe(false)
  })
})
