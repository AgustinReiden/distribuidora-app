/**
 * Formulario de la ventana de precio anterior (#1157): el aviso de que la
 * ventana también la usa quien tiene señal, solo lectura para quien no es
 * admin, y la validación del rango (entero de 0 a 168, como el CHECK y la RPC).
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
    ...over,
  }
}

function formVentana() {
  const input = screen.getByLabelText('Horas') as HTMLInputElement
  const form = input.closest('form') as HTMLFormElement
  const boton = within(form).getByRole('button', { name: 'Guardar' })
  return { input, form, boton }
}

describe('VistaConfiguracion — ventana de precio anterior', () => {
  it('muestra el aviso de que la ventana vale también para quien tiene señal', () => {
    render(<VistaConfiguracion {...props()} />)
    expect(screen.getByText('Ventana de precio anterior')).toBeInTheDocument()
    expect(screen.getByText(/vale también para quien tiene señal/)).toBeInTheDocument()
    expect(screen.getByText('Vigente: 24 h')).toBeInTheDocument()
  })

  it('sin permiso (no admin) el input y el botón quedan deshabilitados y lo dice', () => {
    render(<VistaConfiguracion {...props({ puedeEditarVentana: false })} />)
    const { input, boton } = formVentana()
    expect(input).toBeDisabled()
    expect(boton).toBeDisabled()
    expect(screen.getByText('Solo un admin puede cambiarla.')).toBeInTheDocument()
  })

  it('el admin escribe 48 y Guardar llama onGuardarVentana(48)', async () => {
    const onGuardarVentana = vi.fn()
    render(<VistaConfiguracion {...props({ onGuardarVentana })} />)
    const { input, boton } = formVentana()
    expect(screen.queryByText('Solo un admin puede cambiarla.')).not.toBeInTheDocument()
    expect(boton).toBeDisabled() // sin cambio
    await userEvent.clear(input)
    await userEvent.type(input, '48')
    expect(boton).toBeEnabled()
    await userEvent.click(boton)
    expect(onGuardarVentana).toHaveBeenCalledWith(48)
  })

  it.each(['169', '2.5', '-1', ''])('%s deja el botón deshabilitado y muestra el error', (v) => {
    const onGuardarVentana = vi.fn()
    render(<VistaConfiguracion {...props({ onGuardarVentana })} />)
    const { input, form, boton } = formVentana()
    fireEvent.change(input, { target: { value: v } })
    expect(boton).toBeDisabled()
    expect(within(form).getByRole('alert')).toHaveTextContent('entre 0 y 168')
    fireEvent.submit(form)
    expect(onGuardarVentana).not.toHaveBeenCalled()
  })

  it('0 es válido: sin tolerancia', async () => {
    const onGuardarVentana = vi.fn()
    render(<VistaConfiguracion {...props({ onGuardarVentana })} />)
    const { input, form, boton } = formVentana()
    fireEvent.change(input, { target: { value: '0' } })
    expect(within(form).queryByRole('alert')).not.toBeInTheDocument()
    expect(boton).toBeEnabled()
    await userEvent.click(boton)
    expect(onGuardarVentana).toHaveBeenCalledWith(0)
  })

  it('se resincroniza cuando llega el valor del servidor', () => {
    const { rerender } = render(<VistaConfiguracion {...props()} />)
    rerender(<VistaConfiguracion {...props({ ventanaPrecioAnteriorHoras: 0 })} />)
    expect(formVentana().input.value).toBe('0')
    expect(screen.getByText('Vigente: 0 h')).toBeInTheDocument()
  })
})
