# UI/UX Redesign: Crecer Distribuciones - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Transform the app from a generic Tailwind starter look into a branded, professional SaaS product for "Crecer Distribuciones".

**Architecture:** Pure visual upgrade - no data model, routing, or logic changes. Systematic color replacement (blue→emerald, gray→slate), typography upgrade (Inter font), and component-level refinement (cards, buttons, inputs, navigation). Changes flow from config files outward to components.

**Tech Stack:** Tailwind CSS, Radix UI, Lucide React, Google Fonts (Inter)

---

## Task 1: Foundation - Font, Tailwind Config, Global CSS

**Files:**
- Modify: `index.html`
- Modify: `tailwind.config.js`
- Modify: `src/index.css`

**Step 1: Add Inter font to index.html**

In `index.html`, add Google Fonts preconnect and stylesheet in the `<head>`, after the existing preconnect lines (after line 44). Also update all branding references:

```html
<!-- Add after line 44 (after maps.gstatic.com preconnect) -->
<link rel="preconnect" href="https://fonts.googleapis.com" />
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet" />
```

Also update the CSP `style-src` to allow Google Fonts:
```
style-src 'self' 'unsafe-inline' https://fonts.googleapis.com;
font-src 'self' https://fonts.gstatic.com;
```

Update branding references throughout `index.html`:
- `<meta name="theme-color" content="#059669" />` (was #2563eb)
- `<meta name="apple-mobile-web-app-title" content="Crecer" />` (was Distribuidora)
- `<meta name="application-name" content="Crecer Distribuciones" />` (was Distribuidora App)
- `<meta name="msapplication-TileColor" content="#059669" />` (was #2563eb)
- `<meta property="og:title" content="Crecer Distribuciones" />` (was Distribuidora App)
- `<meta property="og:description" content="Sistema de gestión - Crecer Distribuciones" />`
- `<meta property="og:site_name" content="Crecer Distribuciones" />`
- `<link rel="mask-icon" ... color="#059669" />` (was #2563eb)
- `<title>Crecer Distribuciones</title>` (was Distribuidora App)
- Update skip-link background in `<style>` from `#1e40af` to `#047857` (emerald-700)

**Step 2: Update tailwind.config.js**

Add Inter to the font family and extend the theme:

```js
/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  darkMode: 'class',
  theme: {
    extend: {
      fontFamily: {
        sans: ['Inter', 'system-ui', '-apple-system', 'BlinkMacSystemFont', 'Segoe UI', 'Roboto', 'sans-serif'],
      },
      animation: {
        'slide-in': 'slide-in 0.2s ease-out',
        'fade-in': 'fade-in 0.2s ease-out',
        'fade-out': 'fade-out 0.15s ease-in',
        'scale-in': 'scale-in 0.2s ease-out',
      },
      keyframes: {
        'slide-in': {
          '0%': { opacity: '0', transform: 'translateX(100%)' },
          '100%': { opacity: '1', transform: 'translateX(0)' },
        },
        'fade-in': {
          '0%': { opacity: '0' },
          '100%': { opacity: '1' },
        },
        'fade-out': {
          '0%': { opacity: '1' },
          '100%': { opacity: '0' },
        },
        'scale-in': {
          '0%': { opacity: '0', transform: 'scale(0.95)' },
          '100%': { opacity: '1', transform: 'scale(1)' },
        },
      },
    },
  },
  plugins: [],
}
```

**Step 3: Update src/index.css**

Replace the body font-family and update global colors:

```css
/* In body rule - replace font-family */
body {
  font-family: 'Inter', system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  @apply bg-slate-100 dark:bg-slate-900 text-slate-900 dark:text-slate-100;
}
```

Update focus ring color:
```css
*:focus-visible {
  @apply outline-none ring-2 ring-emerald-500 ring-offset-2 dark:ring-offset-slate-900;
}
```

Update scrollbar colors:
```css
::-webkit-scrollbar-track {
  @apply bg-slate-100 dark:bg-slate-800;
}
::-webkit-scrollbar-thumb {
  @apply bg-slate-300 dark:bg-slate-600 rounded-full;
}
::-webkit-scrollbar-thumb:hover {
  @apply bg-slate-400 dark:bg-slate-500;
}
```

Update input border color:
```css
input:not([type="checkbox"]):not([type="radio"]),
textarea,
select {
  ...
  border-color: #cbd5e1; /* slate-300 instead of gray d1d5db */
}

.dark input:not([type="checkbox"]):not([type="radio"]),
.dark textarea,
.dark select {
  background-color: #334155 !important; /* slate-700 instead of gray 374151 */
  color: #ffffff !important;
  border-color: #475569; /* slate-600 instead of gray 4b5563 */
}
```

Update select dark mode:
```css
select {
  @apply dark:bg-slate-700 dark:border-slate-600 dark:text-white;
}
option {
  @apply dark:bg-slate-700 dark:text-white;
}
```

**Step 4: Verify the build compiles**

Run: `npx vite build 2>&1 | head -20`
Expected: Build succeeds without errors

**Step 5: Commit**

```bash
git add index.html tailwind.config.js src/index.css
git commit -m "feat(ui): foundation - Inter font, emerald palette, slate neutrals"
```

---

## Task 2: Global Color Replacement - blue→emerald primary

This task replaces `blue-600` (primary action color) with `emerald-600` across all files. This is the biggest single change. It needs careful find/replace.

**Important context:** Not ALL blue is primary. Some blue is semantic (e.g., `bg-blue-100 text-blue-800` for "asignado" status in formatters.ts). Those should stay blue. Only replace blue used as the *primary brand/action color*.

**Files:** ~68 files under `src/` containing `blue-600`

**Step 1: Replace primary blue-600 → emerald-600 across all component files**

Use search-and-replace across all `.tsx` files in `src/components/` and `src/App.tsx`:
- `blue-600` → `emerald-600` (primary action color)
- `blue-700` → `emerald-700` (hover states)
- `blue-500` → `emerald-500` (focus rings)

**Do NOT replace in these files (they use blue semantically for status):**
- `src/utils/formatters.ts` - `getEstadoColor` uses blue for "asignado" status (keep)
- `src/styles/high-contrast.css` - accessibility overrides (keep)

**Step 2: Replace primary blue soft backgrounds**

In the same component files:
- `bg-blue-50` → `bg-emerald-50` (only when used as primary soft bg, NOT for status badges)
- `bg-blue-100` → `bg-emerald-100` (only for primary, NOT status)
- `dark:bg-blue-900/30` → `dark:bg-emerald-900/30` (only for primary)
- `dark:bg-blue-900/20` → `dark:bg-emerald-900/20` (only for primary)
- `text-blue-400` → `text-emerald-400` (dark mode primary text)

**Status colors to KEEP as blue** (used for "asignado"/"en camino" status):
- In `PedidoCard.tsx` EstadoStepper: blue for `asignado` state → KEEP
- In `VistaDashboard.tsx` EstadoCard for "En camino": blue → KEEP
- In `formatters.ts` getEstadoColor: blue for asignado → KEEP

**Step 3: Replace ring-blue-500 → ring-emerald-500**

This is the focus ring color. Replace in all input/form files:
- `ring-blue-500` → `ring-emerald-500`
- `focus:ring-blue-500` → `focus:ring-emerald-500`
- `focus:border-blue-500` → `focus:border-emerald-500`

**Step 4: Verify build compiles**

Run: `npx vite build 2>&1 | head -20`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add -A
git commit -m "feat(ui): replace blue primary with emerald across all components"
```

---

## Task 3: Global Color Replacement - gray→slate neutrals

**Files:** All component files using `gray-*` as neutral (not semantic)

**Step 1: Replace gray→slate in component files**

Systematic replacement across `src/components/`:
- `gray-50` → `slate-50`
- `gray-100` → `slate-100`
- `gray-200` → `slate-200`
- `gray-300` → `slate-300`
- `gray-400` → `slate-400`
- `gray-500` → `slate-500`
- `gray-600` → `slate-600`
- `gray-700` → `slate-700`
- `gray-800` → `slate-800`
- `gray-900` → `slate-900`

Also in:
- `src/utils/formatters.ts` (bg-gray-100 text-gray-800 defaults)
- `src/App.tsx`
- `src/components/ui/Dialog.tsx`
- `src/components/ui/Skeleton.tsx`
- `src/components/ui/EmptyState.tsx`
- `src/components/ui/FormField.tsx`

**Step 2: Verify build compiles**

Run: `npx vite build 2>&1 | head -20`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add -A
git commit -m "feat(ui): replace gray neutrals with slate for cooler tone"
```

---

## Task 4: Login Screen Redesign

**Files:**
- Modify: `src/components/auth/LoginScreen.tsx`

**Step 1: Rewrite LoginScreen with new branding**

Replace the entire component with the new design:

```tsx
import React, { useState } from 'react';
import { TrendingUp, Loader2 } from 'lucide-react';
import { useAuth } from '../../hooks/supabase';

export default function LoginScreen() {
  const { login } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    setError('');
    setLoading(true);
    try {
      await login(email, password);
    } catch {
      setError('Email o contraseña incorrectos');
    }
    setLoading(false);
  };

  return (
    <div className="min-h-screen bg-gradient-to-br from-emerald-700 via-teal-600 to-emerald-800 flex items-center justify-center p-4 relative overflow-hidden">
      {/* Decorative background pattern */}
      <div className="absolute inset-0 overflow-hidden">
        <div className="absolute -top-40 -right-40 w-80 h-80 rounded-full bg-white/5" />
        <div className="absolute -bottom-32 -left-32 w-96 h-96 rounded-full bg-white/5" />
        <div className="absolute top-1/3 left-1/4 w-64 h-64 rounded-full bg-teal-500/10" />
      </div>

      <div className="relative bg-white/95 backdrop-blur-sm rounded-2xl shadow-2xl w-full max-w-md p-8">
        <div className="text-center mb-8">
          <div className="inline-flex items-center justify-center w-16 h-16 bg-gradient-to-br from-emerald-500 to-teal-600 rounded-2xl mb-4 shadow-lg shadow-emerald-200">
            <TrendingUp className="w-8 h-8 text-white" />
          </div>
          <h1 className="text-2xl font-bold text-slate-800 tracking-tight">Crecer Distribuciones</h1>
          <p className="text-slate-500 mt-1 text-sm">Sistema de gestión</p>
        </div>
        <form onSubmit={handleSubmit} className="space-y-5">
          {error && (
            <div className="bg-red-50 text-red-600 px-4 py-3 rounded-xl text-sm border border-red-100">
              {error}
            </div>
          )}
          <div>
            <label htmlFor="email" className="block text-sm font-medium text-slate-700 mb-1.5">Email</label>
            <input
              id="email"
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="w-full px-4 py-3 border border-slate-300 rounded-xl focus:ring-2 focus:ring-emerald-500 focus:border-emerald-500 transition-all text-slate-800 placeholder:text-slate-400"
              placeholder="tu@email.com"
              required
            />
          </div>
          <div>
            <label htmlFor="password" className="block text-sm font-medium text-slate-700 mb-1.5">Contraseña</label>
            <input
              id="password"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="w-full px-4 py-3 border border-slate-300 rounded-xl focus:ring-2 focus:ring-emerald-500 focus:border-emerald-500 transition-all text-slate-800 placeholder:text-slate-400"
              placeholder="••••••••"
              required
            />
          </div>
          <button
            type="submit"
            disabled={loading}
            className="w-full py-3 bg-gradient-to-r from-emerald-600 to-teal-600 text-white rounded-xl hover:from-emerald-500 hover:to-teal-500 font-semibold flex items-center justify-center transition-all shadow-md hover:shadow-lg disabled:opacity-50"
          >
            {loading ? <Loader2 className="w-5 h-5 animate-spin" /> : 'Ingresar'}
          </button>
        </form>
      </div>
    </div>
  );
}
```

**Step 2: Verify build compiles**

Run: `npx vite build 2>&1 | head -20`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add src/components/auth/LoginScreen.tsx
git commit -m "feat(ui): redesign login screen with Crecer branding"
```

---

## Task 5: TopNavigation Redesign

**Files:**
- Modify: `src/components/layout/TopNavigation.tsx`

**Step 1: Update the header, logo, and navigation styling**

Key changes to `TopNavigation.tsx`:

1. Replace `Truck` import with `TrendingUp` (line 5)
2. Header bar (line 172): Change from `bg-white dark:bg-gray-800 border-b dark:border-gray-700 shadow-sm` to:
   ```
   bg-gradient-to-r from-emerald-700 to-teal-600 dark:from-slate-900 dark:to-slate-800 shadow-lg
   ```
   Remove the `border-b` since the gradient provides visual separation.

3. Logo section (line 192): Replace truck icon and text:
   ```tsx
   <div className="flex items-center space-x-2">
     <div className="p-2 bg-white/20 backdrop-blur-sm rounded-xl">
       <TrendingUp className="w-5 h-5 text-white" />
     </div>
     <span className="font-bold text-lg text-white hidden sm:block tracking-tight">
       Crecer
     </span>
   </div>
   ```

4. Hamburger button (line 177-188): Change text/hover to white variants:
   ```
   hover:bg-white/10 → text-white
   ```
   Icon color: `text-white` instead of `text-gray-600 dark:text-gray-300`

5. Desktop nav items (line 211-219): Active item uses `bg-white/20 text-white`, inactive uses `text-white/80 hover:bg-white/10`:
   ```tsx
   className={`flex items-center space-x-2 px-4 py-2 rounded-lg transition-all ${
     vista === item.id
       ? 'bg-white/20 text-white shadow-sm backdrop-blur-sm'
       : 'text-white/80 hover:bg-white/10 hover:text-white'
   }`}
   ```

6. Dropdown group buttons (line 239-243): Same white-on-gradient pattern:
   ```tsx
   className={`flex items-center space-x-2 px-4 py-2 rounded-lg transition-all ${
     isActive
       ? 'bg-white/20 text-white'
       : 'text-white/80 hover:bg-white/10 hover:text-white'
   }`}
   ```

7. Dropdown menus (line 252): Add backdrop-blur:
   ```
   bg-white dark:bg-slate-800 rounded-xl shadow-xl border dark:border-slate-700 backdrop-blur-sm
   ```

8. Theme toggle button (line 282-288): White text:
   ```
   text-white/80 hover:bg-white/10 hover:text-white
   ```

9. User menu button (line 300-310): White text, avatar with white ring:
   ```tsx
   <div className="w-8 h-8 rounded-full bg-white/20 ring-2 ring-white/30 flex items-center justify-center">
     <span className="text-sm font-semibold text-white">
       {perfil?.nombre?.charAt(0)?.toUpperCase() || 'U'}
     </span>
   </div>
   <span className="hidden sm:block text-sm font-medium text-white/90 max-w-24 truncate">
     {perfil?.nombre?.split(' ')[0] || 'Usuario'}
   </span>
   <ChevronDown className="w-4 h-4 text-white/60" />
   ```

10. Mobile menu (line 340-344): Keep `bg-white dark:bg-slate-800` since it's a separate panel. Update inactive items to use slate colors.

**Step 2: Verify build compiles**

Run: `npx vite build 2>&1 | head -20`

**Step 3: Commit**

```bash
git add src/components/layout/TopNavigation.tsx
git commit -m "feat(ui): redesign navigation with gradient header and Crecer branding"
```

---

## Task 6: Dashboard Visual Upgrade

**Files:**
- Modify: `src/components/vistas/VistaDashboard.tsx`

**Step 1: Upgrade MetricaCard component**

Replace the MetricaCard component (lines 114-135) with a more refined version:

```tsx
const MetricaCard = memo(function MetricaCard({ icono, titulo, valor, subtitulo, colorClase, tendencia }: MetricaCardProps) {
  const Icono = icono;
  return (
    <div className="bg-white dark:bg-slate-800 rounded-xl shadow-sm hover:shadow-lg transition-all duration-200 overflow-hidden group">
      <div className={`h-1 ${colorClase.bg}`} /> {/* Top colored accent line */}
      <div className="p-6">
        <div className="flex items-start justify-between">
          <div className={`p-3 bg-gradient-to-br ${colorClase.bg} rounded-xl shadow-sm`}>
            <Icono className={`w-6 h-6 ${colorClase.icon}`} />
          </div>
          {tendencia && (
            <div className="text-right">
              {tendencia}
            </div>
          )}
        </div>
        <div className="mt-4">
          <p className="text-sm font-medium text-slate-500 dark:text-slate-400">{titulo}</p>
          <p className={`text-3xl font-bold mt-1 tracking-tight ${colorClase.text}`}>{valor}</p>
          {subtitulo && <p className="text-xs text-slate-400 dark:text-slate-500 mt-1">{subtitulo}</p>}
        </div>
      </div>
    </div>
  );
});
```

**Step 2: Upgrade EstadoCard component**

Replace EstadoCard (lines 138-154):

```tsx
const EstadoCard = memo(function EstadoCard({ icono, titulo, valor, colorClase, onClick }: EstadoCardProps) {
  const Icono = icono;
  return (
    <button
      onClick={onClick}
      className={`${colorClase.bg} border ${colorClase.border} rounded-xl p-4 text-left hover:shadow-md hover:translate-y-[-1px] transition-all duration-200 w-full`}
    >
      <div className="flex items-center justify-between">
        <div className="flex items-center space-x-2">
          <Icono className={`w-5 h-5 ${colorClase.icon}`} />
          <span className={`${colorClase.text} font-medium text-sm`}>{titulo}</span>
        </div>
      </div>
      <p className={`text-3xl font-bold ${colorClase.icon} mt-2 tracking-tight`}>{valor}</p>
    </button>
  );
});
```

**Step 3: Upgrade BarraProgreso**

Replace BarraProgreso (lines 157-188) - change blue to emerald:

```tsx
const BarraProgreso = memo(function BarraProgreso({ dia, ventas, maxVenta, index }: BarraProgresoProps) {
  const porcentaje = maxVenta > 0 ? (ventas / maxVenta) * 100 : 0;
  const esHoy = index === 6;

  return (
    <div className="flex items-center space-x-3 group">
      <span className={`w-12 text-sm ${esHoy ? 'font-bold text-emerald-600' : 'text-slate-600 dark:text-slate-400'}`}>
        {dia}
      </span>
      <div className="flex-1 bg-slate-200 dark:bg-slate-700 rounded-full h-8 overflow-hidden">
        <div
          className={`h-8 rounded-full flex items-center justify-end pr-3 transition-all duration-500 ${
            esHoy
              ? 'bg-gradient-to-r from-emerald-500 to-teal-500'
              : 'bg-gradient-to-r from-emerald-400 to-teal-400'
          }`}
          style={{
            width: `${Math.max(porcentaje, 15)}%`,
            animationDelay: `${index * 100}ms`
          }}
        >
          <span className="text-xs text-white font-medium truncate">
            {formatPrecio(ventas)}
          </span>
        </div>
      </div>
      <div className="w-16 text-right opacity-0 group-hover:opacity-100 transition-opacity">
        <span className="text-xs text-slate-500">{porcentaje.toFixed(0)}%</span>
      </div>
    </div>
  );
});
```

**Step 4: Update page heading style**

In the VistaDashboard header (lines 248-249), add tracking-tight to the h1:
```tsx
<h1 className="text-2xl font-bold text-slate-800 dark:text-white tracking-tight">
```

**Step 5: Update section cards**

For the section cards ("Ventas últimos 7 días", "Top 5 Productos", "Tasa de Entrega"), they already use `bg-white dark:bg-gray-800 rounded-xl shadow-lg p-6` - after the gray→slate replacement they'll use slate. No additional changes needed.

**Step 6: Verify build**

Run: `npx vite build 2>&1 | head -20`

**Step 7: Commit**

```bash
git add src/components/vistas/VistaDashboard.tsx
git commit -m "feat(ui): upgrade dashboard cards with accent lines and better typography"
```

---

## Task 7: PedidoCard Refinement

**Files:**
- Modify: `src/components/pedidos/PedidoCard.tsx`

**Step 1: Add left border by status and hover effect**

On the outer card div (line 166), add status-based left border:

```tsx
<div className={`bg-white dark:bg-slate-800 border dark:border-slate-700 rounded-xl shadow-sm p-4 hover:shadow-lg hover:translate-y-[-1px] transition-all duration-200 border-l-4 ${
  pedido.estado === 'pendiente' ? 'border-l-amber-400' :
  pedido.estado === 'en_preparacion' ? 'border-l-orange-400' :
  pedido.estado === 'asignado' ? 'border-l-blue-400' :
  pedido.estado === 'entregado' && tieneSalvedad ? 'border-l-amber-500' :
  pedido.estado === 'entregado' ? 'border-l-emerald-500' :
  'border-l-slate-300'
}`}>
```

Note: `rounded-lg` → `rounded-xl` for consistency.

**Step 2: Refine total price styling**

Line 233 - change from `text-blue-600` to `text-emerald-600`:
```tsx
<p className="text-lg font-bold text-emerald-600">{formatPrecio(pedido.total)}</p>
```

Also in the expanded detail total (line 324):
```tsx
<p className="text-xl font-bold text-emerald-600">{formatPrecio(pedido.total)}</p>
```

And individual item subtotals (line 318):
```tsx
<p className="text-sm font-bold text-emerald-600">{formatPrecio(item.subtotal || item.precio_unitario * item.cantidad)}</p>
```

**Step 3: Verify build**

Run: `npx vite build 2>&1 | head -20`

**Step 4: Commit**

```bash
git add src/components/pedidos/PedidoCard.tsx
git commit -m "feat(ui): refine pedido cards with status left border and hover"
```

---

## Task 8: Client and Product Card Refinement

**Files:**
- Modify: `src/components/vistas/VistaClientes.tsx`
- Modify: `src/components/vistas/VistaProductos.tsx`

**Step 1: Upgrade client cards**

In `VistaClientes.tsx`, update the card wrapper (line ~152):
```tsx
<div
  key={cliente.id}
  className="bg-white dark:bg-slate-800 border dark:border-slate-700 rounded-xl shadow-sm p-4 hover:shadow-lg hover:translate-y-[-1px] transition-all duration-200"
>
```

Note: `rounded-lg` → `rounded-xl`, add `hover:translate-y-[-1px]`

**Step 2: Upgrade product cards**

In `VistaProductos.tsx`, apply same card pattern:
- `rounded-lg` → `rounded-xl`
- Add `hover:shadow-lg hover:translate-y-[-1px] transition-all duration-200`

**Step 3: Verify build**

Run: `npx vite build 2>&1 | head -20`

**Step 4: Commit**

```bash
git add src/components/vistas/VistaClientes.tsx src/components/vistas/VistaProductos.tsx
git commit -m "feat(ui): refine client and product cards with hover effects"
```

---

## Task 9: Button and Input Global Refinement

**Files:**
- Modify: `src/components/ui/FormField.tsx` (label color: gray→slate already done in Task 3)
- Modify: `src/components/modals/ModalBase.tsx` (if needed)
- Modify: `src/components/ui/Dialog.tsx` (if needed)

**Step 1: Audit rounded-lg → rounded-xl in buttons**

Search across all component files for primary action buttons that still use `rounded-lg` and upgrade to `rounded-xl`:
- Login button (done in Task 4)
- "Nuevo Cliente" / "Nuevo Producto" / "Nuevo Pedido" buttons in Vista* files
- Modal save/cancel buttons

Focus on buttons that use `bg-emerald-600` (was blue-600) - they should all be `rounded-xl`.

**Step 2: Add gradient to primary action buttons (new entity buttons)**

In each Vista header, the "Nuevo X" button pattern:
```tsx
// Before:
className="... bg-emerald-600 text-white rounded-lg hover:bg-emerald-700 ..."
// After:
className="... bg-gradient-to-r from-emerald-600 to-teal-600 text-white rounded-xl hover:from-emerald-500 hover:to-teal-500 shadow-md hover:shadow-lg ..."
```

Apply to:
- `VistaClientes.tsx` - "Nuevo Cliente" button
- `VistaProductos.tsx` - "Nuevo Producto" button
- `VistaPedidos.tsx` - "Nuevo Pedido" button
- `VistaProveedores.tsx` - "Nuevo Proveedor" button
- `VistaCompras.tsx` - "Nueva Compra" button
- Other Vista* files with primary creation buttons

**Step 3: Verify build**

Run: `npx vite build 2>&1 | head -20`

**Step 4: Commit**

```bash
git add -A
git commit -m "feat(ui): upgrade primary buttons with gradient and rounded-xl"
```

---

## Task 10: Loading, Empty, and Skeleton State Refinement

**Files:**
- Modify: `src/components/layout/LoadingSpinner.tsx`
- Modify: `src/components/ui/Skeleton.tsx`
- Modify: `src/components/ui/EmptyState.tsx`

**Step 1: Update LoadingSpinner color**

In `LoadingSpinner.tsx` line 12, change:
```tsx
<Loader2 className="w-8 h-8 animate-spin text-emerald-600" aria-hidden="true" />
```
(blue-600 → emerald-600, should already be done by Task 2, just verify)

**Step 2: Update Skeleton colors**

In `Skeleton.tsx`, the base Skeleton component (line 67) should now use:
```tsx
className={`bg-slate-200 dark:bg-slate-700 ${rounded} ${animate ? 'animate-pulse' : ''} ${className}`}
```
(gray→slate should be done by Task 3, just verify)

Also update the skeleton card wrappers from `rounded-lg` → `rounded-xl`:
- `SkeletonProductCard` line 108: `rounded-lg shadow` → `rounded-xl shadow-sm`
- `SkeletonPedidoCard` line 175: `rounded-lg shadow` → `rounded-xl shadow-sm`
- `SkeletonStatCard` line 218: `rounded-lg shadow` → `rounded-xl shadow-sm`

**Step 3: Verify EmptyState colors updated**

EmptyState should already have slate colors from Task 3. Verify the icon and text classes are slate not gray.

**Step 4: Verify build**

Run: `npx vite build 2>&1 | head -20`

**Step 5: Commit**

```bash
git add src/components/layout/LoadingSpinner.tsx src/components/ui/Skeleton.tsx src/components/ui/EmptyState.tsx
git commit -m "feat(ui): refine loading, skeleton, and empty states"
```

---

## Task 11: Dialog and Modal Refinement

**Files:**
- Modify: `src/components/ui/Dialog.tsx`

**Step 1: Update Dialog styling**

In `Dialog.tsx`, update `DialogContent` (line 87):
```tsx
className={cn(
  'fixed left-[50%] top-[50%] z-50 grid w-full max-w-md translate-x-[-50%] translate-y-[-50%] gap-0 bg-white dark:bg-slate-800 shadow-2xl rounded-2xl max-h-[90vh] overflow-hidden border dark:border-slate-700',
  'data-[state=open]:animate-scale-in data-[state=closed]:animate-fade-out',
  'focus:outline-none',
  className
)}
```

Key changes:
- `rounded-xl` → `rounded-2xl` (more premium)
- `shadow-xl` → `shadow-2xl` (more depth)
- Added `border dark:border-slate-700`

**Step 2: Verify build**

Run: `npx vite build 2>&1 | head -20`

**Step 3: Commit**

```bash
git add src/components/ui/Dialog.tsx
git commit -m "feat(ui): refine dialog/modal with rounder corners and deeper shadow"
```

---

## Task 12: Remaining Vistas and PWA Metadata

**Files:**
- Modify: Various remaining Vista files for consistency
- Modify: `src/components/PWAPrompt.tsx`
- Modify: `src/components/ErrorBoundary.tsx`

**Step 1: Scan for any remaining blue-600 in src/**

Run: `grep -r "blue-600" src/ --include="*.tsx" --include="*.ts" -l`

For each file found:
- If it's a primary action color → change to emerald-600
- If it's a status color (asignado, en_camino) → keep blue

**Step 2: Scan for remaining gray-* not yet replaced**

Run: `grep -r "gray-" src/ --include="*.tsx" --include="*.ts" -l`

Replace remaining gray→slate in any missed files.

**Step 3: Update PWA metadata**

In `src/components/PWAPrompt.tsx`:
- Replace blue references with emerald branding
- Update any "Distribuidora" text to "Crecer"

In `src/components/ErrorBoundary.tsx`:
- Update blue button color to emerald

**Step 4: Verify build**

Run: `npx vite build 2>&1 | head -20`

**Step 5: Commit**

```bash
git add -A
git commit -m "feat(ui): cleanup remaining color references and PWA branding"
```

---

## Task 13: Final Verification and Dark Mode Check

**Step 1: Full build verification**

Run: `npx vite build`
Expected: Clean build with no errors

**Step 2: Run existing tests**

Run: `npx vitest run`
Expected: All tests pass (changes are visual-only, tests cover logic)

**Step 3: Search for any remaining old branding**

Run: `grep -ri "distribuidora" src/ --include="*.tsx" --include="*.ts" -l`

Update any remaining "Distribuidora" references to "Crecer Distribuciones" or "Crecer" as appropriate.

**Step 4: Search for inconsistencies**

Run: `grep -r "rounded-lg" src/components/ --include="*.tsx" -l`

Major components (cards, buttons, modals) should use `rounded-xl` or `rounded-2xl`. Minor inner elements can keep `rounded-lg`. This is a judgment call per file.

**Step 5: Final commit**

```bash
git add -A
git commit -m "feat(ui): final cleanup and consistency pass"
```

---

## Summary of Changes

| Category | Before | After |
|----------|--------|-------|
| Brand name | "Distribuidora" | "Crecer Distribuciones" |
| Primary color | blue-600 | emerald-600 with teal accents |
| Neutral color | gray-* | slate-* |
| Font | System fonts | Inter (Google Fonts) |
| Header | White flat bar | Emerald→Teal gradient |
| Cards | rounded-lg, shadow-sm | rounded-xl, hover:shadow-lg, translate |
| Buttons | bg-blue-600 rounded-lg | gradient emerald→teal, rounded-xl, shadow |
| Login | Blue gradient, basic form | Emerald gradient, decorative circles, backdrop blur |
| Inputs | border, rounded-lg | border-slate-300, rounded-xl |
| Modals | rounded-xl, shadow-xl | rounded-2xl, shadow-2xl |
| Dashboard | Simple cards | Top accent line, gradient icons, tracking-tight |
| Pedido cards | Plain border | Status-colored left border |
| Logo | Truck icon | TrendingUp icon |
