import { test, expect } from '@playwright/test'

/**
 * Tests e2e para la funcionalidad de login
 */
test.describe('Login', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/')
    // Wait for the login form to render
    await page.waitForSelector('form', { timeout: 10000 })
  })

  test('debe mostrar la pantalla de login', async ({ page }) => {
    // Verificar que el heading de la app está visible
    await expect(page.getByRole('heading', { name: /distribuidora/i })).toBeVisible()

    // Verificar campos de email y contraseña
    await expect(page.getByLabel(/email/i)).toBeVisible()
    await expect(page.getByLabel(/contraseña/i)).toBeVisible()

    // Verificar botón de login
    await expect(page.getByRole('button', { name: /ingresar/i })).toBeVisible()
  })

  test('debe mostrar error con credenciales inválidas', async ({ page }) => {
    // Ingresar credenciales inválidas
    await page.getByLabel(/email/i).fill('test@invalid.com')
    await page.getByLabel(/contraseña/i).fill('wrongpassword')

    // Intentar login
    await page.getByRole('button', { name: /ingresar/i }).click()

    // Verificar mensaje de error (esperar hasta 10 segundos para Supabase response)
    await expect(page.getByText(/incorrectos|inválido|error/i)).toBeVisible({ timeout: 10000 })
  })

  test('debe validar campo de email vacío', async ({ page }) => {
    // Dejar email vacío e intentar login
    await page.getByLabel(/contraseña/i).fill('somepassword')
    await page.getByRole('button', { name: /ingresar/i }).click()

    // El campo email debería tener el atributo required
    const emailInput = page.getByLabel(/email/i)
    await expect(emailInput).toHaveAttribute('required', '')
  })

  test('debe tener accesibilidad básica en el formulario', async ({ page }) => {
    // Verificar que los campos tienen labels asociados
    const emailInput = page.getByLabel(/email/i)
    const passwordInput = page.getByLabel(/contraseña/i)

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
