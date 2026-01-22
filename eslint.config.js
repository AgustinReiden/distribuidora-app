import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import tseslint from '@typescript-eslint/eslint-plugin'
import tsparser from '@typescript-eslint/parser'
import { defineConfig, globalIgnores } from 'eslint/config'

export default defineConfig([
  globalIgnores(['dist', '**/*.d.ts']),
  // JavaScript/JSX files
  {
    files: ['**/*.{js,jsx}'],
    extends: [
      js.configs.recommended,
      reactHooks.configs.flat.recommended,
      reactRefresh.configs.vite,
    ],
    languageOptions: {
      ecmaVersion: 2020,
      globals: globals.browser,
      parserOptions: {
        ecmaVersion: 'latest',
        ecmaFeatures: { jsx: true },
        sourceType: 'module',
      },
    },
    rules: {
      // Permitir variables prefijadas con _ o mayúsculas
      'no-unused-vars': ['error', { varsIgnorePattern: '^_|^[A-Z_]', argsIgnorePattern: '^_' }],
      // Desactivar regla estricta de setState en effects (patrón válido para sync con props)
      'react-hooks/set-state-in-effect': 'off',
      // Downgrade warnings que no son críticos
      'react-hooks/exhaustive-deps': 'warn',
    },
  },
  // TypeScript/TSX files
  {
    files: ['**/*.{ts,tsx}'],
    extends: [
      js.configs.recommended,
      reactHooks.configs.flat.recommended,
      reactRefresh.configs.vite,
    ],
    languageOptions: {
      ecmaVersion: 2020,
      globals: globals.browser,
      parser: tsparser,
      parserOptions: {
        ecmaVersion: 'latest',
        ecmaFeatures: { jsx: true },
        sourceType: 'module',
      },
    },
    plugins: {
      '@typescript-eslint': tseslint,
    },
    rules: {
      // Usar regla de TypeScript para unused vars
      'no-unused-vars': 'off',
      '@typescript-eslint/no-unused-vars': ['error', { varsIgnorePattern: '^_|^[A-Z_]', argsIgnorePattern: '^_' }],
      // Desactivar regla estricta de setState en effects
      'react-hooks/set-state-in-effect': 'off',
      // Downgrade warnings que no son críticos
      'react-hooks/exhaustive-deps': 'warn',
    },
  },
])
