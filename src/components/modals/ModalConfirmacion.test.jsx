import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalConfirmacion from './ModalConfirmacion'

describe('ModalConfirmacion', () => {
  const defaultConfig = {
    visible: true,
    tipo: 'danger',
    titulo: 'Confirmar acción',
    mensaje: '¿Estás seguro de que deseas continuar?',
    onConfirm: vi.fn()
  }

  const defaultProps = {
    config: defaultConfig,
    onClose: vi.fn()
  }

  beforeEach(() => {
    vi.clearAllMocks()
  })

  describe('Renderizado', () => {
    it('no renderiza nada cuando config.visible es false', () => {
      const { container } = render(
        <ModalConfirmacion
          config={{ ...defaultConfig, visible: false }}
          onClose={vi.fn()}
        />
      )
      expect(container.firstChild).toBeNull()
    })

    it('no renderiza nada cuando config es null', () => {
      const { container } = render(
        <ModalConfirmacion config={null} onClose={vi.fn()} />
      )
      expect(container.firstChild).toBeNull()
    })

    it('renderiza el modal cuando visible es true', () => {
      render(<ModalConfirmacion {...defaultProps} />)
      expect(screen.getByText('Confirmar acción')).toBeInTheDocument()
      expect(screen.getByText('¿Estás seguro de que deseas continuar?')).toBeInTheDocument()
    })

    it('renderiza botones de Cancelar y Confirmar', () => {
      render(<ModalConfirmacion {...defaultProps} />)
      expect(screen.getByRole('button', { name: 'Cancelar' })).toBeInTheDocument()
      expect(screen.getByRole('button', { name: 'Confirmar' })).toBeInTheDocument()
    })
  })

  describe('Tipos de modal', () => {
    it('muestra estilo danger correctamente', () => {
      render(
        <ModalConfirmacion
          config={{ ...defaultConfig, tipo: 'danger' }}
          onClose={vi.fn()}
        />
      )
      const btnConfirmar = screen.getByRole('button', { name: 'Confirmar' })
      expect(btnConfirmar.className).toContain('text-red-600')
    })

    it('muestra estilo warning correctamente', () => {
      render(
        <ModalConfirmacion
          config={{ ...defaultConfig, tipo: 'warning' }}
          onClose={vi.fn()}
        />
      )
      const btnConfirmar = screen.getByRole('button', { name: 'Confirmar' })
      expect(btnConfirmar.className).toContain('text-yellow-600')
    })

    it('muestra estilo success correctamente', () => {
      render(
        <ModalConfirmacion
          config={{ ...defaultConfig, tipo: 'success' }}
          onClose={vi.fn()}
        />
      )
      const btnConfirmar = screen.getByRole('button', { name: 'Confirmar' })
      expect(btnConfirmar.className).toContain('text-green-600')
    })

    it('usa estilo success por defecto para tipo desconocido', () => {
      render(
        <ModalConfirmacion
          config={{ ...defaultConfig, tipo: 'unknown' }}
          onClose={vi.fn()}
        />
      )
      const btnConfirmar = screen.getByRole('button', { name: 'Confirmar' })
      expect(btnConfirmar.className).toContain('text-green-600')
    })
  })

  describe('Interacciones', () => {
    it('llama onClose al hacer clic en Cancelar', async () => {
      const user = userEvent.setup()
      const onClose = vi.fn()
      render(<ModalConfirmacion config={defaultConfig} onClose={onClose} />)

      await user.click(screen.getByRole('button', { name: 'Cancelar' }))

      expect(onClose).toHaveBeenCalledTimes(1)
    })

    it('llama onConfirm al hacer clic en Confirmar', async () => {
      const user = userEvent.setup()
      const onConfirm = vi.fn()
      render(
        <ModalConfirmacion
          config={{ ...defaultConfig, onConfirm }}
          onClose={vi.fn()}
        />
      )

      await user.click(screen.getByRole('button', { name: 'Confirmar' }))

      expect(onConfirm).toHaveBeenCalledTimes(1)
    })

    it('no llama onClose al hacer clic en Confirmar', async () => {
      const user = userEvent.setup()
      const onClose = vi.fn()
      render(<ModalConfirmacion config={defaultConfig} onClose={onClose} />)

      await user.click(screen.getByRole('button', { name: 'Confirmar' }))

      expect(onClose).not.toHaveBeenCalled()
    })
  })

  describe('Casos de uso comunes', () => {
    it('confirmar eliminación de item', async () => {
      const user = userEvent.setup()
      const onConfirm = vi.fn()
      const config = {
        visible: true,
        tipo: 'danger',
        titulo: 'Eliminar producto',
        mensaje: '¿Estás seguro de eliminar este producto? Esta acción no se puede deshacer.',
        onConfirm
      }

      render(<ModalConfirmacion config={config} onClose={vi.fn()} />)

      expect(screen.getByText('Eliminar producto')).toBeInTheDocument()
      expect(screen.getByText(/esta acción no se puede deshacer/i)).toBeInTheDocument()

      await user.click(screen.getByRole('button', { name: 'Confirmar' }))
      expect(onConfirm).toHaveBeenCalled()
    })

    it('confirmar cambio de estado', async () => {
      const user = userEvent.setup()
      const onConfirm = vi.fn()
      const config = {
        visible: true,
        tipo: 'warning',
        titulo: 'Cambiar estado',
        mensaje: '¿Marcar este pedido como entregado?',
        onConfirm
      }

      render(<ModalConfirmacion config={config} onClose={vi.fn()} />)

      expect(screen.getByText('Cambiar estado')).toBeInTheDocument()

      await user.click(screen.getByRole('button', { name: 'Confirmar' }))
      expect(onConfirm).toHaveBeenCalled()
    })

    it('confirmar acción exitosa', async () => {
      const user = userEvent.setup()
      const onConfirm = vi.fn()
      const config = {
        visible: true,
        tipo: 'success',
        titulo: 'Operación completada',
        mensaje: '¿Deseas continuar con el siguiente paso?',
        onConfirm
      }

      render(<ModalConfirmacion config={config} onClose={vi.fn()} />)

      const btnConfirmar = screen.getByRole('button', { name: 'Confirmar' })
      expect(btnConfirmar.className).toContain('text-green-600')

      await user.click(btnConfirmar)
      expect(onConfirm).toHaveBeenCalled()
    })
  })

  describe('Accesibilidad', () => {
    it('el modal tiene overlay con fondo oscuro', () => {
      const { container } = render(<ModalConfirmacion {...defaultProps} />)
      const overlay = container.querySelector('.bg-black.bg-opacity-50')
      expect(overlay).toBeInTheDocument()
    })

    it('los botones son interactivos', () => {
      render(<ModalConfirmacion {...defaultProps} />)

      const btnCancelar = screen.getByRole('button', { name: 'Cancelar' })
      const btnConfirmar = screen.getByRole('button', { name: 'Confirmar' })

      expect(btnCancelar).not.toBeDisabled()
      expect(btnConfirmar).not.toBeDisabled()
    })
  })

  /**
   * Campo de fecha opcional.
   *
   * EL INCIDENTE: "marcar entregado" individual estampaba `fecha_entrega`
   * SIEMPRE con la fecha de hoy. El uso real es al revés — el chofer sale el
   * lunes y el encargado marca las entregas el martes a la mañana— así que la
   * rendición del lunes quedaba vacía y la del martes inflada con mercadería que
   * no salió ese día. Las entregas MASIVAS ya tenían su selector de fecha; la
   * individual no, y el bug no rompe nada visible: sólo mueve la plata de día.
   */
  describe('Campo de fecha', () => {
    const campoFecha = {
      label: 'Fecha de entrega',
      valorInicial: '2026-08-18',
      max: '2026-08-18',
      ayuda: 'Si estás cargando la entrega de un día anterior, cambiala.',
    }

    const renderConFecha = (onConfirm = vi.fn()) => {
      render(
        <ModalConfirmacion
          config={{ ...defaultConfig, tipo: 'success', campoFecha, onConfirm }}
          onClose={vi.fn()}
        />,
      )
      return onConfirm
    }

    it('sin campoFecha no muestra input y confirma sin argumento', () => {
      const onConfirm = vi.fn()
      render(<ModalConfirmacion config={{ ...defaultConfig, onConfirm }} onClose={vi.fn()} />)

      expect(screen.queryByLabelText(/fecha de entrega/i)).toBeNull()
      screen.getByRole('button', { name: 'Confirmar' }).click()
      expect(onConfirm).toHaveBeenCalledWith(undefined)
    })

    it('arranca en el valor inicial y lo devuelve al confirmar', () => {
      const onConfirm = renderConFecha()

      expect(screen.getByLabelText(/fecha de entrega/i).value).toBe('2026-08-18')
      screen.getByRole('button', { name: 'Confirmar' }).click()
      expect(onConfirm).toHaveBeenCalledWith('2026-08-18')
    })

    it('devuelve la fecha elegida, no la de hoy — el caso del incidente', async () => {
      const user = userEvent.setup()
      const onConfirm = renderConFecha()

      // El encargado marca el martes las entregas que el chofer hizo el lunes.
      const input = screen.getByLabelText(/fecha de entrega/i)
      await user.clear(input)
      await user.type(input, '2026-08-17')
      await user.click(screen.getByRole('button', { name: 'Confirmar' }))

      expect(onConfirm).toHaveBeenCalledWith('2026-08-17')
    })

    it('no deja confirmar con la fecha vacía', async () => {
      const user = userEvent.setup()
      const onConfirm = renderConFecha()

      await user.clear(screen.getByLabelText(/fecha de entrega/i))

      const boton = screen.getByRole('button', { name: 'Confirmar' })
      expect(boton).toBeDisabled()
      expect(onConfirm).not.toHaveBeenCalled()
    })

    it('no permite elegir una fecha futura', () => {
      renderConFecha()
      expect(screen.getByLabelText(/fecha de entrega/i)).toHaveAttribute('max', '2026-08-18')
    })

    it('muestra el texto de ayuda', () => {
      renderConFecha()
      expect(screen.getByText(/cargando la entrega de un día anterior/i)).toBeInTheDocument()
    })
  })
})
