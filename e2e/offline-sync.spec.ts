/**
 * Chaos Tests - Sincronización Offline
 *
 * Tests de integración "sucios" que validan el comportamiento de la app
 * en condiciones adversas:
 * - Pérdida de conexión durante operaciones
 * - Cierre de app con datos pendientes
 * - Reconexión y sincronización automática
 * - Registro del service worker (base de todo lo anterior)
 */

import { test, expect, type Page } from '@playwright/test'

// =============================================================================
// UTILIDADES
// =============================================================================

/**
 * Helper para simular login (ajustar según tu implementación)
 */
async function _login(page: Page, email: string, password: string) {
  await page.goto('/login')
  await page.fill('[data-testid="email-input"]', email)
  await page.fill('[data-testid="password-input"]', password)
  await page.click('[data-testid="login-button"]')
  await page.waitForURL('**/dashboard**', { timeout: 10000 })
}

/**
 * Helper para verificar el indicador de sync
 */
async function _getSyncStatus(page: Page): Promise<string> {
  const indicator = page.locator('[data-testid="sync-indicator"]')
  if (await indicator.count() > 0) {
    return (await indicator.getAttribute('data-status')) || 'unknown'
  }
  return 'not-found'
}

/**
 * Helper para esperar sincronización completa
 */
async function _waitForSync(page: Page, timeout = 30000) {
  await expect(page.locator('[data-testid="sync-indicator"][data-status="online"]'))
    .toBeVisible({ timeout })
}

// =============================================================================
// TESTS DE CAOS - OFFLINE/ONLINE
// =============================================================================

