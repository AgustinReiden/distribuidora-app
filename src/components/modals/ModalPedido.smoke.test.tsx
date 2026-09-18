/**
 * ModalPedido — smoke de caracterización del ALTA DE PEDIDO.
 *
 * Es el flujo más caro de romper de toda la app: lo usa el preventista parado en
 * el mostrador, con el cliente esperando. Tenía 1303 líneas y cero tests.
 *
 * Estos tests NO juzgan el comportamiento: lo FIJAN tal como está hoy, por rol
 * ARIA y por texto visible, para que un rediseño de la UI (el pase a bottom
 * sheet en mobile) se ponga rojo si mueve algo que importa. Por eso no hay una
 * sola aserción sobre clases de Tailwind: el acoplamiento a clases es
 * justamente lo que el rediseño viene a romper.
 *
 * Tres cosas que conviene saber antes de leerlos:
 *
 *  - `onGuardar` NO recibe payload: es `() => void`. El pedido que se persiste
 *    lo arma `PedidosContainer` con su propio `nuevoPedido`. Acá el harness
 *    reproduce ese estado con los mismos handlers del container y se lo pasa al
 *    spy, así que lo que se asevera es "qué estado quedó armado cuando el modal
 *    pidió guardar".
 *  - El cajón del carrito vive SIEMPRE en el DOM y se tapa con
 *    `aria-hidden={!carritoAbierto}`. Las queries por ROL lo respetan (las de
 *    texto no), así que "está en el carrito" se prueba abriendo el cajón — y eso
 *    es parte de lo que hay que conservar.
 *  - Los `<select>` del cajón (Forma de Pago, Estado de Pago, Preventista) NO
 *    tienen nombre accesible: su `<label>` es un hermano suelto, sin `htmlFor`
 *    ni anidado. Por eso se los busca por `getByDisplayValue` (la opción
 *    elegida), que sigue siendo comportamiento observable y no estructura. El
 *    único que sí tiene nombre es el toggle FC/ZZ del header.
 */
import { useState } from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent, { PointerEventsCheckLevel } from '@testing-library/user-event'

// Fixtures mutables de los hooks mockeados. `vi.mock` se hoistea arriba de los
// imports, así que las factories no pueden capturar consts de este módulo.
const { estadoMock } = vi.hoisted(() => ({
  estadoMock: {
    /** Compra mínima de la sucursal (migs 204/205). 0 = sin política. */
    montoMinimoPedido: 0,
    bonificaciones: [] as Array<{
      productoId: string
      promoId: string
      promoNombre: string
      cantidadBonificacion: number
      descripcionRegalo?: string
    }>,
    /** Mínimo de venta por producto (mig 147). Alimenta el badge, el piso al
     *  agregar y el `moqMap` del carrito. */
    minimosProducto: undefined as Map<string, number> | undefined,
    /** Lo que el hook REPORTA como incumplido. Ver el test de MOQ. */
    violacionesMOQ: [] as Array<{
      productoId: string
      cantidadActual: number
      cantidadMinima: number
    }>,
    faltantes: [] as Array<{
      grupoNombre: string
      faltante: number
      precioTier: number
      etiqueta?: string
    }>,
    faltantesBonificacion: [] as Array<{
      productoId: string
      promoNombre: string
      faltante: number
      bonificacion: number
    }>,
    hayDescuentoTotal: false,
    totalOriginal: 0,
    totalConDescuentoCliente: 0,
    /** Padrón del selector "Preventista asignado *" (solo admin). */
    preventistasAsignables: [] as Array<{ id: string; nombre: string }>,
  },
}))

vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({
    politicas: {
      montoMinimoPedido: estadoMock.montoMinimoPedido,
      comisionPctPreventista: 2,
      comisionPctOtros: 0,
      diasAlertaVencimiento: 60,
      diasCriticoVencimiento: 15,
    },
  }),
}))

vi.mock('../../hooks/queries/useUsuariosQuery', () => ({
  usePreventistasAsignablesQuery: () => ({ data: estadoMock.preventistasAsignables }),
}))

// El alta rápida de cliente monta `AddressAutocomplete`, que carga la API de
// Google por script. Sin red ni API key el hook real haría un `setInterval` de
// 15s: se mockea en error, que es el modo degradado que el componente ya sabe
// mostrar ("Autocompletado no disponible. Escribí la dirección manualmente.").
const googleMapsCaido = {
  isLoaded: false,
  isLoading: false,
  error: 'Google Maps no se carga en tests',
  load: async (): Promise<void> => {},
}
vi.mock('../../hooks/useGoogleMaps', () => ({
  useGoogleMaps: () => googleMapsCaido,
  default: () => googleMapsCaido,
  loadGoogleMapsAPI: async (): Promise<void> => {},
}))

// Las tres capas de precio (promo → mayorista → descuento del cliente) tienen
// sus propios tests; acá interesa la pantalla. Por defecto se devuelve una
// resolución neutra: sin promos ni escalas, el total que muestra el modal es la
// suma cruda de `precioUnitario * cantidad`.
vi.mock('../../hooks/usePromocionPedido', () => ({
  usePromocionPedido: (
    items: Array<{ productoId: string; cantidad: number; precioUnitario: number }>,
  ) => {
    // Mismo cálculo que `construirMOQMap`: sólo los mínimos > 1 y sólo de lo que
    // ya está en el carrito. Es el que fija el piso de los controles -/+ y del
    // input de cantidad.
    const moqMap = new Map<string, number>()
    for (const item of items) {
      const moq = estadoMock.minimosProducto?.get(String(item.productoId))
      if (moq && moq > 1) moqMap.set(String(item.productoId), moq)
    }
    return {
      preciosResueltos: new Map(),
      faltantes: estadoMock.faltantes,
      promoResolucion: {
        bonificaciones: estadoMock.bonificaciones,
        productosConPromo: new Set<string>(),
      },
      faltantesBonificacion: estadoMock.faltantesBonificacion,
      itemsFinales: items,
      totalFinal: 0,
      totalOriginal: estadoMock.totalOriginal,
      ahorro: 0,
      hayDescuento: false,
      itemsConDescuentoCliente: items,
      totalConDescuentoCliente: estadoMock.totalConDescuentoCliente,
      hayDescuentoCliente: false,
      hayDescuentoTotal: estadoMock.hayDescuentoTotal,
      descuentoClientePct: new Map<string, number>(),
      descuentoPorCategoria: new Set<string>(),
      isLoading: false,
      moqMap,
      minimosProducto: estadoMock.minimosProducto,
      violacionesMOQ: estadoMock.violacionesMOQ,
    }
  },
}))

