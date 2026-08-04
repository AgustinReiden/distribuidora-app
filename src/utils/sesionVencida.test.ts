import { describe, it, expect, vi, beforeEach } from 'vitest';

const refreshSession = vi.fn();
vi.mock('../lib/supabase', () => ({
  supabase: { auth: { refreshSession: () => refreshSession() } },
}));

const {
  pareceSesionVencida,
  explicarErrorDeSesion,
  MENSAJE_SESION_RENOVADA,
  MENSAJE_SESION_CAIDA,
} = await import('./sesionVencida');

describe('pareceSesionVencida', () => {
  it('reconoce el error de sucursal, que es el síntoma habitual', () => {
    expect(pareceSesionVencida('No se pudo determinar la sucursal activa')).toBe(true);
    // Tal cual llega desde el RPC, con prefijo.
    expect(pareceSesionVencida('Error al crear pedido: No se pudo determinar la sucursal activa')).toBe(true);
  });

  it('reconoce los errores de JWT explícitos', () => {
    expect(pareceSesionVencida('JWT expired')).toBe(true);
    expect(pareceSesionVencida('token is expired')).toBe(true);
    expect(pareceSesionVencida('invalid claim: missing sub')).toBe(true);
  });

  it('no se come errores de negocio', () => {
    expect(pareceSesionVencida('Stock insuficiente en MANAOS COLA 3LT')).toBe(false);
    expect(pareceSesionVencida('La compra mínima de "FIDEO" es 3 unidades')).toBe(false);
    expect(pareceSesionVencida('')).toBe(false);
    expect(pareceSesionVencida(null)).toBe(false);
    expect(pareceSesionVencida(undefined)).toBe(false);
  });
});

describe('explicarErrorDeSesion', () => {
  beforeEach(() => refreshSession.mockReset());

  it('deja pasar sin tocar los errores que no son de sesión', async () => {
    const msg = 'Stock insuficiente en MANAOS COLA 3LT';
    expect(await explicarErrorDeSesion(msg)).toBe(msg);
    expect(refreshSession).not.toHaveBeenCalled();
  });

  it('si la sesión se renueva, avisa que hay que reintentar', async () => {
    refreshSession.mockResolvedValue({ data: { session: { access_token: 'x' } }, error: null });
    expect(await explicarErrorDeSesion('No se pudo determinar la sucursal activa'))
      .toBe(MENSAJE_SESION_RENOVADA);
  });

  it('si no se puede renovar, manda a iniciar sesión de nuevo', async () => {
    refreshSession.mockResolvedValue({ data: { session: null }, error: { message: 'no refresh token' } });
    expect(await explicarErrorDeSesion('No se pudo determinar la sucursal activa'))
      .toBe(MENSAJE_SESION_CAIDA);
  });

  it('sin red, manda a iniciar sesión de nuevo', async () => {
    // supabase-js devuelve el error, no lo tira: así se ve un refresh sin red.
    refreshSession.mockResolvedValue({
      data: { session: null },
      error: { message: 'Failed to fetch' },
    });
    expect(await explicarErrorDeSesion('JWT expired')).toBe(MENSAJE_SESION_CAIDA);
  });
});
