/**
 * Hook genérico para operaciones CRUD
 *
 * Reduce la duplicación de código en handlers de entidades
 * proporcionando operaciones de guardado, actualización y eliminación
 * con manejo de estados, errores y notificaciones.
 */
import { useCallback } from 'react';
import { withLoadingState, showDeleteConfirmation } from '../utils/errorHandling';
import type { NotifyService, ModalControl, ConfirmModal } from './handlers/types';

// ============================================
// TIPOS
// ============================================

export interface GenericHandlersConfig<T, TInput = Partial<T>> {
  /** Función para crear un nuevo registro */
  create?: (data: TInput) => Promise<T>;
  /** Función para actualizar un registro existente */
  update?: (id: string, data: TInput) => Promise<T>;
  /** Función para eliminar un registro */
  remove?: (id: string) => Promise<void>;
  /** Control del modal de edición */
  modal?: ModalControl;
  /** Control del modal de confirmación */
  confirmModal?: ConfirmModal;
  /** Setter del estado de guardando */
  setLoading?: (loading: boolean) => void;
  /** Setter del registro en edición */
  setEditing?: (item: T | null) => void;
  /** Servicio de notificaciones */
  notify: NotifyService;
  /** Callback después de guardar exitosamente */
  onSaveSuccess?: (item: T) => void;
  /** Callback después de eliminar exitosamente */
  onDeleteSuccess?: () => void;
  /** Mensajes personalizados */
  messages?: {
    createSuccess?: string;
    updateSuccess?: string;
    deleteSuccess?: string;
    deleteConfirmTitle?: string;
    deleteConfirmMessage?: string;
    createError?: string;
    updateError?: string;
    deleteError?: string;
  };
}

export interface GenericHandlersReturn<T, TInput = Partial<T>> {
  /** Handler para guardar (crear o actualizar) */
  handleSave: (data: TInput & { id?: string }) => Promise<void>;
  /** Handler para eliminar con confirmación */
  handleDelete: (id: string, itemName?: string) => void;
  /** Handler para eliminar directamente (sin confirmación) */
  handleDeleteDirect: (id: string) => Promise<void>;
  /** Handler para abrir el modal de edición */
  handleOpenEdit: (item: T) => void;
  /** Handler para abrir el modal de creación */
  handleOpenCreate: () => void;
  /** Handler para cerrar el modal */
  handleClose: () => void;
}

// ============================================
// HOOK
// ============================================

export function useGenericHandlers<T extends { id?: string }, TInput = Partial<T>>(
  config: GenericHandlersConfig<T, TInput>
): GenericHandlersReturn<T, TInput> {
  const {
    create,
    update,
    remove,
    modal,
    confirmModal,
    setLoading = () => {},
    setEditing = () => {},
    notify,
    onSaveSuccess,
    onDeleteSuccess,
    messages = {}
  } = config;

  const {
    createSuccess = 'Creado correctamente',
    updateSuccess = 'Actualizado correctamente',
    deleteSuccess = 'Eliminado correctamente',
    deleteConfirmTitle = 'Confirmar eliminación',
    deleteConfirmMessage = '¿Está seguro de que desea eliminar este elemento?',
    createError = 'Error al crear',
    updateError = 'Error al actualizar',
    deleteError = 'Error al eliminar'
  } = messages;

  /**
   * Handler para guardar (crear o actualizar)
   */
  const handleSave = useCallback(async (data: TInput & { id?: string }): Promise<void> => {
    const isUpdate = Boolean(data.id);

    await withLoadingState(
      setLoading,
      async () => {
        let result: T;
        if (isUpdate && update && data.id) {
          result = await update(data.id, data);
        } else if (create) {
          result = await create(data);
        } else {
          throw new Error('No se proporcionó función de creación/actualización');
        }

        modal?.setOpen(false);
        setEditing(null);
        onSaveSuccess?.(result);

        return result;
      },
      {
        notifyService: notify,
        successMessage: isUpdate ? updateSuccess : createSuccess,
        errorMessage: isUpdate ? updateError : createError
      }
    );
  }, [create, update, modal, setLoading, setEditing, notify, onSaveSuccess, createSuccess, updateSuccess, createError, updateError]);

  /**
   * Handler para eliminar con confirmación
   */
  const handleDelete = useCallback((id: string, itemName?: string): void => {
    if (!confirmModal) {
      console.warn('No se proporcionó modal de confirmación');
      return;
    }

    showDeleteConfirmation({
      titulo: deleteConfirmTitle,
      mensaje: itemName
        ? `¿Está seguro de que desea eliminar "${itemName}"?`
        : deleteConfirmMessage,
      setConfig: confirmModal.setConfig,
      onConfirm: async () => {
        await withLoadingState(
          setLoading,
          async () => {
            if (!remove) throw new Error('No se proporcionó función de eliminación');
            await remove(id);
            onDeleteSuccess?.();
          },
          {
            notifyService: notify,
            successMessage: deleteSuccess,
            errorMessage: deleteError
          }
        );
      }
    });
  }, [remove, confirmModal, setLoading, notify, onDeleteSuccess, deleteConfirmTitle, deleteConfirmMessage, deleteSuccess, deleteError]);

  /**
   * Handler para eliminar directamente (sin confirmación)
   */
  const handleDeleteDirect = useCallback(async (id: string): Promise<void> => {
    await withLoadingState(
      setLoading,
      async () => {
        if (!remove) throw new Error('No se proporcionó función de eliminación');
        await remove(id);
        onDeleteSuccess?.();
      },
      {
        notifyService: notify,
        successMessage: deleteSuccess,
        errorMessage: deleteError
      }
    );
  }, [remove, setLoading, notify, onDeleteSuccess, deleteSuccess, deleteError]);

  /**
   * Handler para abrir el modal de edición
   */
  const handleOpenEdit = useCallback((item: T): void => {
    setEditing(item);
    modal?.setOpen(true);
  }, [setEditing, modal]);

  /**
   * Handler para abrir el modal de creación
   */
  const handleOpenCreate = useCallback((): void => {
    setEditing(null);
    modal?.setOpen(true);
  }, [setEditing, modal]);

  /**
   * Handler para cerrar el modal
   */
  const handleClose = useCallback((): void => {
    modal?.setOpen(false);
    setEditing(null);
  }, [modal, setEditing]);

  return {
    handleSave,
    handleDelete,
    handleDeleteDirect,
    handleOpenEdit,
    handleOpenCreate,
    handleClose
  };
}

export default useGenericHandlers;