import ModalPedido, { type NuevoPedidoState } from './ModalPedido'
import type { PatchHorarioCliente } from '../ui/BloqueHorarioRequerido'
import { fechaLocalISO } from '../../utils/formatters'
import type { ClienteDB, ProductoDB } from '../../types'

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const PRODUCTOS: ProductoDB[] = [
  { id: '1', nombre: 'Gaseosa Cola 2L', precio: 1250, stock: 40, categoria: 'Bebidas' },
  { id: '2', nombre: 'Galletitas Surtidas', precio: 800, stock: 3, categoria: 'Almacen' },
  // Agotado: se LISTA igual, deshabilitado y con el motivo (no se filtra).
  { id: '3', nombre: 'Agua sin Gas 500cc', precio: 900, stock: 0, categoria: 'Bebidas' },
]

const CLIENTES: ClienteDB[] = [
  {
    id: '10',
    nombre_fantasia: 'Kiosco El Sol',
    razon_social: 'El Sol SRL',
    direccion: 'San Martin 100',
    horarios_atencion: '08:00-18:00',
    // Preselecciona FC al elegirlo (mig 116). Ver el camino feliz.
    tipo_factura_default: 'FC',
  },
  {
    id: '11',
    nombre_fantasia: 'Almacen Dona Rosa',
    razon_social: 'Rosa SA',
    direccion: 'Belgrano 250',
    horarios_atencion: '09:00-13:00',
    // Deuda previa: sólo se avisa si el rol puede verla (`puedeVerDeuda`).
    saldo_cuenta: 12345,
  },
  {
    id: '12',
    nombre_fantasia: 'Feria La Banda',
    razon_social: 'Banda SRL',
    direccion: 'Ruta 9 Km 4',
    // Sin horario cargado (mig 157): bloquea el confirmar hasta resolverlo.
  },
]

const CATEGORIAS = ['Bebidas', 'Almacen']

/**
 * `formatPrecio` usa Intl es-AR: mete un espacio DURO (U+00A0) entre el signo y
 * el número. El normalizador de testing-library lo colapsa a un espacio común,
 * así que acá se escribe con espacio normal.
 */
const TOTAL_SEIS_UNIDADES = '$ 7.500,00'

interface HarnessProps {
  onGuardarSpy: (payload: NuevoPedidoState) => void
  onCloseSpy?: () => void
  onEliminarPromoSpy?: (promoId: string, promoNombre: string) => void
  onRestaurarPromoSpy?: (promoId: string) => void
  onActualizarPrecioSpy?: (productoId: string, precio: number) => void
  onCrearClienteSpy?: (cliente: Record<string, unknown>) => void
  onGuardarHorarioSpy?: (clienteId: string, patch: PatchHorarioCliente) => void
  isAdmin?: boolean
  guardando?: boolean
  isOffline?: boolean
  puedeVerDeuda?: boolean
  promosEliminadas?: Array<{ promoId: string; promoNombre: string }>
}

/**
 * Reproduce el cableado real de `PedidosContainer` (líneas 2033-2140): el modal
 * no tiene el estado del pedido, sólo avisa cambios. Los handlers son copia de
 * los que el container le pasa hoy, incluidas las dos reglas que viven en el
 * container y no en el modal:
 *
 *  - `onClienteChange` preselecciona `tipoFactura` con el `tipo_factura_default`
 *    del cliente (mig 116), leyendo la lista de clientes del render actual —
 *    igual que el container, que todavía no refetcheó cuando el alta rápida
 *    acaba de crear uno.
 *  - `onEstadoPagoChange` resetea `montoPagado` al salir de "parcial".
 *  - `onAgregarItem` usa el `cantidad` que manda el modal (el mínimo de venta,
 *    mig 147) sólo la primera vez; si ya está en el carrito suma de a uno.
 *
 * La lista de clientes es estado del harness porque dos flujos la modifican:
 * el alta rápida (crea uno) y el bloque de horario (le parchea el horario).
 */
