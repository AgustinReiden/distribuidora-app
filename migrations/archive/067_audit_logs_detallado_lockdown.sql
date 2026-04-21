-- Migration 067: Lock down audit_logs_detallado view.
--
-- Security advisor flagged two ERROR-level criticals on this view:
--   1. auth_users_exposed: view exposes auth.users (via LEFT JOIN on email)
--      to the `anon` role via SELECT privilege.
--   2. security_definer_view: the view runs as its owner, bypassing the RLS
--      policies on audit_logs.
--
-- The combination meant any anonymous client could read every audit row
-- (old_data/new_data snapshots of every mutation) plus the emails of any
-- user whose UUID appeared in audit_logs.usuario_id.
--
-- The app does not reference this view (grep confirmed zero hits under
-- src/); it exists only for manual admin inspection via the Supabase
-- dashboard. Fix: switch to security_invoker so the caller's RLS applies
-- to audit_logs, and revoke everything from anon. Leave authenticated
-- SELECT in place so a future admin UI can query it — RLS on audit_logs
-- will still restrict visible rows to admins.

ALTER VIEW public.audit_logs_detallado SET (security_invoker = true);

REVOKE ALL ON public.audit_logs_detallado FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.audit_logs_detallado FROM authenticated;
