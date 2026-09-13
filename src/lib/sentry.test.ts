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
}

interface BreadcrumbData {
  [key: string]: unknown
}

interface SentryInitConfig {
  beforeSend: (event: { breadcrumbs?: Array<{ data?: BreadcrumbData }> }) => {
    breadcrumbs?: Array<{ data?: BreadcrumbData }>
  }
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
})