function Harness({
  onGuardarSpy,
  onCloseSpy,
  onEliminarPromoSpy,
  onRestaurarPromoSpy,
  onActualizarPrecioSpy,
  onCrearClienteSpy,
  onGuardarHorarioSpy,
  isAdmin,
  guardando,
  isOffline,
  puedeVerDeuda,
  promosEliminadas,
}: HarnessProps) {
  const [clientes, setClientes] = useState<ClienteDB[]>(CLIENTES)
  const [pedido, setPedido] = useState<NuevoPedidoState>({
    clienteId: '',
    items: [],
    notas: '',
    formaPago: 'efectivo',
    estadoPago: 'pendiente',
    montoPagado: 0,
    fecha: fechaLocalISO(),
    tipoFactura: 'ZZ',
  })

  return (
    <ModalPedido
      productos={PRODUCTOS}
      clientes={clientes}
      categorias={CATEGORIAS}
      nuevoPedido={pedido}
      guardando={guardando ?? false}
      isAdmin={isAdmin}
      isOffline={isOffline}
      puedeVerDeuda={puedeVerDeuda}
      currentUserId="u-1"
      promosEliminadas={promosEliminadas}
      onClose={() => onCloseSpy?.()}
      onGuardar={() => onGuardarSpy(pedido)}
      onClienteChange={(clienteId) =>
        setPedido(prev => ({
          ...prev,
          clienteId,
          tipoFactura:
            clientes.find(c => String(c.id) === String(clienteId))?.tipo_factura_default ?? 'ZZ',
        }))
      }
      onAgregarItem={(productoId, cantidad = 1, precio) => {
        setPedido(prev => {
          const existe = prev.items.find(i => i.productoId === productoId)
          if (existe) {
            return {
              ...prev,
              items: prev.items.map(i =>
                i.productoId === productoId ? { ...i, cantidad: i.cantidad + 1 } : i,
              ),
            }
          }
          const producto = PRODUCTOS.find(p => p.id === productoId)
          return {
            ...prev,
            items: [
              ...prev.items,
              { productoId, cantidad, precioUnitario: precio ?? producto?.precio ?? 0 },
            ],
          }
        })
      }}
      onActualizarCantidad={(productoId, cantidad) => {
        setPedido(prev =>
          cantidad <= 0
            ? { ...prev, items: prev.items.filter(i => i.productoId !== productoId) }
            : {
                ...prev,
                items: prev.items.map(i =>
                  i.productoId === productoId ? { ...i, cantidad } : i,
                ),
              },
        )
      }}
      onActualizarPrecio={(productoId, precio) => {
        onActualizarPrecioSpy?.(productoId, precio)
        setPedido(prev => ({
          ...prev,
          items: prev.items.map(i =>
            i.productoId === productoId
              ? { ...i, precioUnitario: precio, precioOverride: true }
              : i,
          ),
        }))
      }}
      onCrearCliente={async (clienteData) => {
        onCrearClienteSpy?.(clienteData)
        const creado: ClienteDB = {
          id: '99',
          nombre_fantasia: String(clienteData.nombreFantasia ?? ''),
          razon_social: String(clienteData.razonSocial ?? ''),
          direccion: String(clienteData.direccion ?? ''),
          horarios_atencion: String(clienteData.horariosAtencion ?? ''),
        }
        setClientes(prev => [...prev, creado])
        return { id: '99' }
      }}
      onGuardarHorarioCliente={async (clienteId, patch) => {
        onGuardarHorarioSpy?.(clienteId, patch)
        setClientes(prev =>
          prev.map(c => (String(c.id) === clienteId ? { ...c, ...patch } : c)),
        )
      }}
      onNotasChange={(notas) => setPedido(prev => ({ ...prev, notas }))}
      onFormaPagoChange={(formaPago) => setPedido(prev => ({ ...prev, formaPago }))}
      onEstadoPagoChange={(estadoPago) =>
        setPedido(prev => ({
          ...prev,
          estadoPago,
          // Al salir de "parcial" el monto tipeado deja de tener sentido:
          // si queda, se cobraría de más al confirmar.
          montoPagado: estadoPago === 'parcial' ? prev.montoPagado : 0,
        }))
      }
      onMontoPagadoChange={(montoPagado) => setPedido(prev => ({ ...prev, montoPagado }))}
      onTipoFacturaChange={(tipoFactura) => setPedido(prev => ({ ...prev, tipoFactura }))}
      onPreventistaChange={(preventistaId) => setPedido(prev => ({ ...prev, preventistaId }))}
      onEliminarPromoCreacion={onEliminarPromoSpy}
      onRestaurarPromoCreacion={onRestaurarPromoSpy}
    />
  )
}

interface OpcionesMontaje {
  /**
   * Apaga el chequeo de `pointer-events` de userEvent. Sólo para probar el
   * click AFUERA del modal: Radix le pone `pointer-events: none` al `body`
   * mientras el diálogo está abierto, así que sin esto userEvent se niega a
   * tocarlo y el guard de `onInteractOutside` queda sin probar.
   */
  permitirClickAfuera?: boolean
}

function montar(props: Partial<HarnessProps> = {}, opciones: OpcionesMontaje = {}) {
  const onGuardarSpy = vi.fn()
  const onCloseSpy = vi.fn()
  const onEliminarPromoSpy = vi.fn()
  const onRestaurarPromoSpy = vi.fn()
  const onActualizarPrecioSpy = vi.fn()
  const onCrearClienteSpy = vi.fn()
  const onGuardarHorarioSpy = vi.fn()
  const user = userEvent.setup(
    opciones.permitirClickAfuera
      ? { pointerEventsCheck: PointerEventsCheckLevel.Never }
      : {},
  )
  render(
    <Harness
      onGuardarSpy={onGuardarSpy}
      onCloseSpy={onCloseSpy}
      onEliminarPromoSpy={onEliminarPromoSpy}
      onRestaurarPromoSpy={onRestaurarPromoSpy}
      onActualizarPrecioSpy={onActualizarPrecioSpy}
      onCrearClienteSpy={onCrearClienteSpy}
      onGuardarHorarioSpy={onGuardarHorarioSpy}
      {...props}
    />,
  )
  return {
    user,
    onGuardarSpy,
    onCloseSpy,
    onEliminarPromoSpy,
    onRestaurarPromoSpy,
    onActualizarPrecioSpy,
    onCrearClienteSpy,
    onGuardarHorarioSpy,
  }
}

/** El botón inferior izquierdo: abre el cajón y cuenta lo cargado. */
const botonCarrito = () =>
  screen.getByRole('button', { name: /unidad|unidades|sin productos/i })

const botonConfirmar = () => screen.getByRole('button', { name: 'Confirmar' })

/** Elige el cliente por el buscador (mínimo 2 caracteres para que liste). */
async function elegirCliente(user: ReturnType<typeof userEvent.setup>, nombre: string) {
  await user.type(screen.getByPlaceholderText(/buscar por nombre/i), nombre)
  await user.click(await screen.findByRole('option', { name: new RegExp(nombre, 'i') }))
}

/** Filtra el catálogo y toca la fila del producto (el "+ Agregar" de la fila). */
async function agregarProducto(
  user: ReturnType<typeof userEvent.setup>,
  busqueda: string,
) {
  const buscador = screen.getByPlaceholderText(/buscar producto/i)
  await user.clear(buscador)
  await user.type(buscador, busqueda)
  await user.click(screen.getByText('+ Agregar'))
}

