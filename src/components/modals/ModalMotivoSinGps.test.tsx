/**
 * #1602: «Continuar sin GPS» pide el motivo, también con `denied`.
 *
 * Y la regla de CLAUDE.md sobre confirmaciones dentro de un modal Radix: en
 * PedidosContainer y en ModalMarcarVisita, `ModalMotivoSinGps` se renderiza
 * como HERMANO del modal abierto (ModalBase en escritorio, BottomSheet en el
 * celular), no adentro. Lo que queda detrás del overlay es una confirmación que
 * NO es un Dialog de Radix. Ésta sí lo es (ModalBase): se portalea al <body>
 * después del modal de abajo, y Radix apila sus capas (DismissableLayer y
 * FocusScope llevan una pila global, no la del árbol de React), así que la de
 * arriba es la que recibe el puntero y el foco. user-event rechaza clickear o
 * tipear sobre algo con `pointer-events: none`, que es lo que le queda a la
 * capa de abajo: si el motivo quedara detrás, estos tests fallan.
 *
 * Lo que sí importa es el orden: si los dos se montaran en el mismo commit, el
 * `aria-hidden` del de abajo taparía también al motivo. En la app no pasa (el
 * motivo se monta después, al confirmar, y además es lazy), y por eso los
 * tests lo montan así.
 */
import { useState, type ReactNode } from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalBase from './ModalBase'
import BottomSheet from '../ui/BottomSheet'
import ModalMotivoSinGps from './ModalMotivoSinGps'

/**
 * Como en la app: el modal del pedido ya está abierto, el preventista toca
 * «Confirmar pedido» y RECIÉN AHÍ el container monta el motivo al lado.
 */
function ConMotivoAlConfirmar({
  envoltorio,
  status,
  onConfirm,
}: {
  envoltorio: (hijos: ReactNode) => ReactNode
  status: 'denied' | 'timeout'
  onConfirm: (m: string) => void
}) {
  const [pidiendo, setPidiendo] = useState(false)
  return (
    <>
      {envoltorio(<button type="button" onClick={() => setPidiendo(true)}>Confirmar pedido</button>)}
      {pidiendo && <ModalMotivoSinGps status={status} onConfirm={onConfirm} onCancel={() => setPidiendo(false)} />}
    </>
  )
}

describe('ModalMotivoSinGps', () => {
  it('con denied explica que la ubicación está bloqueada y exige el motivo', async () => {
    const user = userEvent.setup()
    const onConfirm = vi.fn()
    render(<ModalMotivoSinGps status="denied" onConfirm={onConfirm} onCancel={() => {}} />)
    expect(screen.getByText('La ubicación está bloqueada en este teléfono.')).toBeInTheDocument()
    const confirmar = screen.getByRole('button', { name: 'Confirmar sin GPS' })
    expect(confirmar).toBeDisabled()
    await user.type(screen.getByRole('textbox'), 'no la puedo activar')
    await user.click(confirmar)
    expect(onConfirm).toHaveBeenCalledWith('no la puedo activar')
  })

  it('como hermano de ModalBase abierto (escritorio) se puede tipear y confirmar', async () => {
    const user = userEvent.setup()
    const onConfirm = vi.fn()
    render(
      <ConMotivoAlConfirmar
        status="denied"
        onConfirm={onConfirm}
        envoltorio={h => <ModalBase title="Nuevo Pedido" onClose={() => {}}>{h}</ModalBase>}
      />,
    )
    await user.click(screen.getByRole('button', { name: 'Confirmar pedido' }))
    await user.type(screen.getByRole('textbox'), 'GPS bloqueado')
    await user.click(screen.getByRole('button', { name: 'Confirmar sin GPS' }))
    expect(onConfirm).toHaveBeenCalledWith('GPS bloqueado')
    // El motivo es el diálogo de arriba: el del pedido queda tapado (aria-hidden).
    expect(screen.getByRole('dialog', { name: 'Continuar sin GPS' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Confirmar pedido' })).toBeNull()
  })

  it('como hermano del BottomSheet del celular (el alta de un preventista) también', async () => {
    const user = userEvent.setup()
    const onConfirm = vi.fn()
    render(
      <ConMotivoAlConfirmar
        status="timeout"
        onConfirm={onConfirm}
        envoltorio={h => (
          <BottomSheet open onClose={() => {}} title="Nuevo Pedido" cerrarAlTocarAfuera={false} bodyBare comoDialogo>
            {h}
          </BottomSheet>
        )}
      />,
    )
    await user.click(screen.getByRole('button', { name: 'Confirmar pedido' }))
    await user.type(screen.getByRole('textbox'), 'sótano sin señal')
    await user.click(screen.getByRole('button', { name: 'Confirmar sin GPS' }))
    expect(onConfirm).toHaveBeenCalledWith('sótano sin señal')
  })
})
