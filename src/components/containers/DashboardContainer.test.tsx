/**
 * El backup del dashboard fallaba en silencio (residual de #523/#524):
 * `descargarJSON` tira cuando `traerTodoVerificado` no puede probar que bajó
 * todo, pero `DashboardToolbar` tipaba `onDescargarBackup` como `() => void` y
 * la llamaba sin `await` — el rechazo quedaba sin manejar y, a los ojos de
 * quien apretó el botón, "Backup" no hacía nada.
 *
 * Este test fija que el error SE MUESTRA.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mockDescargarJSON = vi.fn()
const mockNotifyError = vi.fn()

vi.mock('../../hooks/queries', () => ({
  useMetricasQuery: () => ({ data: undefined, isLoading: false, refetch: vi.fn() }),
  useClientesQuery: () => ({ data: [] }),
  useAvanceMetasQuery: () => ({ data: undefined }),
  periodoMensual: () => '2026-09',
}))

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({
    user: { id: 'u1' },
    isAdmin: true,
    isPreventista: false,
    isEncargado: false,
    authReady: true,
  }),
}))

vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: mockNotifyError, success: vi.fn() }),
}))

vi.mock('../../hooks/supabase', () => ({
  useBackup: () => ({ exportando: false, descargarJSON: mockDescargarJSON }),
}))

// La vista no es lo que se prueba acá: sólo hace falta el botón que dispara
// el backup, tal como lo recibe de DashboardContainer.
vi.mock('../vistas/VistaDashboard', () => ({
  default: ({ onDescargarBackup }: { onDescargarBackup: (tipo: string) => Promise<void> }) => (
    <button type="button" onClick={() => onDescargarBackup('completo')}>Backup</button>
  ),
}))

import DashboardContainer from './DashboardContainer'

describe('DashboardContainer › backup', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('muestra un error cuando el backup no cierra (traerTodoVerificado tira)', async () => {
    mockDescargarJSON.mockRejectedValue(new Error('el backup de pedidos quedó incompleto'))

    const user = userEvent.setup()
    render(<DashboardContainer />)
    await user.click(await screen.findByRole('button', { name: 'Backup' }))

    expect(mockNotifyError).toHaveBeenCalledWith(
      expect.stringContaining('el backup de pedidos quedó incompleto'),
    )
  })

  it('no muestra error cuando el backup sí cierra', async () => {
    mockDescargarJSON.mockResolvedValue(undefined)

    const user = userEvent.setup()
    render(<DashboardContainer />)
    await user.click(await screen.findByRole('button', { name: 'Backup' }))

    expect(mockDescargarJSON).toHaveBeenCalledWith('completo')
    expect(mockNotifyError).not.toHaveBeenCalled()
  })
})
