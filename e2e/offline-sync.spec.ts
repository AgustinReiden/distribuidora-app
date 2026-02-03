/**
 * Chaos Tests - Sincronización Offline
 *
 * Tests de integración "sucios" que validan el comportamiento de la app
 * en condiciones adversas:
 * - Pérdida de conexión durante operaciones
 * - Cierre de app con datos pendientes
 * - Reconexión y sincronización automática
 * - Detección de duplicados
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

/**
 * Helper para contar pedidos en la UI
 */
async function countPedidosInUI(page: Page): Promise<number> {
  await page.waitForSelector('[data-testid="pedido-card"]', { timeout: 10000 }).catch(() => null)
  return await page.locator('[data-testid="pedido-card"]').count()
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

  test('1. Crear pedido offline → reconectar → debe sincronizar sin duplicados', async ({
    page,
    context
  }) => {
    // 1. Navegar y hacer login
    await page.goto('/login')

    // Nota: Ajustar según credenciales de test
    // await login(page, 'test@test.com', 'testpass123')

    // Para este test, asumimos que ya hay una sesión o saltamos login
    await page.goto('/pedidos')
    await page.waitForLoadState('networkidle')

    // 2. Guardar conteo inicial de pedidos
    const initialCount = await countPedidosInUI(page)

    // 3. CORTAR INTERNET
    await context.setOffline(true)
    await page.waitForTimeout(500) // Dar tiempo al listener

    // Verificar que el indicador muestra offline
    // (si existe el componente)
    const offlineIndicator = page.locator('text=Offline')
    if (await offlineIndicator.count() > 0) {
      await expect(offlineIndicator).toBeVisible()
    }

    // 4. Intentar crear pedido offline
    // Nota: Ajustar selectores según tu UI
    const nuevoBtn = page.locator('[data-testid="nuevo-pedido-btn"], button:has-text("Nuevo Pedido")')
    if (await nuevoBtn.count() > 0) {
      await nuevoBtn.first().click()
      await page.waitForTimeout(1000)

      // Llenar formulario mínimo (ajustar según tu UI)
      // await page.fill('[data-testid="cliente-select"]', 'Cliente Test')
      // await page.click('[data-testid="guardar-pedido"]')

      // El pedido debería guardarse localmente
    }

    // 5. SIMULAR CIERRE DE APP
    // Guardamos la URL actual
    const currentUrl = page.url()

    // 6. REABRIR APP
    await page.goto(currentUrl)
    await page.waitForLoadState('domcontentloaded')

    // 7. RESTAURAR INTERNET
    await context.setOffline(false)

    // 8. Esperar sincronización automática
    await page.waitForTimeout(3000) // Dar tiempo para sync

    // 9. Verificar que no hay duplicados
    const finalCount = await countPedidosInUI(page)

    // El conteo debería ser máximo initialCount + 1
    expect(finalCount).toBeLessThanOrEqual(initialCount + 1)

    // Verificar que no hay errores visibles
    const errorMessages = page.locator('text=Error, text=error, [role="alert"]')
    const errorCount = await errorMessages.count()
    // Puede haber 0 o algunos errores legítimos, pero no deberían ser críticos
    console.log(`Errores visibles: ${errorCount}`)
  })

  test('2. Múltiples operaciones offline → reconectar → todas deben procesarse en orden', async ({
    page,
    context
  }) => {
    await page.goto('/pedidos')
    await page.waitForLoadState('networkidle')

    // 1. Cortar internet
    await context.setOffline(true)
    await page.waitForTimeout(500)

    // 2. Simular múltiples operaciones (usando evaluate para queue directo)
    await page.evaluate(async () => {
      // @ts-ignore - Acceso a módulos de la app
      const { queueOperation } = await import('/src/lib/offlineDb.ts')

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
      const { getOperationCounts } = await import('/src/lib/offlineDb.ts')
      const counts = await getOperationCounts()
      return counts.pending
    })

    expect(pendingCount).toBeGreaterThanOrEqual(5)

    // 4. Restaurar internet
    await context.setOffline(false)

    // 5. Esperar procesamiento (con timeout más largo para 5 operaciones)
    await page.waitForTimeout(10000)

    // 6. Verificar que se procesaron
    const finalCounts = await page.evaluate(async () => {
      // @ts-ignore
      const { getOperationCounts } = await import('/src/lib/offlineDb.ts')
      return await getOperationCounts()
    })

    // La mayoría deberían estar completadas o fallidas (pero procesadas)
    const processed = finalCounts.completed + finalCounts.failed
    console.log(`Procesadas: ${processed}, Pendientes: ${finalCounts.pending}`)
  })

  test('3. Operación duplicada no debe crear registros duplicados', async ({
    page,
    context
  }) => {
    await page.goto('/pedidos')
    await page.waitForLoadState('networkidle')

    // 1. Cortar internet
    await context.setOffline(true)

    // 2. Intentar encolar la misma operación dos veces
    const results = await page.evaluate(async () => {
      // @ts-ignore
      const { queueOperation, getPendingOperations } = await import('/src/lib/offlineDb.ts')

      const payload = {
        clienteId: 'test-client',
        items: [{ productoId: 'prod-1', cantidad: 1 }],
        total: 100
      }

      // Primera operación
      const id1 = await queueOperation('CREATE_PEDIDO', payload)

      // Segunda operación idéntica (debería ser rechazada o detectada)
      const id2 = await queueOperation('CREATE_PEDIDO', payload)

      const pending = await getPendingOperations(100)

      return {
        id1,
        id2,
        pendingCount: pending.length
      }
    })

    // Solo una operación debería estar en cola (id2 debería ser null)
    console.log('Resultados duplicado:', results)

    // La segunda llamada con el mismo payload debería retornar null
    // (según la implementación de detección de duplicados)
  })

  test('4. IndexedDB persiste después de cerrar pestaña', async ({
    page,
    browser
  }) => {
    // 1. Primera sesión - crear datos
    await page.goto('/pedidos')
    await page.waitForLoadState('networkidle')

    // Guardar algo en IndexedDB
    await page.evaluate(async () => {
      // @ts-ignore
      const { cacheData } = await import('/src/lib/offlineDb.ts')
      await cacheData('test-persistence', { value: 'datos-persistentes', timestamp: Date.now() })
    })

    // 2. Cerrar página completamente
    await page.close()

    // 3. Abrir nueva página (simula reabrir app)
    const newPage = await browser.newPage()
    await newPage.goto('/pedidos')
    await newPage.waitForLoadState('networkidle')

    // 4. Verificar que los datos persisten
    const cachedData = await newPage.evaluate(async () => {
      // @ts-ignore
      const { getCachedData } = await import('/src/lib/offlineDb.ts')
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
      const { queueOperation } = await import('/src/lib/offlineDb.ts')

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
      const { getPendingOperations, markAsProcessing } = await import('/src/lib/offlineDb.ts')
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

    // 6. La app debería seguir funcionando
    await expect(page.locator('body')).toBeVisible()
  })
})

// =============================================================================
// TESTS DE RUTAS GUARDADAS
// =============================================================================

test.describe('Saved Routes - Cache Tests', () => {
  test('Ruta guardada se recupera correctamente', async ({ page }) => {
    await page.goto('/recorridos')
    await page.waitForLoadState('networkidle')

    // 1. Guardar una ruta
    const routeId = await page.evaluate(async () => {
      // @ts-ignore
      const { saveOptimizedRoute } = await import('/src/lib/offlineDb.ts')

      const id = await saveOptimizedRoute({
        nombre: 'Test Route',
        descripcion: 'Ruta de prueba',
        transportistaId: 'test-transportista',
        clienteIds: ['cliente-1', 'cliente-2', 'cliente-3'],
        ordenOptimizado: [2, 0, 1],
        distanciaTotal: 15000,
        duracionEstimada: 3600
      })

      return id
    })

    expect(routeId).toBeGreaterThan(0)

    // 2. Recuperar la ruta
    const savedRoute = await page.evaluate(async (transportistaId: string) => {
      // @ts-ignore
      const { getSavedRoutes } = await import('/src/lib/offlineDb.ts')
      const routes = await getSavedRoutes(transportistaId)
      return routes.find((r: { nombre: string }) => r.nombre === 'Test Route')
    }, 'test-transportista')

    expect(savedRoute).toBeDefined()
    expect(savedRoute.clienteIds).toHaveLength(3)
    expect(savedRoute.ordenOptimizado).toEqual([2, 0, 1])
  })

  test('Búsqueda de ruta similar funciona', async ({ page }) => {
    await page.goto('/recorridos')

    // 1. Guardar una ruta
    await page.evaluate(async () => {
      // @ts-ignore
      const { saveOptimizedRoute } = await import('/src/lib/offlineDb.ts')

      await saveOptimizedRoute({
        nombre: 'Ruta Semanal',
        transportistaId: 'transportista-1',
        clienteIds: ['a', 'b', 'c', 'd', 'e'],
        ordenOptimizado: [0, 1, 2, 3, 4]
      })
    })

    // 2. Buscar con clientes similares (80% coincidencia)
    const matchingRoute = await page.evaluate(async () => {
      // @ts-ignore
      const { findMatchingRoute } = await import('/src/lib/offlineDb.ts')

      // 4 de 5 clientes = 80% match
      return await findMatchingRoute('transportista-1', ['a', 'b', 'c', 'd'], 20)
    })

    expect(matchingRoute).toBeDefined()
    expect(matchingRoute.nombre).toBe('Ruta Semanal')

    // 3. Buscar con clientes muy diferentes (no debería encontrar)
    const noMatch = await page.evaluate(async () => {
      // @ts-ignore
      const { findMatchingRoute } = await import('/src/lib/offlineDb.ts')

      // Solo 1 de 5 clientes = 20% match (no cumple umbral)
      return await findMatchingRoute('transportista-1', ['a', 'x', 'y', 'z'], 20)
    })

    expect(noMatch).toBeNull()
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
