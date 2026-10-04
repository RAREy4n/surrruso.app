-- ============================================================================
-- Rede de Apoio — Migration: expiração imediata e purge de coordenadas
-- Garante que coordenadas em location_shares sejam zeradas IMEDIATAMENTE
-- no banco de dados assim que a sessão expirar, sem depender exclusivamente
-- do ciclo de 15 minutos do pg_cron.
-- ============================================================================

-- 1. Atualizar location_share_view para zerar coordenadas de sessões expiradas na hora
DROP FUNCTION IF EXISTS public.location_share_view(TEXT);
CREATE OR REPLACE FUNCTION public.location_share_view(viewer_token TEXT)
RETURNS TABLE (
  status          TEXT,          -- 'ativo' | 'aguardando' | 'encerrado' | 'expirado' | 'inexistente'
  label           TEXT,
  latitude        DOUBLE PRECISION,
  longitude       DOUBLE PRECISION,
  accuracy_m      REAL,
  updated_at      TIMESTAMPTZ,
  expires_at      TIMESTAMPTZ
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  s public.location_shares%ROWTYPE;
BEGIN
  SELECT * INTO s
  FROM public.location_shares ls
  WHERE ls.viewer_token_hash = public._ls_hash(viewer_token);

  IF NOT FOUND THEN
    RETURN QUERY SELECT 'inexistente'::TEXT, NULL::TEXT, NULL::DOUBLE PRECISION,
      NULL::DOUBLE PRECISION, NULL::REAL, NULL::TIMESTAMPTZ, NULL::TIMESTAMPTZ;
  ELSIF s.ended_at IS NOT NULL THEN
    -- Garante que se foi encerrada, coordenadas estão limpas no banco
    IF s.last_lat IS NOT NULL THEN
      UPDATE public.location_shares
      SET last_lat = NULL, last_lng = NULL, last_accuracy_m = NULL
      WHERE id = s.id;
    END IF;
    RETURN QUERY SELECT 'encerrado'::TEXT, s.label::TEXT, NULL::DOUBLE PRECISION,
      NULL::DOUBLE PRECISION, NULL::REAL, s.ended_at, s.expires_at;
  ELSIF s.expires_at <= now() THEN
    -- Expiração imediata: limpa as coordenadas da linha do banco instantaneamente
    IF s.last_lat IS NOT NULL THEN
      UPDATE public.location_shares
      SET last_lat = NULL, last_lng = NULL, last_accuracy_m = NULL
      WHERE id = s.id;
    END IF;
    RETURN QUERY SELECT 'expirado'::TEXT, s.label::TEXT, NULL::DOUBLE PRECISION,
      NULL::DOUBLE PRECISION, NULL::REAL, s.expires_at, s.expires_at;
  ELSIF s.last_lat IS NULL THEN
    RETURN QUERY SELECT 'aguardando'::TEXT, s.label::TEXT, NULL::DOUBLE PRECISION,
      NULL::DOUBLE PRECISION, NULL::REAL, NULL::TIMESTAMPTZ, s.expires_at;
  ELSE
    RETURN QUERY SELECT 'ativo'::TEXT, s.label::TEXT, s.last_lat, s.last_lng,
      s.last_accuracy_m, s.last_update_at, s.expires_at;
  END IF;
END;
$$;

-- 2. Atualizar location_share_update para zerar coordenadas se expirada
DROP FUNCTION IF EXISTS public.location_share_update(TEXT, DOUBLE PRECISION, DOUBLE PRECISION, REAL);
CREATE OR REPLACE FUNCTION public.location_share_update(
  publisher_token TEXT,
  lat             DOUBLE PRECISION,
  lng             DOUBLE PRECISION,
  accuracy_m      REAL DEFAULT NULL
)
RETURNS TABLE (
  active     BOOLEAN,
  expires_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  s public.location_shares%ROWTYPE;
BEGIN
  IF lat IS NULL OR lng IS NULL OR lat < -90 OR lat > 90 OR lng < -180 OR lng > 180 THEN
    RAISE EXCEPTION 'coordenada_invalida' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO s
  FROM public.location_shares ls
  WHERE ls.publisher_token_hash = public._ls_hash(publisher_token)
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sessao_inexistente' USING ERRCODE = 'P0002';
  END IF;

  IF s.ended_at IS NOT NULL OR s.expires_at <= now() THEN
    -- Sessão encerrada ou expirada: zera coordenadas no banco na hora
    IF s.last_lat IS NOT NULL THEN
      UPDATE public.location_shares ls
      SET last_lat = NULL, last_lng = NULL, last_accuracy_m = NULL
      WHERE ls.id = s.id;
    END IF;
    RETURN QUERY SELECT false, s.expires_at;
    RETURN;
  END IF;

  -- Ignora envios muito frequentes (menos de 3 s), sem erro.
  IF s.last_update_at IS NULL OR s.last_update_at < now() - INTERVAL '3 seconds' THEN
    UPDATE public.location_shares ls
    SET last_lat = lat,
        last_lng = lng,
        last_accuracy_m = CASE WHEN accuracy_m >= 0 THEN accuracy_m END,
        last_update_at = now()
    WHERE ls.id = s.id;
  END IF;

  RETURN QUERY SELECT true, s.expires_at;
END;
$$;

-- 3. Permissões
REVOKE ALL ON FUNCTION
  public.location_share_update(TEXT, DOUBLE PRECISION, DOUBLE PRECISION, REAL),
  public.location_share_view(TEXT)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
  public.location_share_update(TEXT, DOUBLE PRECISION, DOUBLE PRECISION, REAL),
  public.location_share_view(TEXT)
TO anon, authenticated;
