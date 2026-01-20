import { test, expect } from '@playwright/test'

/**
 * Tests e2e de seguridad básica
 * Verifica que las configuraciones de seguridad están presentes
 */
test.describe('Seguridad', () => {
  test('debe tener Content Security Policy configurado', async ({ page }) => {
    await page.goto('/')

    // Verificar que existe el meta tag de CSP
    const csp = page.locator('meta[http-equiv="Content-Security-Policy"]')
    await expect(csp).toHaveCount(1)

    const cspContent = await csp.getAttribute('content')

    // Verificar directivas importantes
    expect(cspContent).toContain("default-src 'self'")
    expect(cspContent).toContain('script-src')
    expect(cspContent).toContain('frame-ancestors')
  })

  test('debe tener X-Frame-Options configurado', async ({ page }) => {
    await page.goto('/')

    const xFrameOptions = page.locator('meta[http-equiv="X-Frame-Options"]')
    await expect(xFrameOptions).toHaveCount(1)

    const content = await xFrameOptions.getAttribute('content')
    expect(content).toBe('DENY')
  })

  test('debe tener X-Content-Type-Options configurado', async ({ page }) => {
    await page.goto('/')

    const xContentType = page.locator('meta[http-equiv="X-Content-Type-Options"]')
    await expect(xContentType).toHaveCount(1)

    const content = await xContentType.getAttribute('content')
    expect(content).toBe('nosniff')
  })

  test('debe tener Referrer-Policy configurado', async ({ page }) => {
    await page.goto('/')

    const referrer = page.locator('meta[name="referrer"]')
    await expect(referrer).toHaveCount(1)

    const content = await referrer.getAttribute('content')
    expect(content).toBe('strict-origin-when-cross-origin')
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

  test('los formularios deben prevenir CSRF básico', async ({ page }) => {
    await page.goto('/')

    // Verificar que los formularios usan POST o tienen protección
    const forms = page.locator('form')
    const count = await forms.count()

    for (let i = 0; i < count; i++) {
      const form = forms.nth(i)
      const method = await form.getAttribute('method')

      // Si es un form de login/datos sensibles, debería usar POST
      const action = await form.getAttribute('action')
      if (action && (action.includes('login') || action.includes('auth'))) {
        expect(method?.toLowerCase()).toBe('post')
      }
    }
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
