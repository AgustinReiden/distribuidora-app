/**
 * Lo que protege esto: el replay de sesión de Sentry graba un video del DOM.
 * `maskAllText: false` mandaba a Sentry la razón social, dirección, teléfono
 * y saldos de los clientes de cada pantalla, en el 10% de las sesiones y el
 * 100% de las que tienen error. Y `beforeSend` sólo redactaba breadcrumbs en
 * su primer nivel: un objeto anidado (`{ cliente: { direccion } }`) pasaba
 * entero.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

interface ReplayConfig {
  maskAllText?: boolean
  maskAllInputs?: boolean
  unmask?: string[]
  beforeAddRecordingEvent?: (frame: ReplayFrame) => ReplayFrame
}

interface ReplayFrame {
  type: number
  timestamp: number
  data: { tag: string; payload: Record<string, unknown> }
}

interface BreadcrumbData {
  [key: string]: unknown
}

interface EventoDePrueba {
  message?: string
  breadcrumbs?: Array<{ category?: string; message?: string; data?: BreadcrumbData }>
  exception?: { values: Array<{ type: string; value: string }> }
  extra?: Record<string, unknown>
  spans?: Array<{ description?: string; data?: Record<string, unknown> }>
  transaction?: string
}

interface SentryInitConfig {
  beforeSend: (event: EventoDePrueba, hint?: { originalException?: unknown }) => EventoDePrueba
  beforeSendTransaction: (event: EventoDePrueba) => EventoDePrueba | null
}

const initMock = vi.fn()
const replayIntegrationMock = vi.fn((config: ReplayConfig) => config)
const browserTracingIntegrationMock = vi.fn(() => ({}))
const feedbackIntegrationMock = vi.fn(() => ({}))

vi.mock('@sentry/react', () => ({
  init: (config: SentryInitConfig) => initMock(config),
  replayIntegration: (config: ReplayConfig) => replayIntegrationMock(config),
  browserTracingIntegration: () => browserTracingIntegrationMock(),
  feedbackIntegration: () => feedbackIntegrationMock(),
  captureException: vi.fn(),
  captureMessage: vi.fn(),
  setUser: vi.fn(),
  addBreadcrumb: vi.fn(),
  startSpan: vi.fn((_opts: unknown, fn: () => unknown) => fn()),
  withScope: vi.fn(),
  ErrorBoundary: () => null
}))

describe('initSentry', () => {
  beforeEach(() => {
    vi.resetModules()
    vi.stubEnv('VITE_SENTRY_DSN', 'https://public@sentry.example/1')
    vi.stubEnv('PROD', true)
  })

  afterEach(() => {
    vi.unstubAllEnvs()
    vi.clearAllMocks()
  })

  it('enmascara todo el texto del replay de sesión', async () => {
    const { initSentry } = await import('./sentry')
    initSentry()

    expect(replayIntegrationMock).toHaveBeenCalledTimes(1)
    const config = replayIntegrationMock.mock.calls[0][0]
    expect(config.maskAllText).toBe(true)
    expect(config.maskAllInputs).toBe(true)
    expect(config.unmask).toEqual(['.sentry-unmask'])
  })

  it('redacta recursivamente los datos sensibles anidados de un breadcrumb', async () => {
    const { initSentry } = await import('./sentry')
    initSentry()

    const initConfig = initMock.mock.calls[0][0] as SentryInitConfig
    const event = {
      breadcrumbs: [
        {
          data: {
            monto: 500,
            cliente: {
              nombre: 'Distribuidora Ejemplo SRL',
              direccion: 'Calle Falsa 123',
              telefono: '3811234567'
            }
          }
        }
      ]
    }

    const result = initConfig.beforeSend(event)
    const data = result.breadcrumbs?.[0]?.data as BreadcrumbData & { cliente: BreadcrumbData }

    expect(data.cliente.nombre).toBe('[REDACTED]')
    expect(data.cliente.direccion).toBe('[REDACTED]')
    expect(data.cliente.telefono).toBe('[REDACTED]')
    expect(data.monto).toBe(500)
  })

  /**
   * #1266: la búsqueda de pedidos manda el nombre o el CUIT tipeado en
   * `clientes.or=(…ilike…)`, y esa URL viajaba entera en el breadcrumb de fetch
   * de cualquier evento posterior.
   */
  describe('URLs y mensajes con datos de clientes', () => {
    /** La URL tal cual la arma supabase-js (URLSearchParams) para `construirFiltrosPedidos`. */
    function urlDeBusqueda(termino: string): string {
      const url = new URL('https://abc.supabase.co/rest/v1/pedidos')
      url.searchParams.append('select', 'id,total,cliente:clientes!inner(nombre_fantasia)')
      url.searchParams.append('estado', 'eq.pendiente')
      url.searchParams.append(
        'clientes.or',
        `(nombre_fantasia.ilike.%${termino}%,razon_social.ilike.%${termino}%,cuit.ilike.%${termino}%,direccion.ilike.%${termino}%)`,
      )
      url.searchParams.append('limit', '50')
      return url.toString()
    }

    async function configDeInit(): Promise<SentryInitConfig> {
      const { initSentry } = await import('./sentry')
      initSentry()
      return initMock.mock.calls[0][0] as SentryInitConfig
    }

    it('saca el CUIT buscado de la URL del breadcrumb de fetch y deja lo demás', async () => {
      const config = await configDeInit()
      const url = urlDeBusqueda('20-12345678-9')

      const result = config.beforeSend({
        breadcrumbs: [{ category: 'fetch', data: { method: 'GET', url, status_code: 200 } }],
      })
      const redactada = result.breadcrumbs?.[0]?.data?.url as string

      expect(decodeURIComponent(redactada)).not.toContain('12345678')
      expect(redactada).toContain('clientes.or=[REDACTED]')
      expect(redactada).toContain('estado=eq.pendiente')
      expect(redactada).toContain('limit=50')
      expect(redactada.startsWith('https://abc.supabase.co/rest/v1/pedidos?select=')).toBe(true)
    })

    it('saca el nombre buscado aunque no tenga números', async () => {
      const config = await configDeInit()

      const result = config.beforeSend({
        breadcrumbs: [{ category: 'xhr', data: { url: urlDeBusqueda('Almacén Don Pepe') } }],
      })

      expect(decodeURIComponent(String(result.breadcrumbs?.[0]?.data?.url))).not.toMatch(/Pepe/)
    })

    it('tapa el mensaje de un RechazoDeNegocioError y deja el código', async () => {
      const config = await configDeInit()
      const { RechazoDeNegocioError } = await import('../utils/rechazoDeNegocio')
      const err = new RechazoDeNegocioError('El cliente Almacén Don Pepe supera su límite', 'limite_credito')

      const result = config.beforeSend(
        { exception: { values: [{ type: 'RechazoDeNegocioError', value: err.message }] } },
        { originalException: err },
      )

      expect(result.exception?.values[0].value).not.toMatch(/Pepe/)
      expect(result.exception?.values[0].value).toContain('limite_credito')
    })

    it('redacta el texto de logger.error(string) y lo que va en extra', async () => {
      const config = await configDeInit()

      const result = config.beforeSend({
        message: 'Pedido de 20-12345678-9 (juan@example.com) sin sincronizar',
        extra: { message: 'Cliente 20345678901', detalle: { url: urlDeBusqueda('Pepe') } },
      })

      expect(result.message).not.toMatch(/12345678|juan@example\.com/)
      expect(String(result.extra?.message)).not.toContain('20345678901')
      expect(decodeURIComponent(JSON.stringify(result.extra))).not.toMatch(/Pepe/)
    })

    it('redacta la URL de los spans de fetch en las transacciones', async () => {
      const config = await configDeInit()
      const url = urlDeBusqueda('20-12345678-9')

      const result = config.beforeSendTransaction({
        transaction: '/pedidos',
        spans: [{ description: 'GET https://abc.supabase.co/rest/v1/pedidos', data: { url, 'http.query': url.slice(url.indexOf('?')) } }],
      })

      expect(decodeURIComponent(JSON.stringify(result?.spans))).not.toContain('12345678')
    })

    it('redacta la URL que graba el Replay como request', async () => {
      const { initSentry } = await import('./sentry')
      initSentry()
      const replay = replayIntegrationMock.mock.calls[0][0]
      const url = urlDeBusqueda('20-12345678-9')

      expect(typeof replay.beforeAddRecordingEvent).toBe('function')
      const frame = replay.beforeAddRecordingEvent!({
        type: 5,
        timestamp: 0,
        data: { tag: 'performanceSpan', payload: { op: 'resource.fetch', description: url, data: { method: 'GET' } } },
      })

      const descripcion = decodeURIComponent(String(frame.data.payload.description))
      expect(descripcion).toContain('https://abc.supabase.co/rest/v1/pedidos?')
      expect(descripcion).not.toContain('12345678')
    })
  })
})
