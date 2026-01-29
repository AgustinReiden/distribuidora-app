import React, { useState, memo, useRef } from 'react';
import { Loader2, MapPin } from 'lucide-react';
import ModalBase from './ModalBase';
import { useZodValidation } from '../../hooks/useZodValidation';
import { usuarioSchema } from '../../lib/schemas';
import type { PerfilDB } from '../../types';

/** Roles disponibles para usuarios */
export type RolUsuario = 'admin' | 'preventista' | 'transportista' | 'deposito';

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
  /** Zonas disponibles para sugerencias */
  zonasDisponibles?: string[];
}

const ModalUsuario = memo(function ModalUsuario({ usuario, onSave, onClose, guardando, zonasDisponibles = [] }: ModalUsuarioProps) {
  const formRef = useRef<HTMLDivElement>(null);

  // Zod validation hook
  const { errors, validate, clearFieldError, hasAttemptedSubmit, getAriaProps, getErrorMessageProps } = useZodValidation(usuarioSchema);

  const [form, setForm] = useState<UsuarioFormData>(usuario ? {
    id: usuario.id,
    nombre: usuario.nombre || '',
    email: usuario.email,
    rol: (usuario.rol as RolUsuario) || 'preventista',
    activo: usuario.activo !== false,
    zona: usuario.zona || ''
  } : { nombre: '', rol: 'preventista', activo: true, zona: '' });

  // Mostrar campo de zona solo para preventistas
  const mostrarZona = form.rol === 'preventista';

  const handleFieldChange = (field: keyof UsuarioFormData, value: string | boolean): void => {
    setForm({ ...form, [field]: value });
    if (hasAttemptedSubmit && errors[field]) {
      clearFieldError(field);
    }
  };

  const handleSubmit = (): void => {
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

    onSave({ ...form, id: usuario?.id });
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
              setForm({ ...form, rol: newRol, zona: newRol !== 'preventista' ? '' : form.zona });
              if (hasAttemptedSubmit && errors.rol) clearFieldError('rol');
            }}
            className={inputClass('rol')}
            {...getAriaProps('rol', true)}
          >
            <option value="preventista">Preventista</option>
            <option value="transportista">Transportista</option>
            <option value="admin">Administrador</option>
          </select>
          {errors.rol && <p {...getErrorMessageProps('rol')} className="text-red-500 text-xs mt-1">{errors.rol}</p>}
        </div>

        {/* Campo de zona solo para preventistas */}
        {mostrarZona && (
          <div>
            <label htmlFor="zona" className="block text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
              <MapPin className="w-4 h-4" />
              Zona Asignada
            </label>
            <input
              id="zona"
              type="text"
              value={form.zona || ''}
              onChange={e => handleFieldChange('zona', e.target.value)}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
              placeholder="Ej: 1, 2, Norte, Centro..."
              list="zonas-list"
            />
            {/* Datalist con zonas existentes de clientes para sugerencias */}
            {zonasDisponibles.length > 0 && (
              <datalist id="zonas-list">
                {zonasDisponibles.map(zona => (
                  <option key={zona} value={zona} />
                ))}
              </datalist>
            )}
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
              El preventista solo verá clientes de esta zona
            </p>
          </div>
        )}

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
          disabled={guardando}
          className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center disabled:opacity-50"
        >
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
          Guardar
        </button>
      </div>
    </ModalBase>
  );
});

export default ModalUsuario;