beforeEach(() => {
  estadoMock.montoMinimoPedido = 0
  estadoMock.bonificaciones = []
  estadoMock.minimosProducto = undefined
  estadoMock.violacionesMOQ = []
  estadoMock.faltantes = []
  estadoMock.faltantesBonificacion = []
  estadoMock.hayDescuentoTotal = false
  estadoMock.totalOriginal = 0
  estadoMock.totalConDescuentoCliente = 0
  estadoMock.preventistasAsignables = []
})

// ---------------------------------------------------------------------------

describe('ModalPedido — estado inicial', () => {
  it('abre con el catálogo cargado, el carrito vacío y el confirmar deshabilitado', () => {
    montar()

    expect(screen.getByRole('dialog', { name: 'Nuevo Pedido' })).toBeInTheDocument()
    expect(screen.getByText('Gaseosa Cola 2L')).toBeInTheDocument()
    expect(screen.getByText('Galletitas Surtidas')).toBeInTheDocument()
    expect(screen.queryByText('No se encontraron productos')).not.toBeInTheDocument()

    // Sin items: no hay carrito que abrir ni pedido que confirmar.
    expect(botonCarrito()).toHaveAccessibleName(/sin productos/i)
    expect(botonCarrito()).toBeDisabled()
    expect(botonConfirmar()).toBeDisabled()
  })

  it('lista el producto agotado con el motivo y no lo deja agregar', async () => {
    const { user } = montar()

    // Se ve —el vendedor tiene que poder distinguir "no existe" de "está
    // agotado"— pero la fila no agrega nada al tocarla.
    expect(screen.getByText('Agua sin Gas 500cc')).toBeInTheDocument()
    expect(screen.getByText('Sin stock')).toBeInTheDocument()
    expect(screen.getByText('No disponible')).toBeInTheDocument()

    await user.click(screen.getByText('Agua sin Gas 500cc'))

    expect(botonCarrito()).toHaveAccessibleName(/sin productos/i)
    expect(botonConfirmar()).toBeDisabled()
  })

  it('el carrusel de categorías filtra el catálogo y el buscador vacío lo dice', async () => {
    const { user } = montar()

    // Las flechas del carrusel sólo scrollean (no se pueden clickear en jsdom:
    // `Element.scrollBy` no existe), pero sus nombres accesibles son parte del
    // contrato: sin ellos el carrusel queda inoperable con teclado.
    expect(screen.getByRole('button', { name: 'Anterior categoría' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Siguiente categoría' })).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Bebidas' }))
    expect(screen.getByText('Gaseosa Cola 2L')).toBeInTheDocument()
    expect(screen.queryByText('Galletitas Surtidas')).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Todos' }))
    expect(screen.getByText('Galletitas Surtidas')).toBeInTheDocument()

    // Estado vacío en positivo: el cartel aparece, no se esconde el buscador.
    await user.type(screen.getByPlaceholderText(/buscar producto/i), 'zzz')
    expect(screen.getByText('No se encontraron productos')).toBeInTheDocument()
  })
})

