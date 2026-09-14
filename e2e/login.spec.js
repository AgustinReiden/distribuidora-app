import { test, expect } from '@playwright/test'

/**
 * Tests e2e para la funcionalidad de login
 */
test.describe('Login', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/')
    await page.waitForLoadState('networkidle')
    // Wait for the login form to render (auth check + safety timer up to ~2s)
    await page.waitForSelector('form', { timeout: 15000 })
  })

  test('debe mostrar la pantalla de login', async ({ page }) => {
    // Verificar que el heading de la app está visible
    await expect(page.getByRole('heading', { name: /distribuidora/i })).toBeVisible()

    // Verificar campos de email y contraseña (by id — more reliable than label matching)
    await expect(page.locator('#email')).toBeVisible()
    await expect(page.locator('#password')).toBeVisible()

    // Verificar botón de login
    await expect(page.getByRole('button', { name: /ingresar/i })).toBeVisible()
  })

  test('debe mostrar error con credenciales inválidas', async ({ page }) => {
    // Mockear el 400 de Supabase Auth en vez de pegarle a una red real: así
    // el resultado es determinístico y no depende del timeout de 15s de
    // AUTH_REQUEST_TIMEOUT_MS (useAuth.tsx) para asomar cualquier mensaje.
    // LoginScreen.tsx sólo distingue "contiene 'perfil'" vs el resto, así que
    // cualquier error de login que no sea ese cae siempre en el mismo texto:
    // ese es el mensaje exacto que se puede afirmar acá.
    await page.route('**/auth/v1/token**', route => route.fulfill({
      status: 400,
      contentType: 'application/json',
      body: JSON.stringify({ error: 'invalid_grant', error_description: 'Invalid login credentials' })
    }))

    await page.locator('#email').fill('test@invalid.com')
    await page.locator('#password').fill('wrongpassword')

    await page.getByRole('button', { name: /ingresar/i }).click()

    await expect(page.getByText('Email o contraseña incorrectos')).toBeVisible({ timeout: 5000 })
  })

  test('debe validar campo de email vacío', async ({ page }) => {
    // Dejar email vacío e intentar login
    await page.locator('#password').fill('somepassword')
    await page.getByRole('button', { name: /ingresar/i }).click()

    // El campo email debería tener el atributo required
    const emailInput = page.locator('#email')
    await expect(emailInput).toHaveAttribute('required', '')
  })

  test('debe tener accesibilidad básica en el formulario', async ({ page }) => {
    // Verificar que los campos tienen labels asociados
    const emailInput = page.locator('#email')
    const passwordInput = page.locator('#password')

    // Verificar que son focuseables
    await emailInput.focus()
    await expect(emailInput).toBeFocused()

    // Tab al siguiente campo
    await page.keyboard.press('Tab')
    await expect(passwordInput).toBeFocused()

    // Tab al botón
    await page.keyboard.press('Tab')
    await expect(page.getByRole('button', { name: /ingresar/i })).toBeFocused()
  })
})
