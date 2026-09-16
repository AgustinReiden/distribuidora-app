/**
 * El guard de duplicados dentro de ModalCliente (mig 250, #663).
 *
 * Dos cosas que sólo un test que monte el modal puede fijar:
 *
 * 1. Que la confirmación del AVISO se renderice **visible**. Una confirmación
 *    disparada desde un modal Radix tiene que vivir adentro del modal: como
 *    hermano en el container queda detrás del overlay y falla en silencio (ya
 *    pasó con ModalActualizacionMasivaPrecios). Radix portalea el contenido
 *    fuera del árbol, así que mirar el JSX no alcanza.
 * 2. Que un BLOQUEO no guarde nada y muestre el motivo, y que un error de la
 *    RPC tampoco guarde (fail-closed).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import ModalCliente from './ModalCliente'

vi.mock('../../hooks/queries', () => ({
  usePreventistasQuery: () => ({ data: [] }),
  useZonasEstandarizadasQuery: () => ({ data: [] }),
  useCategoriasQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  useClientesQuery: () => ({ data: [] }),
}))

vi.mock('../AddressAutocomplete', () => ({
  AddressAutocomplete: ({ value, onChange }: { value: string; onChange: (v: string) => void }) => (
    <input data-testid="direccion" value={value} onChange={e => onChange(e.target.value)} />
  ),
}))

const onSave = vi.fn()
const onVerificarDuplicado = vi.fn()

function renderModal() {
  return render(
    <ModalCliente
      cliente={null}
      onSave={onSave}
      onVerificarDuplicado={onVerificarDuplicado}
      onClose={vi.fn()}
      guardando={false}
      isAdmin
    />
  )
}

/** Completa lo mínimo que pide el schema y toca Guardar. */
async function completarYGuardar() {
  fireEvent.change(screen.getByLabelText(/raz[óo]n social/i), {
    target: { value: 'Kiosco La Esquina' },
  })
  fireEvent.change(screen.getByLabelText(/nombre fantas[íi]a/i), {
    target: { value: 'Kiosco La Esquina' },
  })
  fireEvent.change(screen.getByTestId('direccion'), { target: { value: 'Berutti 399' } })
  fireEvent.click(screen.getByRole('button', { name: /^guardar$/i }))
}

function veredicto(over: Record<string, unknown> = {}) {
  return {
    bloquea: false,
    avisa: false,
    motivo: null,
    distancia_m: null,
    cliente_visible: null,
    ...over,
  }
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('ModalCliente — guard de duplicados', () => {
  it('sin hallazgo guarda directo, sin preguntar nada', async () => {
    onVerificarDuplicado.mockResolvedValue(veredicto())
    renderModal()
    await completarYGuardar()

    await waitFor(() => expect(onSave).toHaveBeenCalled())
    expect(onSave.mock.calls[0][0].duplicadoConfirmado).toBeUndefined()
  })

  it('el AVISO se confirma ADENTRO del modal y recién ahí guarda', async () => {
    onVerificarDuplicado.mockResolvedValue(veredicto({
      avisa: true,
      motivo: 'distancia',
      distancia_m: 5.2,
      cliente_visible: { id: 22, nombre: 'LOS PORTEÑOS', activo: true },
    }))
    renderModal()
    await completarYGuardar()

    // Si la confirmación quedara detrás del overlay (el bug), este texto no
    // sería visible.
    expect(await screen.findByText(/Hay un cliente muy cerca/i)).toBeVisible()
    expect(screen.getByText(/5,2 m/)).toBeVisible()
    // Todavía no guardó nada: la pregunta está abierta.
    expect(onSave).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: /^confirmar$/i }))
    await waitFor(() => expect(onSave).toHaveBeenCalled())
    expect(onSave.mock.calls[0][0].duplicadoConfirmado).toBe(true)
  })

  it('cancelar el aviso no guarda nada', async () => {
    onVerificarDuplicado.mockResolvedValue(veredicto({
      avisa: true,
      motivo: 'distancia',
      distancia_m: 8.4,
      cliente_visible: { id: 22, codigo: 14, nombre: 'Kiosco', activo: true },
    }))
    renderModal()
    await completarYGuardar()

    // El "Cancelar" del confirm, no el del formulario: el confirm se monta
    // después, así que es el último del documento.
    expect(await screen.findByText(/cliente muy cerca/i)).toBeVisible()
    const cancelar = screen.getAllByRole('button', { name: /^cancelar$/i })
    fireEvent.click(cancelar[cancelar.length - 1])

    await waitFor(() => expect(screen.queryByText(/cliente muy cerca/i)).not.toBeInTheDocument())
    expect(onSave).not.toHaveBeenCalled()
  })

  it('un BLOQUEO muestra el motivo y no guarda', async () => {
    onVerificarDuplicado.mockResolvedValue(veredicto({
      bloquea: true,
      motivo: 'direccion',
      cliente_visible: { id: 382, nombre: 'PASAJE VERA Y ARAGON 2551', activo: true },
    }))
    renderModal()
    await completarYGuardar()

    expect(await screen.findByRole('alert')).toHaveTextContent(/Ya hay un cliente en esa dirección/i)
    expect(onSave).not.toHaveBeenCalled()
  })

  // Fail-closed: un guard que no puede mirar y guarda igual es el bug entero.
  it('si la verificación falla, no guarda y lo dice', async () => {
    onVerificarDuplicado.mockRejectedValue(new Error('No se pudo verificar si ya existe un cliente igual.'))
    renderModal()
    await completarYGuardar()

    expect(await screen.findByRole('alert')).toHaveTextContent(/No se pudo verificar/i)
    expect(onSave).not.toHaveBeenCalled()
  })
})