describe('ModalPedido — camino feliz', () => {
  it('elige cliente, carga un producto, cambia la cantidad y confirma una sola vez', async () => {
    const { user, onGuardarSpy } = montar()

    await elegirCliente(user, 'Kiosco El Sol')
    // El cliente elegido reemplaza al buscador por su ficha.
    expect(screen.getByText('San Martin 100')).toBeInTheDocument()

    await agregarProducto(user, 'Gaseosa')
    expect(botonCarrito()).toHaveAccessibleName(/1 unidad/)
    expect(botonCarrito()).toBeEnabled()

    // El cajón del carrito: recién con él abierto se llega a la cantidad.
    await user.click(botonCarrito())
    expect(screen.getByRole('heading', { name: 'Productos en el pedido (1)' })).toBeInTheDocument()

    const cantidad = screen.getByRole('textbox', { name: 'Cantidad' })
    await user.clear(cantidad)
    await user.type(cantidad, '6')
    await user.keyboard('{Enter}')

    // El monto sale TRES veces a la vez y las tres tienen que seguir estando:
    // el subtotal de la línea, la fila "Total" del cajón y la barra de abajo,
    // que es la única que el preventista lee sin abrir el cajón.
    expect(botonCarrito()).toHaveAccessibleName(/6 unidades/)
    expect(screen.getAllByText(TOTAL_SEIS_UNIDADES)).toHaveLength(3)

    await user.click(botonConfirmar())

    expect(onGuardarSpy).toHaveBeenCalledTimes(1)
    expect(onGuardarSpy).toHaveBeenCalledWith(
      expect.objectContaining({
        clienteId: '10',
        items: [
          expect.objectContaining({ productoId: '1', cantidad: 6, precioUnitario: 1250 }),
        ],
        // Lo ÚNICO que el modal produce además de cliente e items: el
        // `tipo_factura_default` del cliente elegido, preseleccionado al
        // elegirlo (mig 116). Kiosco El Sol es 'FC'; un cliente sin default
        // entra como 'ZZ'.
        tipoFactura: 'FC',
      }),
    )
  })

  it('el toggle FC/ZZ del header arranca en el default del cliente y se puede pisar', async () => {
    const { user, onGuardarSpy } = montar()

    const toggle = screen.getByRole('combobox', { name: 'Tipo de factura' })
    expect(toggle).toHaveValue('ZZ')

    await elegirCliente(user, 'Kiosco El Sol')
    expect(toggle).toHaveValue('FC')

    // Pisable por pedido: el default del cliente es una preselección, no una regla.
    await user.selectOptions(toggle, 'ZZ')
    await agregarProducto(user, 'Gaseosa')
    await user.click(botonConfirmar())

    expect(onGuardarSpy).toHaveBeenCalledWith(
      expect.objectContaining({ tipoFactura: 'ZZ' }),
    )
  })

  it('la forma y el estado de pago viajan en el pedido, y "parcial" pide el monto', async () => {
    const { user, onGuardarSpy } = montar()

    await elegirCliente(user, 'Kiosco El Sol')
    await agregarProducto(user, 'Gaseosa')
    await user.click(botonCarrito())

    await user.selectOptions(screen.getByDisplayValue('Efectivo'), 'transferencia')
    await user.selectOptions(screen.getByDisplayValue('Pendiente'), 'parcial')

    // El bloque del monto parcial sólo existe con estadoPago === 'parcial'.
    expect(screen.getByText('Monto del pago parcial *')).toBeInTheDocument()
    await user.selectOptions(screen.getByDisplayValue('Parcial'), 'pagado')
    expect(screen.queryByText('Monto del pago parcial *')).not.toBeInTheDocument()

    await user.click(botonConfirmar())

    expect(onGuardarSpy).toHaveBeenCalledWith(
      expect.objectContaining({ formaPago: 'transferencia', estadoPago: 'pagado' }),
    )
  })

  it('el cajón del carrito se abre y se cierra desde el botón que cuenta las unidades', async () => {
    const { user } = montar()

    await agregarProducto(user, 'Gaseosa')
    expect(botonCarrito()).toHaveAttribute('aria-expanded', 'false')
    // Cerrado, el contenido del cajón queda tapado con aria-hidden: las queries
    // por rol no lo ven. Esto es lo que el rediseño a bottom sheet tiene que
    // seguir cumpliendo.
    expect(
      screen.queryByRole('heading', { name: /productos en el pedido/i }),
    ).not.toBeInTheDocument()

    await user.click(botonCarrito())
    expect(botonCarrito()).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByRole('heading', { name: 'Productos en el pedido (1)' })).toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Cantidad' })).toBeInTheDocument()

    await user.click(botonCarrito())
    expect(botonCarrito()).toHaveAttribute('aria-expanded', 'false')
    expect(
      screen.queryByRole('heading', { name: /productos en el pedido/i }),
    ).not.toBeInTheDocument()
  })

  it('los controles +, − y el tacho del item del carrito mueven la cantidad y lo borran', async () => {
    const { user } = montar()

    await agregarProducto(user, 'Gaseosa')
    await user.click(botonCarrito())

    // Con una sola unidad el − está apagado: el piso es 1 (o el mínimo de venta).
    expect(screen.getByRole('button', { name: '-' })).toBeDisabled()

    await user.click(screen.getByRole('button', { name: '+' }))
    expect(botonCarrito()).toHaveAccessibleName(/2 unidades/)
    expect(screen.getByRole('button', { name: '-' })).toBeEnabled()

    await user.click(screen.getByRole('button', { name: '-' }))
    expect(botonCarrito()).toHaveAccessibleName(/1 unidad/)

    // El tacho saca el producto de una, sin pasar por cantidad 0.
    await user.click(screen.getByRole('button', { name: 'Eliminar producto' }))
    expect(screen.getByText('El carrito está vacío. Agregá productos arriba.')).toBeInTheDocument()
    expect(botonCarrito()).toHaveAccessibleName(/sin productos/i)
    expect(botonConfirmar()).toBeDisabled()
  })

  it('cerrar avisa al padre y no guarda nada', async () => {
    const { user, onCloseSpy, onGuardarSpy } = montar()

    await elegirCliente(user, 'Kiosco El Sol')
    await agregarProducto(user, 'Gaseosa')
    await user.click(screen.getByRole('button', { name: 'Cerrar' }))

    expect(onCloseSpy).toHaveBeenCalledTimes(1)
    expect(onGuardarSpy).not.toHaveBeenCalled()
  })

  it('Escape cierra el modal', async () => {
    const { user, onCloseSpy, onGuardarSpy } = montar()

    await agregarProducto(user, 'Gaseosa')
    await user.keyboard('{Escape}')

    expect(onCloseSpy).toHaveBeenCalledTimes(1)
    expect(onGuardarSpy).not.toHaveBeenCalled()
  })

  it('el click afuera NO cierra: el carrito armado no se tira por un toque al costado', async () => {
    const { user, onCloseSpy } = montar({}, { permitirClickAfuera: true })

    await agregarProducto(user, 'Gaseosa')

    // Un toque en el fondo, afuera del diálogo. Va contra un nodo propio y no
    // contra `document.body` porque userEvent cachea por ELEMENTO el chequeo de
    // `pointer-events` y nunca lo invalida: el body ya quedó marcado como
    // `none` por los tests anteriores de este archivo (Radix se lo pone
    // mientras el modal está abierto) y la caché se lee aunque el chequeo esté
    // apagado.
    const fondo = document.body.appendChild(document.createElement('div'))
    await user.click(fondo)
    fondo.remove()

    // `ModalBase` cancela las tres modalidades de cierre por interacción externa
    // (`onPointerDownOutside`, `onFocusOutside`, `onInteractOutside`). Un bottom
    // sheet que cierre al tocar afuera tira el pedido a medio armar.
    expect(onCloseSpy).not.toHaveBeenCalled()
    expect(screen.getByRole('dialog', { name: 'Nuevo Pedido' })).toBeInTheDocument()
    expect(botonCarrito()).toHaveAccessibleName(/1 unidad/)
  })
})

