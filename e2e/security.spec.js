import { test, expect } from '@playwright/test'

/**
 * Tests e2e de seguridad básica
 * Verifica que las configuraciones de seguridad están presentes
 */
test.describe('Seguridad', () => {
  // Los cuatro de abajo leían el <meta http-equiv="..."> de index.html, pero
  // X-Frame-Options, X-Content-Type-Options y CSP `frame-ancestors` son
  // directivas que los navegadores IGNORAN cuando vienen de un meta tag —
  // sólo cuentan como header HTTP real. Lo único que protege de verdad es lo
  // que agrega el servidor, y eso es nginx.conf del repo... salvo que no lo
  // es: la config real vive en el panel de Coolify (ver CLAUDE.md § Correr y
  // verificar), así que este archivo no puede saber si el header está puesto.
  //
  // `test.fixme` hasta verificar con `curl -I` contra el dominio real. Una
  // vez confirmado, sacar el fixme (y si nginx.conf del repo estaba
  // desactualizado respecto de Coolify, corregirlo ahí, no acá).
  test.fixme('debe mandar Content-Security-Policy como header HTTP', async ({ page }) => {
    const response = await page.goto('/')
    const csp = response?.headers()['content-security-policy']
    expect(csp).toBeDefined()
    expect(csp).toContain("default-src 'self'")
    expect(csp).toContain('script-src')
    expect(csp).toContain('frame-ancestors')
  })

  test.fixme('debe mandar X-Frame-Options como header HTTP', async ({ page }) => {
    const response = await page.goto('/')
    expect(response?.headers()['x-frame-options']).toBe('DENY')
  })

  test.fixme('debe mandar X-Content-Type-Options como header HTTP', async ({ page }) => {
    const response = await page.goto('/')
    expect(response?.headers()['x-content-type-options']).toBe('nosniff')
  })

  test.fixme('debe mandar Referrer-Policy como header HTTP', async ({ page }) => {
    const response = await page.goto('/')
    expect(response?.headers()['referrer-policy']).toBe('strict-origin-when-cross-origin')
  })

  test('no debe exponer API keys en el HTML', async ({ page }) => {
    await page.goto('/')

    const htmlContent = await page.content()

    // Verificar que no hay API keys de Google expuestas
    expect(htmlContent).not.toMatch(/AIza[0-9A-Za-z_-]{35}/)

    // Verificar que no hay tokens JWT hardcodeados
    expect(htmlContent).not.toMatch(/eyJ[a-zA-Z0-9_-]{100,}/)

    // Verificar que no hay URLs de Supabase con keys
    expect(htmlContent).not.toMatch(/supabase\.co.*anon.*key/i)
  })

  test('los inputs de password deben tener type="password"', async ({ page }) => {
    await page.goto('/')

    // Buscar inputs que parezcan ser de contraseña
    const passwordInputs = page.locator('input[type="password"]')

    // Si hay campos de contraseña, deben ser de tipo password (no text)
    // (verificamos que exista el selector, no necesitamos el count)
    await passwordInputs.count()

    // Verificar que no hay inputs de texto con placeholder/name de password
    const textInputsWithPassword = page.locator(
      'input[type="text"][placeholder*="password" i], ' +
      'input[type="text"][placeholder*="contraseña" i], ' +
      'input[type="text"][name*="password" i]'
    )
    const insecureCount = await textInputsWithPassword.count()
    expect(insecureCount).toBe(0)
  })

  test('debe usar HTTPS para recursos externos', async ({ page }) => {
    const requests = []

    // Interceptar requests de recursos
    page.on('request', request => {
      const url = request.url()
      if (!url.startsWith('http://localhost') && !url.startsWith('data:')) {
        requests.push(url)
      }
    })

    await page.goto('/')
    await page.waitForLoadState('networkidle')

    // Todos los recursos externos deben usar HTTPS
    for (const url of requests) {
      if (url.startsWith('http://')) {
        // Permitir localhost para desarrollo
        expect(url).toMatch(/^http:\/\/localhost/)
      }
    }
  })
})
