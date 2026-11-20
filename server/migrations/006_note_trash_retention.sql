ALTER TABLE notes ADD COLUMN deleted_at double precision;
ALTER TABLE notes ADD COLUMN purged boolean NOT NULL DEFAULT false;

-- Backfill dates from older clients while preserving opaque payloads.
CREATE FUNCTION read_legacy_note_deletion(payload bytea) RETURNS double precision
LANGUAGE plpgsql STRICT AS $$
DECLARE deleted jsonb;
BEGIN
  deleted := convert_from(payload, 'UTF8')::jsonb -> 'deletedAt';
  IF jsonb_typeof(deleted) = 'number' THEN
    RETURN (deleted::text)::double precision;
  END IF;
  RETURN NULL;
EXCEPTION WHEN data_exception THEN
  RETURN NULL;
END;
$$;

UPDATE notes SET deleted_at = read_legacy_note_deletion(data);
DROP FUNCTION read_legacy_note_deletion(bytea);
CREATE INDEX notes_trash_expiry ON notes(library_id, deleted_at) WHERE NOT purged AND deleted_at IS NOT NULL;