describe('ModalPedido — guardas del confirmar', () => {
  it('sin items no deja confirmar aunque haya cliente elegido', async () => {
    const { user, onGuardarSpy } = montar()

    await elegirCliente(user, 'Kiosco El Sol')

    expect(botonConfirmar()).toBeDisabled()
    expect(onGuardarSpy).not.toHaveBeenCalled()
  })

  // BUG: el confirmar NO mira `clienteId`. Con el carrito cargado y sin cliente
  // el botón queda habilitado y `onGuardar` se dispara igual; lo único que frena
  // el alta es el `notify.warning('Seleccioná cliente y productos')` de
  // `handleGuardarPedido`, ya en el container. Todas las demás guardas (mínimo,
  // MOQ, stock, horario, preventista, guardando) sí apagan el botón. Se asevera
  // el comportamiento actual.
  it('sin cliente deja confirmar igual: la guarda vive en el container, no en el botón', async () => {
    const { user, onGuardarSpy } = montar()

    await agregarProducto(user, 'Gaseosa')

    expect(botonConfirmar()).toBeEnabled()
    await user.click(botonConfirmar())

    expect(onGuardarSpy).toHaveBeenCalledTimes(1)
    expect(onGuardarSpy).toHaveBeenCalledWith(expect.objectContaining({ clienteId: '' }))
  })

  it('con compra mínima sin alcanzar avisa cuánto falta y apaga el confirmar', async () => {
    estadoMock.montoMinimoPedido = 100000
    const { user, onGuardarSpy } = montar()

    await elegirCliente(user, 'Kiosco El Sol')
    await agregarProducto(user, 'Gaseosa')

    // El motivo está DOS veces en el DOM —dentro del cajón y en la barra
    // inferior—, pero con el cajón cerrado sólo una es alcanzable: la otra
    // queda tapada por el `aria-hidden` del cajón, y las queries por rol lo
    // respetan.
    const aviso = screen.getByRole('alert')
    expect(aviso).toHaveTextContent(
      'El pedido no alcanza la compra mínima de $100.000,00. Faltan $98.750,00.',
    )
    expect(botonCarrito()).toHaveAccessibleName(/1 unidad/)
    expect(botonConfirmar()).toBeDisabled()
    expect(onGuardarSpy).not.toHaveBeenCalled()
  })

  it('sin stock suficiente lista el faltante y apaga el confirmar', async () => {
    const { user, onGuardarSpy } = montar()

    await elegirCliente(user, 'Kiosco El Sol')
    // Galletitas tiene stock 3.
    await agregarProducto(user, 'Galletitas')
    await user.click(botonCarrito())

    const cantidad = screen.getByRole('textbox', { name: 'Cantidad' })
    await user.clear(cantidad)
    await user.type(cantidad, '8')
    await user.keyboard('{Enter}')

    expect(screen.getByText('Galletitas Surtidas: disponible 3, cargaste 8')).toBeInTheDocument()
    expect(
      screen.getByText('1 producto sin stock suficiente — revisá el carrito.'),
    ).toBeInTheDocument()
    expect(botonConfirmar()).toBeDisabled()
    expect(onGuardarSpy).not.toHaveBeenCalled()
  })

  it('el mínimo de venta entra ya cargado y el − no deja bajar del piso', async () => {
    // Mínimo 3 para la Gaseosa (mig 147). Sale del catálogo completo, no del
    // carrito: un producto todavía no agregado también muestra el badge.
    estadoMock.minimosProducto = new Map([['1', 3]])
    const { user } = montar()

    expect(screen.getByText('Min: 3')).toBeInTheDocument()

    await agregarProducto(user, 'Gaseosa')
    // Entra con 3, no con 1: el sistema conoce el mínimo y no lo hace tipear.
    expect(botonCarrito()).toHaveAccessibleName(/3 unidades/)

    await user.click(botonCarrito())
    expect(screen.getByText('Min: 3 uds')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: '-' })).toBeDisabled()
  })

  it('las violaciones de mínimo de venta listan el producto y apagan el confirmar', async () => {
    // Se inyecta la violación tal como la reporta `usePromocionPedido`, sin
    // `minimosProducto`, porque HOY NO HAY CAMINO DE UI QUE LA PRODUZCA: el
    // catálogo agrega ya con el mínimo y en el carrito tanto el − como el input
    // clampean contra ese mismo piso. El cartel sólo se ve con estado que viene
    // de otro lado (un pedido armado sin señal, o un mínimo que subió después).
    estadoMock.violacionesMOQ = [{ productoId: '1', cantidadActual: 1, cantidadMinima: 3 }]
    const { user, onGuardarSpy } = montar()

    await elegirCliente(user, 'Kiosco El Sol')
    await agregarProducto(user, 'Gaseosa')
    await user.click(botonCarrito())

    expect(
      screen.getByText('los siguientes productos no cumplen el mínimo de compra:'),
    ).toBeInTheDocument()
    expect(screen.getByText('Gaseosa Cola 2L: mínimo 3, cargaste 1')).toBeInTheDocument()
    expect(
      screen.getByText('1 producto no cumple el mínimo — revisá el carrito.'),
    ).toBeInTheDocument()
    expect(botonConfirmar()).toBeDisabled()
    expect(onGuardarSpy).not.toHaveBeenCalled()
  })

  it('el admin tiene que elegir a quién se le acredita la venta antes de confirmar', async () => {
    estadoMock.preventistasAsignables = [
      { id: 'u-1', nombre: 'Ana Admin' },
      { id: 'u-2', nombre: 'Beto Preventista' },
    ]
    const { user, onGuardarSpy } = montar({ isAdmin: true })

    await elegirCliente(user, 'Kiosco El Sol')
    await agregarProducto(user, 'Gaseosa')
    await user.click(botonCarrito())

    // Sin default silencioso a su propio nombre: la venta se atribuye a
    // `pedidos.usuario_id` y elegir mal carga a un vendedor lo que vendió otro.
    const selector = screen.getByDisplayValue('— Elegí quién vende —')
    expect(screen.getByRole('option', { name: 'Ana Admin (vos)' })).toBeInTheDocument()
    expect(
      screen.getByText('Elegí a quién se le acredita la venta (a vos o al preventista que la hizo).'),
    ).toBeInTheDocument()
    expect(botonConfirmar()).toBeDisabled()

    await user.selectOptions(selector, 'u-2')

    expect(botonConfirmar()).toBeEnabled()
    await user.click(botonConfirmar())
    expect(onGuardarSpy).toHaveBeenCalledWith(
      expect.objectContaining({ preventistaId: 'u-2' }),
    )
  })

  it('un cliente sin horario bloquea el pedido hasta cargarlo, sin salir del modal', async () => {
    const { user, onGuardarHorarioSpy } = montar()

    await elegirCliente(user, 'Feria La Banda')
    await agregarProducto(user, 'Gaseosa')

    expect(screen.getByText('Falta el horario de Feria La Banda')).toBeInTheDocument()
    expect(
      screen.getByText('Falta cargar el horario del cliente — subí para completarlo.'),
    ).toBeInTheDocument()
    expect(botonConfirmar()).toBeDisabled()

    await user.selectOptions(screen.getByRole('combobox', { name: 'Hora de apertura' }), '08:00')
    await user.selectOptions(screen.getByRole('combobox', { name: 'Hora de cierre' }), '18:00')
    await user.click(screen.getByRole('button', { name: 'Guardar horario' }))

    expect(onGuardarHorarioSpy).toHaveBeenCalledTimes(1)
    expect(onGuardarHorarioSpy).toHaveBeenCalledWith('12', {
      horarios_atencion: '08:00-18:00',
      dias_atencion: null,
    })
    // Guardado el horario, el bloque desaparece y el pedido se puede confirmar.
    expect(screen.queryByText('Falta el horario de Feria La Banda')).not.toBeInTheDocument()
    expect(botonConfirmar()).toBeEnabled()
  })

  it('mientras está guardando no se puede confirmar de nuevo', async () => {
    const { user, onGuardarSpy } = montar({ guardando: true })

    await elegirCliente(user, 'Kiosco El Sol')
    await agregarProducto(user, 'Gaseosa')

    // Sin este término del `disabled`, dos toques seguidos dan de alta el mismo
    // pedido dos veces.
    expect(botonConfirmar()).toBeDisabled()
    await user.click(botonConfirmar())
    expect(onGuardarSpy).not.toHaveBeenCalled()
  })
})

