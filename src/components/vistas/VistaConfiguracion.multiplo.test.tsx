/**
 * Formulario del múltiplo del redondeo de los precios en masa (#1561, CAT-8; decisión del
 * dueño: pasa a la política comercial). Sólo lectura para quien no es admin, la validación del
 * rango (de 0,01 a 10.000 con dos decimales, como el CHECK y la RPC) y que sin
 * `onGuardarMultiploRedondeo` no aparece.
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
    multiploRedondeoPrecio: 10,
    puedeEditarMultiploRedondeo: true,
    guardandoMultiploRedondeo: false,
    onGuardarMultiploRedondeo: vi.fn(),
    ...over,
  }
}

function formMultiplo() {
  const input = screen.getByLabelText('Múltiplo') as HTMLInputElement
  const form = input.closest('form') as HTMLFormElement
  const boton = within(form).getByRole('button', { name: 'Guardar' })
  return { input, form, boton }
}

describe('VistaConfiguracion — múltiplo del redondeo de los precios en masa', () => {
  it('muestra el valor vigente y qué hace', () => {
    render(<VistaConfiguracion {...props({ multiploRedondeoPrecio: 50 })} />)
    expect(screen.getByText('Redondeo de los precios en masa')).toBeInTheDocument()
    expect(screen.getByText('Vigente: $50')).toBeInTheDocument()
    expect(formMultiplo().input.value).toBe('50')
  })

  it('sin onGuardarMultiploRedondeo no se muestra', () => {
    render(<VistaConfiguracion {...props({ onGuardarMultiploRedondeo: undefined })} />)
    expect(screen.queryByText('Redondeo de los precios en masa')).toBeNull()
  })

  it('el admin guarda un múltiplo nuevo, también con coma decimal', async () => {
    const onGuardar = vi.fn()
    render(<VistaConfiguracion {...props({ onGuardarMultiploRedondeo: onGuardar })} />)
    const { input, boton } = formMultiplo()
    expect(boton).toBeDisabled() // sin cambios
    await userEvent.clear(input)
    await userEvent.type(input, '0,5')
    await userEvent.click(boton)
    expect(onGuardar).toHaveBeenCalledWith(0.5)
  })

  // «1.234» ya no va acá: es plata, y con el punto de miles es mil doscientos treinta y cuatro (#1560).
  it.each(['0', '-10', '10000.01', '1,234', '10.001', 'abc', '12abc', ''])('rechaza %j con su motivo y no guarda', async (valor) => {
    const onGuardar = vi.fn()
    render(<VistaConfiguracion {...props({ onGuardarMultiploRedondeo: onGuardar })} />)
    const { input, boton } = formMultiplo()
    await userEvent.clear(input)
    if (valor) await userEvent.type(input, valor)
    expect(screen.getByRole('alert').textContent).toMatch(/múltiplo/i)
    expect(boton).toBeDisabled()
  })

  // #1560: es plata y se lee con el punto de miles, como el resto de los montos. Con
  // `Number(valor.replace(',', '.'))`, «1.000» se guardaba 1 y «10.000», 10, sin error.
  it.each([
    ['1.000', 1000],
    ['10.000', 10000],
    ['1.000,00', 1000],
    ['1.000,5', 1000.5],
    ['12.5', 12.5],
    ['0.50', 0.5],
  ])('lee %j como %d', async (tipeado, esperado) => {
    const onGuardar = vi.fn()
    render(<VistaConfiguracion {...props({ onGuardarMultiploRedondeo: onGuardar })} />)
    const { input, boton } = formMultiplo()
    await userEvent.clear(input)
    await userEvent.type(input, tipeado)
    expect(screen.queryByRole('alert')).toBeNull()
    await userEvent.click(boton)
    expect(onGuardar).toHaveBeenCalledWith(esperado)
  })

  it('el valor guardado se muestra con coma decimal', () => {
    render(<VistaConfiguracion {...props({ multiploRedondeoPrecio: 0.5 })} />)
    expect(formMultiplo().input.value).toBe('0,5')
  })

  it('quien no es admin lo ve y no lo puede cambiar', () => {
    render(<VistaConfiguracion {...props({ puedeEditarMultiploRedondeo: false })} />)
    expect(formMultiplo().input).toBeDisabled()
    expect(screen.getByText('Solo un admin puede cambiarlo.')).toBeInTheDocument()
  })
})
