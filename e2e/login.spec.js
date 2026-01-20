import { test, expect } from '@playwright/test'

/**
 * Tests e2e para la funcionalidad de login
 */
test.describe('Login', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/')
  })

  test('debe mostrar la pantalla de login', async ({ page }) => {
    // Verificar que el formulario de login está visible
    await expect(page.getByRole('heading', { name: /iniciar sesión|login/i })).toBeVisible()

    // Verificar campos de email y contraseña
    await expect(page.getByLabel(/email|correo/i)).toBeVisible()
    await expect(page.getByLabel(/contraseña|password/i)).toBeVisible()

    // Verificar botón de login
    await expect(page.getByRole('button', { name: /ingresar|iniciar|login/i })).toBeVisible()
  })

  test('debe mostrar error con credenciales inválidas', async ({ page }) => {
    // Ingresar credenciales inválidas
    await page.getByLabel(/email|correo/i).fill('test@invalid.com')
    await page.getByLabel(/contraseña|password/i).fill('wrongpassword')

    // Intentar login
    await page.getByRole('button', { name: /ingresar|iniciar|login/i }).click()

    // Verificar mensaje de error (esperar hasta 5 segundos)
    await expect(page.getByText(/incorrectos|inválido|error/i)).toBeVisible({ timeout: 5000 })
  })

  test('debe validar campo de email vacío', async ({ page }) => {
    // Dejar email vacío e intentar login
    await page.getByLabel(/contraseña|password/i).fill('somepassword')
    await page.getByRole('button', { name: /ingresar|iniciar|login/i }).click()

    // El campo email debería mostrar algún indicador de error o el navegador
    // debería prevenir el submit por ser campo required
    const emailInput = page.getByLabel(/email|correo/i)
    await expect(emailInput).toHaveAttribute('required', '')
  })

  test('debe tener accesibilidad básica en el formulario', async ({ page }) => {
    // Verificar que los campos tienen labels asociados
    const emailInput = page.getByLabel(/email|correo/i)
    const passwordInput = page.getByLabel(/contraseña|password/i)

    // Verificar que son focuseables
    await emailInput.focus()
    await expect(emailInput).toBeFocused()

    // Tab al siguiente campo
    await page.keyboard.press('Tab')
    await expect(passwordInput).toBeFocused()

    // Tab al botón
    await page.keyboard.press('Tab')
    await expect(page.getByRole('button', { name: /ingresar|iniciar|login/i })).toBeFocused()
  })
})
