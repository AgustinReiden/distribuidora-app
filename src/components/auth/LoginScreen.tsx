import React, { useState } from 'react';
import { useAuth } from '../../hooks/supabase';
import { Button } from '../ui/Button';
import { Logo } from '../ui/Logo';

/* Login con marca (WP-56, #780).
 *
 * Lo que NO se mueve, porque lo mide e2e/login.spec.js y lo fija
 * LoginScreen.test.tsx: el <form onSubmit>, `#email` y `#password` con su
 * <label for>, el heading con «Crecer Distribuciones» (es el logo: el nombre
 * accesible del <h1> sale de él), el botón «Ingresar» y el orden de
 * Tab email -> contraseña -> botón. Por eso los campos NO pasan por `FormField`:
 * ese primitivo pisa el `id` del hijo con uno de `useId()` y `#email` dejaría de
 * existir. Y por eso tampoco hay acá ningún link ni botón nuevo (un «olvidé mi
 * contraseña» se metería en el recorrido de Tab).
 *
 * Alto contraste: `high-contrast.css` apaga la tarjeta por NOMBRE de clase
 * (`bg-white`, `dark:bg-gray-800`), no por valor. `gray` y `stone` tienen los
 * mismos valores (tailwind.config.js), pero ese CSS sólo conoce `gray`: la
 * superficie de la tarjeta sigue con ese nombre y el resto del texto va en
 * `stone`. El logo no pasa por ahí: es una imagen, y sobre la tarjeta negra del
 * alto contraste oscuro le toca la variante oscura igual que en el modo oscuro. */
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
    } catch (err) {
      const message = err instanceof Error ? err.message : '';
      setError(message.includes('perfil')
        ? message
        : 'Email o contraseña incorrectos');
    }
    setLoading(false);
  };

  return (
    <div className="min-h-screen bg-gradient-to-br from-brand-600 to-brand-800 dark:from-brand-900 dark:to-brand-950 flex items-center justify-center p-4">
      <div className="bg-white dark:bg-gray-800 rounded-2xl shadow-2xl w-full max-w-md p-6 sm:p-8">
        <div className="text-center mb-8">
          <h1>
            <Logo variante="completo" className="mx-auto w-56 sm:w-64" />
          </h1>
          <p className="text-stone-500 dark:text-stone-400 mt-5">Ingresá con tu cuenta</p>
        </div>
        <form onSubmit={handleSubmit} className="space-y-4">
          {/* `role="alert"`: el lector de pantalla lo anuncia al aparecer (#885).
              Al reintentar el error se limpia y vuelve a montarse, así que un
              segundo fallo se anuncia de nuevo. */}
          {error && (
            <div role="alert" className="bg-red-50 dark:bg-red-900/20 text-red-600 dark:text-red-400 px-4 py-3 rounded-lg text-sm">
              {error}
            </div>
          )}
          <div>
            <label htmlFor="email" className="block text-sm font-medium text-stone-700 dark:text-stone-300 mb-1">Email</label>
            <input
              id="email"
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="w-full px-4 py-3 border rounded-lg dark:bg-stone-700 dark:border-stone-600 dark:text-white focus:ring-2 focus:ring-brand-500 focus:border-brand-500"
              placeholder="tu@email.com"
              required
            />
          </div>
          <div>
            <label htmlFor="password" className="block text-sm font-medium text-stone-700 dark:text-stone-300 mb-1">Contraseña</label>
            <input
              id="password"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="w-full px-4 py-3 border rounded-lg dark:bg-stone-700 dark:border-stone-600 dark:text-white focus:ring-2 focus:ring-brand-500 focus:border-brand-500"
              placeholder="••••••••"
              required
            />
          </div>
          <Button type="submit" variant="primary" size="lg" loading={loading} disabled={loading} className="w-full">
            Ingresar
          </Button>
        </form>
      </div>
    </div>
  );
}
