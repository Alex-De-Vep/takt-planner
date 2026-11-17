CREATE FUNCTION notify_closed_note_session() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM pg_notify('takt_note_session_closed', OLD.id::text);
  ELSIF NEW.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at THEN
    PERFORM pg_notify('takt_note_session_closed', NEW.id::text);
  END IF;
  RETURN NULL;
END;
$$;

CREATE TRIGGER notify_closed_note_session
AFTER DELETE OR UPDATE OF revoked_at ON sessions
FOR EACH ROW EXECUTE FUNCTION notify_closed_note_session();
