-- ══════════════════════════════════════════════════════════════
-- ENERGY SYSTEM — Sync des tags propriétaire → abonnés
-- Lorsqu'un joueur s'abonne à un objet, les tags attribués
-- par le propriétaire sont copiés dans ses tags locaux.
-- Un tag inexistant chez l'abonné est créé à la volée.
-- ══════════════════════════════════════════════════════════════

-- ── Personnages ───────────────────────────────────────────────
-- Appelée après INSERT dans followed_characters.
-- Copie les tags owner (character_tags → tags) vers
-- followed_character_tags (en créant les tags si besoin).

CREATE OR REPLACE FUNCTION public.sync_char_tags_to_follower(
  p_character_id UUID,
  p_follower_id  UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r RECORD;
  v_new_tag_id UUID;
BEGIN
  -- Parcourt tous les tags associés au personnage par son propriétaire
  FOR r IN
    SELECT t.name, t.color
    FROM public.character_tags ct
    JOIN public.tags t ON t.id = ct.tag_id
    WHERE ct.character_id = p_character_id
  LOOP
    -- Cherche si l'abonné possède déjà un tag du même nom
    SELECT id INTO v_new_tag_id
    FROM public.tags
    WHERE user_id = p_follower_id
      AND lower(name) = lower(r.name)
    LIMIT 1;

    -- Sinon, crée-le avec la même couleur que l'original
    IF v_new_tag_id IS NULL THEN
      INSERT INTO public.tags (user_id, name, color)
      VALUES (p_follower_id, r.name, r.color)
      ON CONFLICT (user_id, name) DO NOTHING
      RETURNING id INTO v_new_tag_id;

      -- En cas de conflit (race condition), récupère l'id existant
      IF v_new_tag_id IS NULL THEN
        SELECT id INTO v_new_tag_id
        FROM public.tags
        WHERE user_id = p_follower_id AND lower(name) = lower(r.name)
        LIMIT 1;
      END IF;
    END IF;

    -- Ajoute la liaison dans followed_character_tags (ignore les doublons)
    IF v_new_tag_id IS NOT NULL THEN
      INSERT INTO public.followed_character_tags (user_id, character_id, tag_id)
      VALUES (p_follower_id, p_character_id, v_new_tag_id)
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sync_char_tags_to_follower(UUID, UUID) TO authenticated;


-- ── Documents ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.sync_doc_tags_to_follower(
  p_document_id UUID,
  p_follower_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r RECORD;
  v_new_tag_id UUID;
BEGIN
  FOR r IN
    SELECT t.name, t.color
    FROM public.document_tags dt
    JOIN public.doc_tags t ON t.id = dt.tag_id
    WHERE dt.document_id = p_document_id
  LOOP
    SELECT id INTO v_new_tag_id
    FROM public.doc_tags
    WHERE user_id = p_follower_id
      AND lower(name) = lower(r.name)
    LIMIT 1;

    IF v_new_tag_id IS NULL THEN
      INSERT INTO public.doc_tags (user_id, name, color)
      VALUES (p_follower_id, r.name, r.color)
      ON CONFLICT (user_id, name) DO NOTHING
      RETURNING id INTO v_new_tag_id;

      IF v_new_tag_id IS NULL THEN
        SELECT id INTO v_new_tag_id
        FROM public.doc_tags
        WHERE user_id = p_follower_id AND lower(name) = lower(r.name)
        LIMIT 1;
      END IF;
    END IF;

    IF v_new_tag_id IS NOT NULL THEN
      INSERT INTO public.followed_document_tags (user_id, document_id, tag_id)
      VALUES (p_follower_id, p_document_id, v_new_tag_id)
      ON CONFLICT DO NOTHING;
    END IF;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.sync_doc_tags_to_follower(UUID, UUID) TO authenticated;


-- ── RPC publique : sync_owner_tags ────────────────────────────
-- Point d'entrée appelé depuis le JS via sb.rpc().
-- Paramètres :
--   p_item_type  : 'char' | 'doc'
--   p_item_id    : UUID de l'objet
--
-- Sécurité : vérifie que l'appelant est bien un abonné de l'objet
-- (ou propriétaire, pour forcer une re-sync manuelle).

CREATE OR REPLACE FUNCTION public.sync_owner_tags(
  p_item_type TEXT,
  p_item_id   UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
BEGIN
  IF v_caller_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_authenticated');
  END IF;

  IF p_item_type = 'char' THEN
    -- Vérifie que l'appelant est bien abonné (ou propriétaire)
    IF NOT EXISTS (
      SELECT 1 FROM public.followed_characters
      WHERE user_id = v_caller_id AND character_id = p_item_id
    ) AND NOT EXISTS (
      SELECT 1 FROM public.characters
      WHERE id = p_item_id AND user_id = v_caller_id
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'not_follower');
    END IF;
    PERFORM public.sync_char_tags_to_follower(p_item_id, v_caller_id);

  ELSIF p_item_type = 'doc' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.followed_documents
      WHERE user_id = v_caller_id AND document_id = p_item_id
    ) AND NOT EXISTS (
      SELECT 1 FROM public.documents
      WHERE id = p_item_id AND user_id = v_caller_id
    ) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'not_follower');
    END IF;
    PERFORM public.sync_doc_tags_to_follower(p_item_id, v_caller_id);

  ELSE
    RETURN jsonb_build_object('ok', false, 'error', 'invalid_type');
  END IF;

  RETURN jsonb_build_object('ok', true);
END;
$$;

GRANT EXECUTE ON FUNCTION public.sync_owner_tags(TEXT, UUID) TO authenticated;


-- ══════════════════════════════════════════════════════════════
-- Résumé :
--
--  sync_char_tags_to_follower(char_id, follower_id)
--    Interne. Copie les tags owner d'un personnage vers un abonné.
--    Crée le tag dans la table `tags` de l'abonné si absent.
--
--  sync_doc_tags_to_follower(doc_id, follower_id)
--    Interne. Idem pour les documents (table `doc_tags`).
--
--  sync_owner_tags(type, item_id)   ← appelée depuis le JS
--    Wrapper sécurisé qui vérifie l'abonnement puis délègue.
--
-- Note : les chroniques n'ont pas de système de tags dans le
-- schéma actuel, elles sont donc ignorées ici.
-- ══════════════════════════════════════════════════════════════