describe('ModalPedido — sin conexión', () => {
  it('avisa que el pedido se encola y no deja declarar el cobro', async () => {
    const { user } = montar({ isOffline: true })

    await elegirCliente(user, 'Kiosco El Sol')
    await agregarProducto(user, 'Gaseosa')

    expect(screen.getByRole('status')).toHaveTextContent(
      'Sin conexión — el pedido se guarda en el teléfono y se sincroniza solo cuando vuelva la señal.',
    )

    await user.click(botonCarrito())

    // Un "pagado" offline entraría impago igual (el replay no registra pagos) y
    // el chofer se lo cobraría de nuevo al cliente: se fuerza 'pendiente'.
    const estadoPago = screen.getByDisplayValue('Pendiente')
    expect(estadoPago).toBeDisabled()
    expect(
      screen.getByText('Sin conexión el cobro se registra después, desde la ficha del pedido.'),
    ).toBeInTheDocument()
    // El pedido igual se puede confirmar: offline no bloquea el alta.
    expect(botonConfirmar()).toBeEnabled()
  })
})

describe('ModalPedido — deuda previa del cliente', () => {
  it('avisa la deuda al elegir el cliente y NO bloquea el confirmar', async () => {
    const { user, onGuardarSpy } = montar({ puedeVerDeuda: true })

    await elegirCliente(user, 'Almacen Dona Rosa')

    // Decisión explícita: quien vende decide si igual le carga el pedido.
    expect(screen.getByRole('status')).toHaveTextContent(
      'Este cliente tiene una deuda previa de $ 12.345,00.',
    )

    await agregarProducto(user, 'Gaseosa')
    expect(botonConfirmar()).toBeEnabled()
    await user.click(botonConfirmar())
    expect(onGuardarSpy).toHaveBeenCalledTimes(1)
  })

  it('sin permiso para verla, la deuda no se muestra', async () => {
    const { user } = montar()

    await elegirCliente(user, 'Almacen Dona Rosa')

    expect(screen.queryByRole('status')).not.toBeInTheDocument()
    expect(screen.queryByText(/deuda previa/i)).not.toBeInTheDocument()
  })
})

describe('ModalPedido — precio editado a mano (admin)', () => {
  it('el admin pisa el precio del item desde el propio carrito y queda marcado "Manual"', async () => {
    const { user, onActualizarPrecioSpy } = montar({ isAdmin: true })

    await elegirCliente(user, 'Kiosco El Sol')
    await agregarProducto(user, 'Gaseosa')
    await user.click(botonCarrito())

    await user.click(screen.getByText(/1\.250,00 c\/u/))
    const input = screen.getByRole('spinbutton')
    await user.clear(input)
    await user.type(input, '1000')
    await user.keyboard('{Enter}')

    expect(onActualizarPrecioSpy).toHaveBeenCalledTimes(1)
    expect(onActualizarPrecioSpy).toHaveBeenCalledWith('1', 1000)
    expect(screen.getByText('Manual')).toBeInTheDocument()
    expect(screen.getByText(/1\.000,00 c\/u/)).toBeInTheDocument()
  })

  // BUG: el input de precio maneja Escape para cancelar la edición, pero no
  // detiene la propagación. El keydown sigue hasta el listener de documento de
  // Radix y cierra el modal ENTERO — con el carrito armado adentro. El único
  // camino de cancelación que no pierde el pedido es hacer click afuera del
  // input (blur), y ése CONFIRMA el precio en vez de descartarlo.
  it('Escape mientras se edita el precio se lleva puesto el modal entero', async () => {
    const { user, onCloseSpy, onActualizarPrecioSpy } = montar({ isAdmin: true })

    await agregarProducto(user, 'Gaseosa')
    await user.click(botonCarrito())
    await user.click(screen.getByText(/1\.250,00 c\/u/))
    await user.keyboard('{Escape}')

    expect(onActualizarPrecioSpy).not.toHaveBeenCalled()
    expect(onCloseSpy).toHaveBeenCalledTimes(1)
  })

  it('sin ser admin el precio no es editable', async () => {
    const { user } = montar()

    await agregarProducto(user, 'Gaseosa')
    await user.click(botonCarrito())
    await user.click(screen.getByText(/1\.250,00 c\/u/))

    expect(screen.queryByRole('spinbutton')).not.toBeInTheDocument()
  })
})

