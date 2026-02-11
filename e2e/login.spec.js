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
    // Ingresar credenciales inválidas
    await page.locator('#email').fill('test@invalid.com')
    await page.locator('#password').fill('wrongpassword')

    // Intentar login
    await page.getByRole('button', { name: /ingresar/i }).click()

    // Verificar mensaje de error (esperar hasta 15 segundos para Supabase response)
    await expect(page.getByText(/incorrectos|inválido|error/i)).toBeVisible({ timeout: 15000 })
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
