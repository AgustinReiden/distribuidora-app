/**
 * ModalCliente: el CUIT se valida de verdad (D37 de #1561, 1561-b11) y los datos
 * obligatorios no pasan vacíos ni con espacios solos (la base los frena con un CHECK).
 *
 *  - un CUIT con el dígito verificador equivocado no guarda y dice por qué;
 *  - uno bien armado guarda; vacío se permite;
 *  - uno viejo inválido que no se tocó no bloquea guardar otros cambios;
 *  - razón social, nombre de fantasía y dirección con sólo espacios no guardan.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import ModalCliente from './ModalCliente'
import type { ClienteDB } from '../../types'

vi.mock('../../hooks/queries', () => ({
  usePreventistasQuery: () => ({ data: [] }),
  useZonasEstandarizadasQuery: () => ({ data: [] }),
  useCategoriasQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  useClientesQuery: () => ({ data: [] }),
  usePreventistaZonasQuery: () => ({ data: [] }),
  useDueniosZonasQuery: () => ({ data: new Map() }),
}))
vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ perfil: { rol: 'admin' }, user: { id: 'u-admin' } }),
}))
vi.mock('../AddressAutocomplete', () => ({
  AddressAutocomplete: ({ value, onChange }: { value: string; onChange: (v: string) => void }) => (
    <input data-testid="direccion" value={value} onChange={e => onChange(e.target.value)} />
  ),
}))

const onSave = vi.fn()
const onVerificarDuplicado = vi.fn()
const ESPERA = { timeout: 5000 }

function renderModal(cliente: ClienteDB | null = null) {
  return render(
    <ModalCliente
      cliente={cliente}
      onSave={onSave}
      onVerificarDuplicado={onVerificarDuplicado}
      onClose={vi.fn()}
      guardando={false}
      isAdmin
    />
  )
}

function completar({ cuit = '', razon = 'Kiosco La Esquina', fantasia = 'Kiosco La Esquina', direccion = 'Berutti 399' } = {}) {
  if (cuit !== null) fireEvent.change(screen.getByLabelText('CUIT'), { target: { value: cuit } })
  fireEvent.change(screen.getByLabelText(/raz[óo]n social/i), { target: { value: razon } })
  fireEvent.change(screen.getByLabelText(/nombre fantas[íi]a/i), { target: { value: fantasia } })
  fireEvent.change(screen.getByTestId('direccion'), { target: { value: direccion } })
}
const guardar = () => fireEvent.click(screen.getByRole('button', { name: /^guardar$/i }))

beforeEach(() => {
  vi.clearAllMocks()
  // jsdom no trae scrollIntoView, y el modal lo usa para llevar la vista al primer error.
  Element.prototype.scrollIntoView = vi.fn()
  onVerificarDuplicado.mockResolvedValue({ bloquea: false, avisa: false, motivo: null, distancia_m: null, cliente_visible: null })
})

describe('ModalCliente — CUIT', () => {
  it('con el dígito verificador equivocado no guarda y lo dice', async () => {
    renderModal()
    completar({ cuit: '20123456789' })
    guardar()

    expect(await screen.findByText(/el dígito verificador no coincide/i, {}, ESPERA)).toBeVisible()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('con 11 dígitos bien armados guarda', async () => {
    renderModal()
    completar({ cuit: '20123456786' })
    guardar()

    await waitFor(() => expect(onSave).toHaveBeenCalled(), ESPERA)
  })

  it('vacío se permite', async () => {
    renderModal()
    completar({ cuit: '' })
    guardar()

    await waitFor(() => expect(onSave).toHaveBeenCalled(), ESPERA)
  })

  it('un CUIT viejo inválido que no se tocó no bloquea guardar otros cambios', async () => {
    const existente = {
      id: '7', razon_social: 'Kiosco Viejo', nombre_fantasia: 'Kiosco Viejo', direccion: 'Berutti 399',
      cuit: '20-12345678-9', tipo_documento: 'CUIT', activo: true,
    } as unknown as ClienteDB
    renderModal(existente)
    fireEvent.change(screen.getByLabelText(/nombre fantas[íi]a/i), { target: { value: 'Kiosco Nuevo' } })
    guardar()

    await waitFor(() => expect(onSave).toHaveBeenCalled(), ESPERA)
  })
})

describe('ModalCliente — DNI (B17, #1561)', () => {
  const elegirDni = () => fireEvent.change(screen.getByDisplayValue('CUIT'), { target: { value: 'DNI' } })

  it('elegir DNI y dejarlo vacío guarda sin documento, no el relleno 00-00000000-0', async () => {
    renderModal()
    elegirDni()
    completar({ cuit: null as unknown as string })
    guardar()

    await waitFor(() => expect(onSave).toHaveBeenCalled(), ESPERA)
    expect(onSave.mock.calls[0][0]).toMatchObject({ cuit: '', tipo_documento: 'DNI' })
  })

  it('un DNI se guarda en el formato de almacenamiento, con tipo DNI', async () => {
    renderModal()
    elegirDni()
    fireEvent.change(screen.getByLabelText('DNI'), { target: { value: '30123456' } })
    completar({ cuit: null as unknown as string })
    guardar()

    await waitFor(() => expect(onSave).toHaveBeenCalled(), ESPERA)
    expect(onSave.mock.calls[0][0]).toMatchObject({ cuit: '00-30123456-0', tipo_documento: 'DNI' })
  })

  it('un DNI rellenado con ceros en el campo CUIT no guarda y dice que elija DNI', async () => {
    renderModal()
    completar({ cuit: '00030123468' })
    guardar()

    expect(await screen.findByText(/no empieza con 00/i, {}, ESPERA)).toBeVisible()
    expect(onSave).not.toHaveBeenCalled()
  })

  // El campo era obligatorio y se inventaba un número para poder dar de alta al cliente.
  it('el documento no es obligatorio: se guarda sin él y el campo no se anuncia como requerido', async () => {
    renderModal()
    expect(screen.getByLabelText('CUIT')).not.toHaveAttribute('aria-required')
    completar({ cuit: '' })
    guardar()

    await waitFor(() => expect(onSave).toHaveBeenCalled(), ESPERA)
    expect(onSave.mock.calls[0][0]).toMatchObject({ cuit: '' })
  })

  it('un número inventado rellenado con ceros en el campo CUIT no guarda y dice que se puede dejar vacío', async () => {
    renderModal()
    completar({ cuit: '00000001234' })
    guardar()

    expect(await screen.findByText(/dejá el campo vacío/i, {}, ESPERA)).toBeVisible()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('un cliente con DNI se abre como DNI, con el número limpio', () => {
    const existente = {
      id: '8', razon_social: 'Almacén Inventado', nombre_fantasia: 'Almacén Inventado', direccion: 'Berutti 399',
      cuit: '00-01234567-0', tipo_documento: 'DNI', activo: true,
    } as unknown as ClienteDB
    renderModal(existente)
    expect(screen.getByLabelText('DNI')).toHaveValue('1234567')
  })
})

describe('ModalCliente — obligatorios sin espacios solos', () => {
  it.each([
    ['razón social', { razon: '   ' }, /raz[óo]n social/i],
    ['nombre de fantasía', { fantasia: '   ' }, /nombre de fantas[íi]a/i],
    ['dirección', { direccion: '     ' }, /direcci[óo]n/i],
  ])('%s con espacios solos no guarda', async (_nombre, cambio, mensaje) => {
    renderModal()
    completar(cambio)
    guardar()

    expect(await screen.findByText(mensaje, { selector: 'p' }, ESPERA)).toBeVisible()
    expect(onSave).not.toHaveBeenCalled()
  })
})
