/**
 * ModalConfigDigest: lo que el admin elige es lo que se guarda.
 *
 * El foco está en los bordes que la base rechaza con un CHECK — cero días,
 * cero secciones — y en que "no recibir" sea una salida explícita y no algo
 * que haya que simular dejando todo apagado.
 */
import '@testing-library/jest-dom/vitest';
import { describe, it, expect, vi } from 'vitest';
import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import ModalConfigDigest from './ModalConfigDigest';
import type {
  BotDigestConfig,
  GuardarAvisoAtrasadosInput,
  GuardarConfigDigestInput,
} from '../../hooks/queries/useBotDigestConfig';

const CONFIG_BASE: BotDigestConfig = {
  perfil_id: 'perfil-uno',
  perfil_nombre: 'Julio',
  telegram_user_id: 111,
  sucursal_id: 2,
  sucursal_nombre: 'Taco Pozo',
  configurado: false,
  activo: true,
  hora_local: 7,
  dias_semana: [1, 2, 3, 4, 5, 6, 7],
  secciones: ['ventas', 'top_clientes', 'stock_critico', 'deuda', 'vencimientos'],
  actualizado_at: null,
  actualizado_por: null,
};

function renderModal(config: Partial<BotDigestConfig> = {}) {
  const onGuardar = vi.fn(async (_input: GuardarConfigDigestInput) => {});
  const onGuardarAviso = vi.fn(async (_input: GuardarAvisoAtrasadosInput) => {});
  const onClose = vi.fn();
  render(
    <ModalConfigDigest
      config={{ ...CONFIG_BASE, ...config }}
      onGuardar={onGuardar}
      onGuardarAviso={onGuardarAviso}
      onClose={onClose}
    />,
  );
  return { onGuardar, onGuardarAviso, onClose };
}

