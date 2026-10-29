/**
 * #1264: `window.__offlineDb` es el puente de los E2E de Playwright, y trae
 * `clearAllData` y `discardFailedOperations`. En producción quedaba expuesto:
 * cualquier script de la página (o alguien con la consola abierta en un
 * teléfono prestado) podía vaciar la cola offline sin pasar por la app.
 *
 * Sólo se expone en el dev server y en el build que el job e2e de CI arma con
 * `VITE_E2E_BRIDGE=true`.
 */
import { describe, it, expect, afterEach, vi } from 'vitest'

type VentanaConPuente = Window & { __offlineDb?: Record<string, unknown> }

async function importarFresco(): Promise<void> {
  delete (window as VentanaConPuente).__offlineDb
  vi.resetModules()
  const modulo = await import('./offlineDb')
  // Cada import fresco abre su propia conexión a la misma base.
  modulo.db.close()
}

describe('offlineDb — puente de E2E', () => {
  afterEach(() => {
    vi.unstubAllEnvs()
    delete (window as VentanaConPuente).__offlineDb
  })

  it('en producción no expone window.__offlineDb', async () => {
    vi.stubEnv('DEV', false)
    vi.stubEnv('PROD', true)
    vi.stubEnv('VITE_E2E_BRIDGE', undefined)

    await importarFresco()

    expect((window as VentanaConPuente).__offlineDb).toBeUndefined()
  })

  it('en el build de E2E sí lo expone', async () => {
    vi.stubEnv('DEV', false)
    vi.stubEnv('PROD', true)
    vi.stubEnv('VITE_E2E_BRIDGE', 'true')

    await importarFresco()

    expect((window as VentanaConPuente).__offlineDb?.queueOperation).toBeTypeOf('function')
  })

  it('en el dev server sí lo expone', async () => {
    vi.stubEnv('DEV', true)
    vi.stubEnv('PROD', false)

    await importarFresco()

    expect((window as VentanaConPuente).__offlineDb?.getOperationCounts).toBeTypeOf('function')
  })
})