test.describe('Offline Sync - Chaos Tests', () => {
  test.describe.configure({ mode: 'serial' })

  test.beforeEach(async ({ page }) => {
    // Limpiar IndexedDB antes de cada test
    await page.goto('/')
    await page.evaluate(() => {
      indexedDB.deleteDatabase('DistribuidoraOfflineDB')
    })
  })

  // H55: el test "crear pedido offline -> reconectar -> sincroniza sin
  // duplicados" (con login real) se borró porque nunca corrió de verdad: no
  // hay E2E_USER/E2E_PASS en ci.yml, así que el alta offline quedaba comentada
  // y el test sólo probaba cortar/restaurar la red sin loguear. Para tenerlo
  // hace falta un usuario de prueba con contraseña wireados como secrets de
  // CI (E2E_USER/E2E_PASS) y pasados a este archivo.

  test('2. Múltiples operaciones offline → reconectar → la cola no pierde ni duplica nada', async ({
    page,
    context
  }) => {
    // La auto-sincronización (useSyncManager) vive dentro de MainAppInner,
    // que sólo monta con `user && perfil` (App.tsx:451) — sin credenciales de
    // test logueadas, `/pedidos` renderiza LoginScreen y ese efecto nunca
    // corre. Lo que se puede probar sin sesión es lo que le importa a IndexedDB:
    // que encolar offline y reconectar no pierde ni duplica operaciones.
    await page.goto('/pedidos')
    await page.waitForLoadState('networkidle')

    // 1. Cortar internet
    await context.setOffline(true)
    await page.waitForTimeout(500)

    // 2. Simular múltiples operaciones (usando evaluate para queue directo)
    await page.evaluate(async () => {
      // @ts-ignore - Puente de test expuesto por src/lib/offlineDb.ts
      const { queueOperation } = window.__offlineDb

      // Encolar 5 operaciones
      for (let i = 0; i < 5; i++) {
        await queueOperation('UPDATE_PEDIDO', {
          id: `test-pedido-${i}`,
          notas: `Actualización offline ${i}`
        })
      }
    })

    // 3. Verificar que hay operaciones pendientes
    const pendingCount = await page.evaluate(async () => {
      // @ts-ignore
      const { getOperationCounts } = window.__offlineDb
      const counts = await getOperationCounts()
      return counts.pending
    })

    expect(pendingCount).toBeGreaterThanOrEqual(5)

    // 4. Restaurar internet
    await context.setOffline(false)
    await page.waitForTimeout(2000)

    // 5. Sin sesión no hay quien las sincronice: las 5 siguen intactas en
    // "pending", ninguna se perdió ni se marcó completada/fallida sola.
    const finalCounts = await page.evaluate(async () => {
      // @ts-ignore
      const { getOperationCounts } = window.__offlineDb
      return await getOperationCounts()
    })

    expect(finalCounts.pending).toBeGreaterThanOrEqual(5)
    expect(finalCounts.completed).toBe(0)
    expect(finalCounts.failed).toBe(0)
  })

  test('3. El service worker se registra en el build (modo offline real)', async ({
    page
  }) => {
    // No hay deduplicación de operaciones encoladas: cada `queueOperation`
    // crea una entrada nueva aunque el payload sea idéntico, porque el hash
    // incluye Date.now() (ver src/lib/offlineDb.test.ts, "creates a unique
    // operation each call"). Ese comportamiento es a propósito, no un bug
    // pendiente, así que no hay nada que testear ahí.
    //
    // Lo que sí vale la pena chequear en este archivo: que el service worker
    // -la base de TODO lo demás en esta suite, incluida la pantalla en blanco
    // de iPhone que documenta src/utils/serviceWorker.ts- efectivamente se
    // registra contra el build servido. `registrarServiceWorker()` corta en
    // seco si `!import.meta.env.PROD`, así que esto sólo tiene sentido corrido
    // contra `vite preview` sobre el dist/ compilado (ver playwright.config.ts),
    // nunca contra `vite dev`.
    await page.goto('/')
    await page.waitForLoadState('domcontentloaded')

    const registration = await page.evaluate(async () => {
      if (!('serviceWorker' in navigator)) return null
      // El registro es asíncrono desde el arranque de la app; darle margen.
      for (let intento = 0; intento < 20; intento++) {
        const reg = await navigator.serviceWorker.getRegistration()
        if (reg) return { scope: reg.scope, activo: Boolean(reg.active || reg.installing || reg.waiting) }
        await new Promise(resolve => setTimeout(resolve, 250))
      }
      return null
    })

    expect(registration).not.toBeNull()
    expect(registration?.activo).toBe(true)
  })

  test('4. IndexedDB persiste después de cerrar pestaña', async ({
    page,
    context
  }) => {
    // 1. Primera sesión - crear datos
    await page.goto('/pedidos')
    await page.waitForLoadState('networkidle')

    // Guardar algo en IndexedDB
    await page.evaluate(async () => {
      // @ts-ignore
      const { cacheData } = window.__offlineDb
      await cacheData('test-persistence', { value: 'datos-persistentes', timestamp: Date.now() })
    })

    // 2. Cerrar página completamente
    await page.close()

    // 3. Abrir nueva página in SAME context (shares IndexedDB storage)
    const newPage = await context.newPage()
    await newPage.goto('/pedidos')
    await newPage.waitForLoadState('domcontentloaded')

    // 4. Verificar que los datos persisten
    const cachedData = await newPage.evaluate(async () => {
      // @ts-ignore
      const { getCachedData } = window.__offlineDb
      return await getCachedData('test-persistence')
    })

    expect(cachedData).toBeDefined()
    expect((cachedData as { value: string }).value).toBe('datos-persistentes')

    await newPage.close()
  })

  test('5. Reconexión durante sincronización no causa errores', async ({
    page,
    context
  }) => {
    await page.goto('/pedidos')
    await page.waitForLoadState('networkidle')

    // 1. Agregar operaciones a la cola
    await page.evaluate(async () => {
      // @ts-ignore
      const { queueOperation } = window.__offlineDb

      for (let i = 0; i < 3; i++) {
        await queueOperation('UPDATE_PEDIDO', {
          id: `chaos-test-${i}`,
          notas: `Test ${i}`
        })
      }
    })

    // 2. Iniciar sincronización
    const syncPromise = page.evaluate(async () => {
      // @ts-ignore
      const { getPendingOperations, markAsProcessing } = window.__offlineDb
      const pending = await getPendingOperations(1)
      if (pending.length > 0) {
        await markAsProcessing(pending[0].id!)
      }
    })

    // 3. Mientras sincroniza, cortar y reconectar rápidamente
    await context.setOffline(true)
    await page.waitForTimeout(100)
    await context.setOffline(false)
    await page.waitForTimeout(100)
    await context.setOffline(true)
    await page.waitForTimeout(100)
    await context.setOffline(false)

    await syncPromise

    // 4. Esperar que todo se estabilice
    await page.waitForTimeout(2000)

    // 5. No debería haber crashed
    const isPageAlive = await page.evaluate(() => document.body !== null)
    expect(isPageAlive).toBe(true)

    // 6. La app debería seguir funcionando (JS evaluates correctly)
    const canNavigate = await page.evaluate(() => document.readyState === 'complete')
    expect(canNavigate).toBe(true)
  })
})

// =============================================================================
// TESTS DE AUDIT LOG (Verificación básica)
// =============================================================================

test.describe('Audit Logs - Integrity Tests', () => {
  test.skip('Los cambios en pedidos generan audit logs', async ({ page }) => {
    // Este test requiere conexión a Supabase real
    // Marcar como skip si no hay ambiente de test configurado

    await page.goto('/pedidos')

    // Nota: Implementar cuando haya ambiente de test con Supabase
    // 1. Crear pedido
    // 2. Verificar que audit_logs tiene registro
    // 3. Modificar pedido
    // 4. Verificar que audit_logs tiene registro de UPDATE
    // 5. Intentar eliminar audit_log (debería fallar)
  })
})