describe('ModalConfigDigest', () => {
  it('avisa cuando la configuración es el default y no una elección', async () => {
    renderModal({ configurado: false });
    expect(screen.getByText(/todavía no tiene una configuración propia/i)).toBeInTheDocument();
  });

  it('no muestra ese aviso si ya la configuró', () => {
    renderModal({ configurado: true });
    expect(screen.queryByText(/todavía no tiene una configuración propia/i)).not.toBeInTheDocument();
  });

  it('guarda la hora, los días y las secciones que quedaron elegidos', async () => {
    const user = userEvent.setup();
    const { onGuardar, onClose } = renderModal();

    await user.selectOptions(screen.getByLabelText('Hora'), '19');
    // Apagamos sábado y domingo.
    await user.click(screen.getByRole('button', { name: 'sábado' }));
    await user.click(screen.getByRole('button', { name: 'domingo' }));
    // Y sumamos una sección que estaba apagada.
    await user.click(screen.getByRole('checkbox', { name: /Top productos/i }));

    await user.click(screen.getByRole('button', { name: 'Guardar' }));

    await waitFor(() => expect(onGuardar).toHaveBeenCalledTimes(1));
    expect(onGuardar).toHaveBeenCalledWith({
      perfil_id: 'perfil-uno',
      activo: true,
      hora_local: 19,
      dias_semana: [1, 2, 3, 4, 5],
      secciones: [
        'deuda',
        'stock_critico',
        'top_clientes',
        'top_productos',
        'vencimientos',
        'ventas',
      ],
    });
    await waitFor(() => expect(onClose).toHaveBeenCalled());
  });

  it('sin ningún día no deja guardar y dice por qué', async () => {
    const user = userEvent.setup();
    const { onGuardar } = renderModal({ dias_semana: [1] });

    await user.click(screen.getByRole('button', { name: 'lunes' }));

    expect(screen.getByRole('alert')).toHaveTextContent(/al menos un día/i);
    expect(screen.getByRole('button', { name: 'Guardar' })).toBeDisabled();
    expect(onGuardar).not.toHaveBeenCalled();
  });

  it('sin ninguna sección no deja guardar: un mensaje vacío no es una opción', async () => {
    const user = userEvent.setup();
    const { onGuardar } = renderModal({ secciones: ['ventas'] });

    await user.click(screen.getByRole('checkbox', { name: /Ventas del día/i }));

    expect(screen.getByRole('alert')).toHaveTextContent(/al menos una opción de qué incluir/i);
    expect(screen.getByRole('button', { name: 'Guardar' })).toBeDisabled();
    expect(onGuardar).not.toHaveBeenCalled();
  });

  it('"no recibir" guarda activo=false aunque no haya días ni secciones elegidos', async () => {
    const user = userEvent.setup();
    const { onGuardar } = renderModal({ secciones: ['ventas'] });

    await user.click(screen.getByRole('checkbox', { name: /Ventas del día/i }));
    // Con cero secciones el guardado estaba bloqueado…
    expect(screen.getByRole('button', { name: 'Guardar' })).toBeDisabled();

    // …y marcar "no recibir" lo destraba: es la forma explícita de bajarse.
    await user.click(screen.getByRole('checkbox', { name: /No recibir el resumen/i }));
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Guardar' }));
    await waitFor(() => expect(onGuardar).toHaveBeenCalledTimes(1));
    expect(onGuardar.mock.calls[0][0]).toMatchObject({ activo: false });
  });

  it('si falla el guardado el modal NO se cierra y muestra el error', async () => {
    const user = userEvent.setup();
    const onClose = vi.fn();
    const onGuardar = vi.fn(async (_input: GuardarConfigDigestInput) => {
      throw new Error('El perfil no es un admin vinculado al bot');
    });
    render(
      <ModalConfigDigest config={CONFIG_BASE} onGuardar={onGuardar} onClose={onClose} />,
    );

    await user.click(screen.getByRole('button', { name: 'Guardar' }));

    await waitFor(() =>
      expect(screen.getByRole('alert')).toHaveTextContent(/no es un admin vinculado/i),
    );
    // Lo importante: no se pierde lo que acababa de tildar.
    expect(onClose).not.toHaveBeenCalled();
  });
  // Mig 311: el preventista recibe su propio resumen, con sus secciones.
  describe('preventista', () => {
    const PREVENTISTA: Partial<BotDigestConfig> = {
      perfil_nombre: 'Marcelo',
      rol: 'preventista',
      configurado: false,
      // Sin fila de config la base lo manda apagado: es opt-in.
      activo: false,
      secciones: ['mis_ventas', 'mis_atrasados'],
      secciones_permitidas: ['mis_ventas', 'mis_atrasados'],
    };

    it('ofrece sólo sus secciones, nunca las de la sucursal', () => {
      renderModal(PREVENTISTA);
      expect(screen.getByRole('checkbox', { name: /Sus ventas/i })).toBeInTheDocument();
      expect(screen.getByRole('checkbox', { name: /Sus clientes atrasados/i })).toBeInTheDocument();
      expect(screen.queryByRole('checkbox', { name: /Deuda/i })).not.toBeInTheDocument();
      expect(screen.queryByRole('checkbox', { name: /Ventas del día/i })).not.toBeInTheDocument();
      expect(screen.queryByRole('checkbox', { name: /por preventista/i })).not.toBeInTheDocument();
    });

    it('sin configuración avisa que hoy no recibe nada', () => {
      renderModal(PREVENTISTA);
      expect(screen.getByText(/hoy no recibe ningún resumen/i)).toBeInTheDocument();
      expect(screen.getByRole('checkbox', { name: /No recibir el resumen/i })).toBeChecked();
    });

    it('activarlo guarda sus dos secciones', async () => {
      const user = userEvent.setup();
      const { onGuardar } = renderModal(PREVENTISTA);
      await user.click(screen.getByRole('checkbox', { name: /No recibir el resumen/i }));
      await user.click(screen.getByRole('button', { name: 'Guardar' }));
      await waitFor(() => expect(onGuardar).toHaveBeenCalledTimes(1));
      expect(onGuardar.mock.calls[0][0]).toMatchObject({
        activo: true,
        secciones: ['mis_atrasados', 'mis_ventas'],
      });
    });

    it('ofrece el aviso semanal de clientes atrasados, con su default (lunes 08:00)', () => {
      renderModal(PREVENTISTA);
      expect(screen.getByText(/Aviso semanal de clientes atrasados/i)).toBeInTheDocument();
      expect(screen.getByRole('checkbox', { name: /Recibir el aviso/i })).toBeChecked();
      expect(screen.getByLabelText('Hora del aviso')).toHaveValue('8');
      expect(screen.getByRole('button', { name: 'lunes (aviso)' })).toHaveAttribute('aria-pressed', 'true');
      expect(screen.getByRole('button', { name: 'martes (aviso)' })).toHaveAttribute('aria-pressed', 'false');
    });

    it('guarda el aviso (días ordenados) y también el resumen', async () => {
      const user = userEvent.setup();
      const { onGuardar, onGuardarAviso, onClose } = renderModal({
        ...PREVENTISTA,
        configurado: true,
        activo: true,
      });
      await user.selectOptions(screen.getByLabelText('Hora del aviso'), '9');
      await user.click(screen.getByRole('button', { name: 'jueves (aviso)' }));
      await user.click(screen.getByRole('button', { name: 'martes (aviso)' }));
      await user.click(screen.getByRole('button', { name: 'Guardar' }));

      await waitFor(() => expect(onClose).toHaveBeenCalled());
      expect(onGuardarAviso).toHaveBeenCalledWith({
        perfil_id: 'perfil-uno',
        activo: true,
        hora: 9,
        dias: [1, 2, 4],
      });
      expect(onGuardar).toHaveBeenCalledTimes(1);
    });

    it('con el aviso activo y cero días no deja guardar y dice por qué', async () => {
      const user = userEvent.setup();
      const { onGuardar, onGuardarAviso } = renderModal({ ...PREVENTISTA, activo: true });
      await user.click(screen.getByRole('button', { name: 'lunes (aviso)' }));

      expect(screen.getByRole('alert')).toHaveTextContent(/al menos un día para el aviso/i);
      expect(screen.getByRole('button', { name: 'Guardar' })).toBeDisabled();
      expect(onGuardar).not.toHaveBeenCalled();
      expect(onGuardarAviso).not.toHaveBeenCalled();
    });

    it('con el aviso apagado guarda activo=false aunque no queden días', async () => {
      const user = userEvent.setup();
      const { onGuardarAviso } = renderModal({
        ...PREVENTISTA,
        activo: true,
        aviso_atrasados: { activo: true, hora: 8, dias: [1] },
      });
      await user.click(screen.getByRole('button', { name: 'lunes (aviso)' }));
      await user.click(screen.getByRole('checkbox', { name: /Recibir el aviso/i }));
      await user.click(screen.getByRole('button', { name: 'Guardar' }));

      await waitFor(() => expect(onGuardarAviso).toHaveBeenCalledTimes(1));
      expect(onGuardarAviso.mock.calls[0][0]).toMatchObject({ activo: false, dias: [] });
    });

    it('si falla el aviso el modal NO se cierra, muestra el error y no guarda el resumen', async () => {
      const user = userEvent.setup();
      const onClose = vi.fn();
      const onGuardar = vi.fn(async (_i: GuardarConfigDigestInput) => {});
      const onGuardarAviso = vi.fn(async (_i: GuardarAvisoAtrasadosInput) => {
        throw new Error('Sólo podés configurar a los preventistas de tus sucursales');
      });
      render(
        <ModalConfigDigest
          config={{ ...CONFIG_BASE, ...PREVENTISTA, activo: true }}
          onGuardar={onGuardar}
          onGuardarAviso={onGuardarAviso}
          onClose={onClose}
        />,
      );
      await user.click(screen.getByRole('button', { name: 'Guardar' }));

      await waitFor(() =>
        expect(screen.getByRole('alert')).toHaveTextContent(/preventistas de tus sucursales/i),
      );
      expect(onClose).not.toHaveBeenCalled();
      expect(onGuardar).not.toHaveBeenCalled();
    });

    it('una fila con una sección de otro rol no se vuelve a guardar con ella', async () => {
      const user = userEvent.setup();
      const { onGuardar } = renderModal({
        ...PREVENTISTA,
        configurado: true,
        activo: true,
        secciones: ['deuda', 'mis_ventas'],
      });
      await user.click(screen.getByRole('button', { name: 'Guardar' }));
      await waitFor(() => expect(onGuardar).toHaveBeenCalledTimes(1));
      expect(onGuardar.mock.calls[0][0].secciones).toEqual(['mis_ventas']);
    });
  });

  it('el admin (su propia fila) no tiene aviso de atrasados y no llama a esa RPC', async () => {
    const user = userEvent.setup();
    const { onGuardar, onGuardarAviso } = renderModal({ rol: 'admin', es_propio: true });
    expect(screen.getByText('Tu resumen')).toBeInTheDocument();
    expect(screen.queryByText(/Aviso semanal de clientes atrasados/i)).not.toBeInTheDocument();
    expect(screen.queryByRole('checkbox', { name: /Recibir el aviso/i })).not.toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Guardar' }));
    await waitFor(() => expect(onGuardar).toHaveBeenCalledTimes(1));
    expect(onGuardarAviso).not.toHaveBeenCalled();
  });

  it('un admin no ve las secciones del preventista', () => {
    renderModal({ rol: 'admin' });
    expect(screen.getByRole('checkbox', { name: /Clientes atrasados por preventista/i })).toBeInTheDocument();
    expect(screen.queryByRole('checkbox', { name: /Sus ventas/i })).not.toBeInTheDocument();
  });
});
