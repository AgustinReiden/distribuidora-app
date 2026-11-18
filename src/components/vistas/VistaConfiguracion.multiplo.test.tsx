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
  // B20 (D17): el menos y las letras tipeados no entran (ver abajo); lo demás se rechaza con su motivo.
  it.each(['0', '10000.01', '1,234', '10.001', 'abc', ''])('rechaza %j con su motivo y no guarda', async (valor) => {
    const onGuardar = vi.fn()
    render(<VistaConfiguracion {...props({ onGuardarMultiploRedondeo: onGuardar })} />)
    const { input, boton } = formMultiplo()
    await userEvent.clear(input)
    if (valor) await userEvent.type(input, valor)
    expect(screen.getByRole('alert').textContent).toMatch(/múltiplo/i)
    expect(boton).toBeDisabled()
  })

  it.each([
    ['-10', '10'],
    ['12abc', '12'],
  ])('tipeado %j: el menos y las letras no entran, queda %j', async (tipeado, queda) => {
    render(<VistaConfiguracion {...props({ onGuardarMultiploRedondeo: vi.fn() })} />)
    const { input } = formMultiplo()
    await userEvent.clear(input)
    await userEvent.type(input, tipeado)
    expect(input.value).toBe(queda)
  })

  // #1560 y B20 (D17, cambió de regla): es plata. Tipeado, el punto es la coma decimal y los miles
  // los pone el campo («1000» se ve «1.000»).
  it.each([
    ['1000', 1000],
    ['10000', 10000],
    ['1000,00', 1000],
    ['1000,5', 1000.5],
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

// Punto 9 de la segunda pasada de #1644 (#1655): /configuracion guarda en `useState` hasta
// «Guardar», sin modal. Lo tipeado y no guardado levanta la marca de trabajo en curso, para que la
// actualización obligatoria de la app no recargue encima; volver al valor precargado la baja.
describe('VistaConfiguracion — lo tipeado sin guardar es trabajo en curso', () => {
  const todas = props({
    puedeEditarMinimo: true,
    onGuardarAlertasCombos: vi.fn(),
    puedeEditarAlertasCombos: true,
    onGuardarDiasAtrasFechaPedido: vi.fn(),
    puedeEditarDiasAtrasFechaPedido: true,
  })

  it.each([
    ['Compra mínima por pedido', '5', 'configuración: compra mínima y envío sin guardar'],
    ['Preventistas', '5', 'configuración: comisiones sin guardar'],
    ['Amarillo', '5', 'configuración: alertas de vencimiento sin guardar'],
    ['Horas', '5', 'configuración: ventana del precio anterior sin guardar'],
    ['Múltiplo', '5', 'configuración: múltiplo de redondeo sin guardar'],
    ['Margen mínimo', '5', 'configuración: alertas de combos sin guardar'],
    ['Días hacia atrás', '5', 'configuración: días hacia atrás del pedido sin guardar'],
  ])('«%s»', async (etiqueta, tecla, motivo) => {
    const { motivosDeTrabajoEnCurso, _resetTrabajoEnCursoParaTests } = await import('../../utils/trabajoEnCurso')
    _resetTrabajoEnCursoParaTests()
    const user = userEvent.setup()
    render(<VistaConfiguracion {...todas} />)
    expect(motivosDeTrabajoEnCurso()).toEqual([])
    const campo = screen.getByLabelText(etiqueta) as HTMLInputElement
    const precargado = campo.value
    await user.type(campo, tecla)
    expect(motivosDeTrabajoEnCurso()).toEqual([motivo])
    await user.clear(campo)
    await user.type(campo, precargado)
    expect(motivosDeTrabajoEnCurso()).toEqual([])
  })
})
