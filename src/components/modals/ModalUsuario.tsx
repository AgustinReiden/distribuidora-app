import { useState, useEffect, memo, useRef } from 'react';
import { z } from 'zod';
import { Loader2, Truck } from 'lucide-react';
import ModalBase from './ModalBase';
import { useZodValidation } from '../../hooks/useZodValidation';
import {
  usePerfilRolesQuery,
  useAsignarPerfilRolesMutation,
} from '../../hooks/queries';
import { useSucursal } from '../../contexts/SucursalContext';
import type { PerfilDB } from '../../types';

// Validación de teléfono. Duplicada de lib/schemas.ts (telefonoSchema) a
// propósito, por la misma razón que el resto del schema: nada de este modal
// puede depender del chunk compartido.
const telefonoSchema = z
  .string()
  .min(8, { message: 'El teléfono debe tener al menos 8 dígitos' })
  .or(z.literal(''))
  .optional()

// Schema CO-LOCADO a propósito (no en lib/schemas.ts): ver ModalCambioProducto.tsx
// para el incidente de chunk desincronizado que motivó la regla.
// eslint-disable-next-line react-refresh/only-export-components
export const usuarioSchema = z.object({
  nombre: z
    .string()
    .min(1, { message: 'El nombre es obligatorio' })
    .transform(val => val.trim())
    .refine(val => val.length >= 2, { message: 'El nombre debe tener al menos 2 caracteres' }),

  email: z
    .string()
    .email({ message: 'Email inválido' })
    .min(1, { message: 'El email es obligatorio' }),

  rol: z.enum(['admin', 'preventista', 'transportista', 'deposito', 'encargado'], {
    error: 'Rol invalido'
  }),

  zona: z.string().optional(),

  telefono: telefonoSchema
})

/** Roles disponibles para usuarios */
export type RolUsuario = 'admin' | 'preventista' | 'transportista' | 'deposito' | 'encargado';

/** Datos del formulario de usuario */
export interface UsuarioFormData {
  id?: string;
  nombre: string;
  email?: string;
  rol: RolUsuario;
  activo: boolean;
  zona: string;
}

/** Props del componente ModalUsuario */
export interface ModalUsuarioProps {
  /** Usuario a editar (null para nuevo) */
  usuario: PerfilDB | null;
  /** Callback al guardar */
  onSave: (data: UsuarioFormData) => void | Promise<void>;
  /** Callback al cerrar */
  onClose: () => void;
  /** Indica si está guardando */
  guardando: boolean;
  /** @deprecated Zonas ahora vienen de useZonasEstandarizadasQuery */
  zonasDisponibles?: string[];
}

