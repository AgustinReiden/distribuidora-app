/**
 * D11 (reportes-R5, decisión del dueño del 26/11; T7 de #1677): el % con que el gerencial simula la
 * comisión pasa a la política comercial. Lo cambia sólo el admin, de 0 a 100 (como el CHECK y la
 * RPC), y sin `onGuardarComisionPctSimulacion` no aparece.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
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
    comisionPctSimulacion: 2,
    guardandoComisionPctSimulacion: false,
    onGuardarComisionPctSimulacion: vi.fn(),
    ...over,
  }
}

function formSimulacion() {
  const titulo = screen.getByText('Simulación de comisiones del gerencial')
  const form = titulo.closest('form') as HTMLFormElement
  const input = within(form).getByLabelText('Porcentaje') as HTMLInputElement
  const boton = within(form).getByRole('button', { name: 'Guardar' })
  return { input, form, boton }
}

describe('VistaConfiguracion — % de la simulación de comisiones del gerencial', () => {
  it('muestra el vigente', () => {
    render(<VistaConfiguracion {...props({ comisionPctSimulacion: 2.5 })} />)
    expect(formSimulacion().input.value).toBe('2,5')
    expect(within(formSimulacion().form).getByText('Vigente: 2,5 %')).toBeInTheDocument()
  })

  it('sin onGuardarComisionPctSimulacion no se muestra', () => {
    render(<VistaConfiguracion {...props({ onGuardarComisionPctSimulacion: undefined })} />)
    expect(screen.queryByText('Simulación de comisiones del gerencial')).toBeNull()
  })

  it('el admin guarda 3,5', async () => {
    const onGuardar = vi.fn()
    const user = userEvent.setup()
    render(<VistaConfiguracion {...props({ onGuardarComisionPctSimulacion: onGuardar })} />)
    const { input, boton } = formSimulacion()
    expect(boton).toBeDisabled()
    await user.clear(input)
    await user.type(input, '3,5')
    await user.click(boton)
    expect(onGuardar).toHaveBeenCalledWith(3.5)
  })

  it('más de 100 queda en rojo y no guarda', async () => {
    const onGuardar = vi.fn()
    const user = userEvent.setup()
    render(<VistaConfiguracion {...props({ onGuardarComisionPctSimulacion: onGuardar })} />)
    const { input, boton, form } = formSimulacion()
    await user.clear(input)
    await user.type(input, '101')
    expect(within(form).getByRole('alert')).toHaveTextContent('Ingresá un porcentaje entre 0 y 100.')
    expect(boton).toBeDisabled()
    expect(onGuardar).not.toHaveBeenCalled()
  })

  it('quien no es admin lo ve y no lo edita', () => {
    render(<VistaConfiguracion {...props({ puedeEditarComisiones: false })} />)
    const { input, form } = formSimulacion()
    expect(input).toBeDisabled()
    expect(within(form).getByText('Solo un admin puede cambiarlo.')).toBeInTheDocument()
  })
})
