import js from '@eslint/js'
import globals from 'globals'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import { defineConfig, globalIgnores } from 'eslint/config'

export default defineConfig([
  globalIgnores(['dist']),
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
])