const ModalUsuario = memo(function ModalUsuario({ usuario, onSave, onClose, guardando }: ModalUsuarioProps) {
  const formRef = useRef<HTMLDivElement>(null);

  // Zod validation hook
  const { errors, validate, clearFieldError, hasAttemptedSubmit, getAriaProps, getErrorMessageProps } = useZodValidation(usuarioSchema);

  // Capacidades extra en la sucursal activa (mig 155)
  const { currentSucursalNombre } = useSucursal();
  const { data: rolesExtraGuardados } = usePerfilRolesQuery(usuario?.id);
  const asignarRolesMut = useAsignarPerfilRolesMutation();

  const [form, setForm] = useState<UsuarioFormData>(usuario ? {
    id: usuario.id,
    nombre: usuario.nombre || '',
    email: usuario.email,
    rol: (usuario.rol as RolUsuario) || 'preventista',
    activo: usuario.activo !== false,
    zona: usuario.zona || ''
  } : { nombre: '', rol: 'preventista', activo: true, zona: '' });

  // Estado local para las capacidades extra (tabla perfil_roles, mig 155)
  const [puedeLlevarRuta, setPuedeLlevarRuta] = useState<boolean>(false);

  useEffect(() => {
    if (rolesExtraGuardados) {
      setPuedeLlevarRuta(rolesExtraGuardados.includes('transportista'));
    }
  }, [rolesExtraGuardados]);

  // El bloque de capacidades extra no aplica a quien ya las tiene por su rol:
  // el transportista lleva la ruta por definicion y el admin puede todo.
  const mostrarCapacidadesExtra = !!usuario?.id
    && form.rol !== 'transportista'
    && form.rol !== 'admin';

  const handleFieldChange = (field: keyof UsuarioFormData, value: string | boolean): void => {
    setForm({ ...form, [field]: value });
    if (hasAttemptedSubmit && errors[field]) {
      clearFieldError(field);
    }
  };

  const handleSubmit = async (): Promise<void> => {
    const result = validate({
      nombre: form.nombre,
      email: form.email || '',
      rol: form.rol,
      zona: form.zona,
      telefono: '' // Optional field
    });

    if (!result.success) {
      setTimeout(() => {
        const firstError = formRef.current?.querySelector('.border-red-500');
        if (firstError) firstError.scrollIntoView({ behavior: 'smooth', block: 'center' });
      }, 100);
      return;
    }

    // Guardar perfil
    await onSave({ ...form, id: usuario?.id });

    // Guardar capacidades extra de la sucursal activa. Si el rol paso a ser
    // transportista o admin, se limpian: ya las tiene por rol y dejarlas seria
    // ruido en la tabla.
    if (usuario?.id) {
      const roles = mostrarCapacidadesExtra && puedeLlevarRuta ? ['transportista'] : [];
      try {
        await asignarRolesMut.mutateAsync({ usuarioId: usuario.id, roles });
      } catch {
        // Si falla, el perfil ya se guardó
      }
    }
  };

  const inputClass = (field: string): string =>
    `w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white ${errors[field] ? 'border-red-500 bg-red-50 dark:bg-red-900/20' : ''}`;

  return (
    <ModalBase title="Editar Usuario" onClose={onClose}>
      <div ref={formRef} className="p-4 space-y-4">
        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200">Email</label>
          <input
            type="email"
            value={form.email || ''}
            disabled
            className="w-full px-3 py-2 border rounded-lg bg-gray-100 dark:bg-gray-700 dark:border-gray-600 dark:text-gray-400"
          />
        </div>
        <div>
          <label htmlFor="nombre" className="block text-sm font-medium mb-1 dark:text-gray-200">Nombre *</label>
          <input
            id="nombre"
            type="text"
            value={form.nombre}
            onChange={e => handleFieldChange('nombre', e.target.value)}
            className={inputClass('nombre')}
            {...getAriaProps('nombre', true)}
          />
          {errors.nombre && <p {...getErrorMessageProps('nombre')} className="text-red-500 text-xs mt-1">{errors.nombre}</p>}
        </div>
        <div>
          <label htmlFor="rol" className="block text-sm font-medium mb-1 dark:text-gray-200">Rol *</label>
          <select
            id="rol"
            value={form.rol}
            onChange={e => {
              const newRol = e.target.value as RolUsuario;
              const esPreventista = newRol === 'preventista';
              setForm({ ...form, rol: newRol, zona: esPreventista ? form.zona : '' });
              if (hasAttemptedSubmit && errors.rol) clearFieldError('rol');
            }}
            className={inputClass('rol')}
            {...getAriaProps('rol', true)}
          >
            <option value="preventista">Preventista</option>
            <option value="transportista">Transportista</option>
            <option value="deposito">Deposito</option>
            <option value="encargado">Encargado</option>
            <option value="admin">Administrador</option>
          </select>
          {errors.rol && <p {...getErrorMessageProps('rol')} className="text-red-500 text-xs mt-1">{errors.rol}</p>}
        </div>

        {/* Capacidades extra en la sucursal activa (mig 155). Se SUMAN al rol,
            no lo reemplazan: el preventista que acompaña al camion sigue
            vendiendo y ademas reparte. */}
        {mostrarCapacidadesExtra && (
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
              <Truck className="w-4 h-4" />
              Capacidades extra{currentSucursalNombre ? ` en ${currentSucursalNombre}` : ''}
            </label>
            <div className="border dark:border-gray-600 rounded-lg p-3 bg-white dark:bg-gray-700">
              <label className="flex items-start gap-2 text-sm dark:text-gray-200 cursor-pointer">
                <input
                  type="checkbox"
                  checked={puedeLlevarRuta}
                  onChange={e => setPuedeLlevarRuta(e.target.checked)}
                  className="w-4 h-4 rounded mt-0.5"
                />
                <span>
                  Puede llevar la ruta (transportista)
                  <span className="block text-xs text-gray-500 dark:text-gray-400 mt-0.5">
                    Le permite recibir la ruta del dia, marcar entregado y cobrar los pedidos
                    de esa ruta. NO le da acceso a cobrar cuenta corriente desde la ficha
                    del cliente.
                  </span>
                </span>
              </label>
            </div>
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
              Solo aplica a esta sucursal. Debe volver a entrar a la app para que tome efecto.
            </p>
          </div>
        )}

        <div>
          <div className="flex items-center space-x-2">
            <input
              type="checkbox"
              id="activo"
              checked={form.activo}
              onChange={e => handleFieldChange('activo', e.target.checked)}
              className="w-4 h-4"
            />
            <label htmlFor="activo" className="text-sm dark:text-gray-200">Usuario activo</label>
          </div>
          {!form.activo && (
            <p className="text-xs text-amber-700 dark:text-amber-500 mt-1">
              Al desactivarlo no va a poder iniciar sesión y se le cierran las sesiones abiertas.
              No se borra nada: su historial queda intacto y se revierte volviendo a tildarlo.
            </p>
          )}
        </div>
      </div>
      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50 dark:bg-gray-800">
        <button
          onClick={onClose}
          className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg"
        >
          Cancelar
        </button>
        <button
          onClick={handleSubmit}
          disabled={guardando || asignarRolesMut.isPending}
          className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center disabled:opacity-50"
        >
          {(guardando || asignarRolesMut.isPending) && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
          Guardar
        </button>
      </div>
    </ModalBase>
  );
});

export default ModalUsuario;