describe('ModalPedido — promociones del pedido', () => {
  it('quitar una promo pide confirmación dentro del modal y recién ahí avisa al padre', async () => {
    estadoMock.bonificaciones = [
      {
        productoId: '2',
        promoId: 'promo-1',
        promoNombre: 'Segunda unidad gratis',
        cantidadBonificacion: 1,
        descripcionRegalo: '1 paquete Galletitas Surtidas',
      },
    ]
    const { user, onEliminarPromoSpy } = montar({ isAdmin: true })

    await elegirCliente(user, 'Kiosco El Sol')
    await agregarProducto(user, 'Gaseosa')
    await user.click(botonCarrito())

    expect(screen.getByText('1 paquete Galletitas Surtidas')).toBeInTheDocument()
    expect(screen.getByText('GRATIS')).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Quitar promoción' }))

    // La confirmación se renderiza DENTRO del modal: como hermano quedaría
    // detrás del overlay de Radix y la quita fallaría en silencio.
    const confirmacion = screen.getByRole('dialog', { name: 'Quitar promoción' })
    expect(
      within(confirmacion).getByText(
        '¿Quitar la promoción "Segunda unidad gratis" de este pedido? El cliente no recibirá la bonificación.',
      ),
    ).toBeInTheDocument()
    expect(onEliminarPromoSpy).not.toHaveBeenCalled()

    await user.click(within(confirmacion).getByRole('button', { name: 'Confirmar' }))

    expect(onEliminarPromoSpy).toHaveBeenCalledTimes(1)
    expect(onEliminarPromoSpy).toHaveBeenCalledWith('promo-1', 'Segunda unidad gratis')
    expect(screen.queryByRole('dialog', { name: 'Quitar promoción' })).not.toBeInTheDocument()
  })

  it('la promo quitada queda listada con su botón de restaurar', async () => {
    const { user, onRestaurarPromoSpy } = montar({
      isAdmin: true,
      promosEliminadas: [{ promoId: 'promo-1', promoNombre: 'Segunda unidad gratis' }],
    })

    await agregarProducto(user, 'Gaseosa')
    await user.click(botonCarrito())

    expect(screen.getByText(/Promoción quitada:/)).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Restaurar' }))

    expect(onRestaurarPromoSpy).toHaveBeenCalledTimes(1)
    expect(onRestaurarPromoSpy).toHaveBeenCalledWith('promo-1')
  })
})

describe('ModalPedido — nudges y descuento del cliente', () => {
  it('muestra cuánto falta para el precio mayorista y para la bonificación', async () => {
    estadoMock.faltantes = [
      { grupoNombre: 'Gaseosas 2L', faltante: 4, precioTier: 1100, etiqueta: 'Mayorista' },
    ]
    estadoMock.faltantesBonificacion = [
      { productoId: '1', promoNombre: 'Lleve 6 pague 5', faltante: 2, bonificacion: 1 },
    ]
    const { user } = montar()

    await agregarProducto(user, 'Gaseosa')
    await user.click(botonCarrito())

    expect(screen.getByText(/Agrega 4 mas de/)).toBeInTheDocument()
    expect(screen.getByText(/para precio Mayorista/)).toBeInTheDocument()
    expect(screen.getByText(/y te llevas 1 gratis!/)).toBeInTheDocument()
  })

  it('con descuento del cliente el total va tachado y dice el ahorro', async () => {
    estadoMock.hayDescuentoTotal = true
    estadoMock.totalOriginal = 1250
    estadoMock.totalConDescuentoCliente = 1000
    const { user } = montar()

    await agregarProducto(user, 'Gaseosa')
    await user.click(botonCarrito())

    expect(screen.getByText('Ahorro: $ 250,00')).toBeInTheDocument()
    // El total con descuento es el que se muestra en la fila Total y en la
    // barra del carrito: es el número que el preventista le canta al cliente.
    expect(screen.getAllByText('$ 1.000,00')).toHaveLength(2)
    expect(botonCarrito()).toHaveAccessibleName(/1 unidad/)
  })
})

describe('ModalPedido — alta rápida de cliente', () => {
  it('exige los campos obligatorios y al crearlo lo deja elegido en el pedido', async () => {
    const { user, onCrearClienteSpy } = montar({ isAdmin: true })

    await user.click(screen.getByRole('button', { name: '+ Nuevo' }))

    // Sin nada cargado: dice CUÁLES faltan, no un "campos incompletos" genérico.
    await user.click(screen.getByRole('button', { name: 'Crear y seleccionar' }))
    expect(
      screen.getByText('Completá: Nombre fantasía, Nombre completo, Dirección'),
    ).toBeInTheDocument()
    expect(onCrearClienteSpy).not.toHaveBeenCalled()

    await user.type(screen.getByPlaceholderText('Nombre fantasia *'), 'Despensa Nueva')
    await user.type(screen.getByPlaceholderText('Nombre completo *'), 'Nueva SRL')
    // Sin API key de Google el autocomplete degrada a un input común, y lo dice.
    expect(
      screen.getByText('Autocompletado no disponible. Escribí la dirección manualmente.'),
    ).toBeInTheDocument()
    await user.type(screen.getByPlaceholderText('Escribí la dirección...'), 'Avellaneda 55')
    await user.selectOptions(screen.getByRole('combobox', { name: 'Hora de apertura' }), '09:00')
    await user.selectOptions(screen.getByRole('combobox', { name: 'Hora de cierre' }), '13:00')

    await user.click(screen.getByRole('button', { name: 'Crear y seleccionar' }))

    expect(onCrearClienteSpy).toHaveBeenCalledTimes(1)
    expect(onCrearClienteSpy).toHaveBeenCalledWith(
      expect.objectContaining({
        nombreFantasia: 'Despensa Nueva',
        nombre: 'Nueva SRL',
        // El "Nombre completo" se usa como razón social (la DB la exige).
        razonSocial: 'Nueva SRL',
        direccion: 'Avellaneda 55',
        horariosAtencion: '09:00-13:00',
      }),
    )
    // El formulario se cierra solo y el cliente recién creado queda elegido.
    expect(screen.getByRole('button', { name: '+ Nuevo' })).toBeInTheDocument()
    expect(screen.getByText('Despensa Nueva')).toBeInTheDocument()
    expect(screen.getByText('Avellaneda 55')).toBeInTheDocument()
  })
})
