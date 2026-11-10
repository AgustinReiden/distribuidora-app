/**
 * Formulario de los días hacia atrás de la fecha del pedido (#1514): sólo lectura para quien
 * no es admin, la validación del rango (entero de 0 a 30, como el CHECK y la RPC) y que sin
 * `onGuardarDiasAtrasFechaPedido` no aparece.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaConfiguracion, { type VistaConfiguracionProps } from './VistaConfiguracion'

function props(over: Partial<VistaConfiguracionProps> = {}): VistaConfiguracionProps {
  return {
    montoMinimoActual: 0,
    cargando: false,
    guardando: false,
    impacto: undefined,
    impactoCargando: false,
    onMontoTipeado: vi.fn(),
    onGuardar: vi.fn(),
    nombreSucursal: 'Tucumán',
    comisionPctPreventista: 2,
    comisionPctOtros: 0,
    guardandoComisiones: false,
    onGuardarComisiones: vi.fn(),
    puedeEditarComisiones: true,
    diasAlertaVencimiento: 60,
    diasCriticoVencimiento: 15,
    guardandoAlertas: false,
    onGuardarAlertas: vi.fn(),
    mostrarSinStock: true,
    guardandoMostrarSinStock: false,
    onGuardarMostrarSinStock: vi.fn(),
    ventanaPrecioAnteriorHoras: 24,
    puedeEditarVentana: true,
    guardandoVentana: false,
    onGuardarVentana: vi.fn(),
    diasAtrasFechaPedido: 7,
    puedeEditarDiasAtrasFechaPedido: true,
    guardandoDiasAtrasFechaPedido: false,
    onGuardarDiasAtrasFechaPedido: vi.fn(),
    ...over,
  }
}

function formDias() {
  const input = screen.getByLabelText('Días hacia atrás') as HTMLInputElement
  const form = input.closest('form') as HTMLFormElement
  const boton = within(form).getByRole('button', { name: 'Guardar' })
  return { input, form, boton }
}

describe('VistaConfiguracion — días hacia atrás de la fecha del pedido', () => {
  it('muestra el aviso de la cola offline y el valor vigente', () => {
    render(<VistaConfiguracion {...props()} />)
    expect(screen.getByText('Fecha del pedido hacia atrás')).toBeInTheDocument()
    expect(screen.getByText(/queda en la cola con el motivo/)).toBeInTheDocument()
    expect(screen.getByText('Vigente: 7 días')).toBeInTheDocument()
  })

  it('sin onGuardarDiasAtrasFechaPedido no se muestra', () => {
    render(<VistaConfiguracion {...props({ onGuardarDiasAtrasFechaPedido: undefined })} />)
    expect(screen.queryByText('Fecha del pedido hacia atrás')).not.toBeInTheDocument()
  })

  it('sin permiso (no admin) el input y el botón quedan deshabilitados y lo dice', () => {
    render(<VistaConfiguracion {...props({ puedeEditarDiasAtrasFechaPedido: false })} />)
    const { input, boton } = formDias()
    expect(input).toBeDisabled()
    expect(boton).toBeDisabled()
    expect(screen.getByText('Solo un admin puede cambiarlos.')).toBeInTheDocument()
  })

  it('el admin escribe 3 y Guardar llama onGuardarDiasAtrasFechaPedido(3)', async () => {
    const onGuardarDiasAtrasFechaPedido = vi.fn()
    render(<VistaConfiguracion {...props({ onGuardarDiasAtrasFechaPedido })} />)
    const { input, boton } = formDias()
    expect(boton).toBeDisabled() // sin cambio
    await userEvent.clear(input)
    await userEvent.type(input, '3')
    expect(boton).toBeEnabled()
    await userEvent.click(boton)
    expect(onGuardarDiasAtrasFechaPedido).toHaveBeenCalledWith(3)
  })

  it.each(['31', '2.5', '-1', ''])('%s deja el botón deshabilitado y muestra el error', (v) => {
    const onGuardarDiasAtrasFechaPedido = vi.fn()
    render(<VistaConfiguracion {...props({ onGuardarDiasAtrasFechaPedido })} />)
    const { input, form, boton } = formDias()
    fireEvent.change(input, { target: { value: v } })
    expect(boton).toBeDisabled()
    expect(within(form).getByRole('alert')).toHaveTextContent('entre 0 y 30')
    fireEvent.submit(form)
    expect(onGuardarDiasAtrasFechaPedido).not.toHaveBeenCalled()
  })

  it('0 es válido: sólo la fecha de hoy', async () => {
    const onGuardarDiasAtrasFechaPedido = vi.fn()
    render(<VistaConfiguracion {...props({ onGuardarDiasAtrasFechaPedido })} />)
    const { input, form, boton } = formDias()
    fireEvent.change(input, { target: { value: '0' } })
    expect(within(form).queryByRole('alert')).not.toBeInTheDocument()
    await userEvent.click(boton)
    expect(onGuardarDiasAtrasFechaPedido).toHaveBeenCalledWith(0)
  })

  it('se resincroniza cuando llega el valor del servidor', () => {
    const { rerender } = render(<VistaConfiguracion {...props()} />)
    rerender(<VistaConfiguracion {...props({ diasAtrasFechaPedido: 1 })} />)
    expect(formDias().input.value).toBe('1')
    expect(screen.getByText('Vigente: 1 día')).toBeInTheDocument()
  })
})
