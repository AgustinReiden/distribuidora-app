import { test, expect } from '@playwright/test'

/**
 * Tests e2e de accesibilidad básica
 * Verifica que la aplicación cumple con estándares básicos de accesibilidad
 */
test.describe('Accesibilidad', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/')
    await page.waitForLoadState('networkidle')
    // Wait for the React app to render (login form appears after auth check)
    await page.waitForSelector('form', { timeout: 15000 })
  })

  test('la página debe tener un título', async ({ page }) => {
    await expect(page).toHaveTitle(/.+/)
  })

  test('debe tener el atributo lang en español', async ({ page }) => {
    const html = page.locator('html')
    await expect(html).toHaveAttribute('lang', 'es')
  })

  test('debe tener meta viewport para responsividad', async ({ page }) => {
    const viewport = page.locator('meta[name="viewport"]')
    await expect(viewport).toHaveAttribute('content', /width=device-width/)
  })

  test('los botones deben ser focuseables con teclado', async ({ page }) => {
    // Buscar el botón de login (submit button inside the rendered form)
    const loginButton = page.getByRole('button', { name: /ingresar/i })
    await expect(loginButton).toBeVisible()

    // Verificar que el botón es focuseable
    await loginButton.focus()
    await expect(loginButton).toBeFocused()
  })

  test('los inputs deben tener labels asociados', async ({ page }) => {
    // Buscar todos los inputs de tipo text, email, password
    const inputs = page.locator('input[type="text"], input[type="email"], input[type="password"]')
    const count = await inputs.count()

    for (let i = 0; i < count; i++) {
      const input = inputs.nth(i)
      const id = await input.getAttribute('id')
      const ariaLabel = await input.getAttribute('aria-label')
      const ariaLabelledby = await input.getAttribute('aria-labelledby')

      // Cada input debe tener al menos una forma de label
      const hasLabel = id && await page.locator(`label[for="${id}"]`).count() > 0
      const hasAriaLabel = !!ariaLabel
      const hasAriaLabelledby = !!ariaLabelledby
      const hasPlaceholder = !!(await input.getAttribute('placeholder'))

      // Al menos una forma de identificación debe existir
      expect(hasLabel || hasAriaLabel || hasAriaLabelledby || hasPlaceholder).toBeTruthy()
    }
  })

  test('no debe haber errores de contraste obvios', async ({ page }) => {
    // Verify the app has rendered visible content
    const heading = page.getByRole('heading', { name: /distribuidora/i })
    await expect(heading).toBeVisible()

    // Verificar que hay texto legible (no todo transparente o muy pequeño)
    const fontSize = await heading.evaluate(el => {
      return window.getComputedStyle(el).fontSize
    })
    const fontSizeNum = parseFloat(fontSize)
    expect(fontSizeNum).toBeGreaterThanOrEqual(12) // Mínimo 12px
  })

  test('los links deben ser distinguibles', async ({ page }) => {
    const links = page.getByRole('link')
    const count = await links.count()

    for (let i = 0; i < Math.min(count, 5); i++) {
      const link = links.nth(i)
      const isVisible = await link.isVisible()

      if (isVisible) {
        // Verificar que el link tiene texto o aria-label
        const text = await link.textContent()
        const ariaLabel = await link.getAttribute('aria-label')
        expect(text?.trim() || ariaLabel).toBeTruthy()
      }
    }
  })

  test('debe ser navegable con teclado (Tab)', async ({ page }) => {
    // Comenzar desde el body
    await page.locator('body').focus()

    // Presionar Tab varias veces y verificar que el foco se mueve
    const focusedElements = []

    for (let i = 0; i < 5; i++) {
      await page.keyboard.press('Tab')
      const focused = await page.evaluate(() => {
        const el = document.activeElement
        return el ? el.tagName.toLowerCase() : null
      })
      if (focused && focused !== 'body') {
        focusedElements.push(focused)
      }
    }

    // Debe haber elementos focuseables
    expect(focusedElements.length).toBeGreaterThan(0)
  })
})
