CREATE TABLE settings (key text PRIMARY KEY, value jsonb NOT NULL);
INSERT INTO settings VALUES ('maintenance', 'false');
CREATE TABLE users (
 id uuid PRIMARY KEY, email text UNIQUE NOT NULL, password_hash text NOT NULL,
 verified_at timestamptz, deleted_at timestamptz, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE libraries (
 id uuid PRIMARY KEY, owner_id uuid UNIQUE NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 revision bigint NOT NULL DEFAULT 0, min_cursor bigint NOT NULL DEFAULT 0,
 initialized boolean NOT NULL DEFAULT false
);
CREATE TABLE sessions (
 id uuid PRIMARY KEY, user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
 device_id uuid NOT NULL, device_name text NOT NULL, revoked_at timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(), last_used_at timestamptz NOT NULL DEFAULT now(),
 absolute_expires_at timestamptz NOT NULL DEFAULT now()+interval '90 days',
 idle_expires_at timestamptz NOT NULL DEFAULT now()+interval '30 days'
);
CREATE TABLE access_tokens (hash text PRIMARY KEY, session_id uuid NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, expires_at timestamptz NOT NULL);
CREATE TABLE refresh_tokens (hash text PRIMARY KEY, session_id uuid NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, used_at timestamptz, expires_at timestamptz NOT NULL);
CREATE TABLE challenges (
 id uuid PRIMARY KEY, user_id uuid REFERENCES users(id) ON DELETE CASCADE, email text NOT NULL,
 purpose text NOT NULL CHECK(purpose IN ('verify','reset')), code_hash text NOT NULL,
 attempts integer NOT NULL DEFAULT 0, consumed_at timestamptz, expires_at timestamptz NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX challenges_email ON challenges(email,purpose,created_at);
CREATE TABLE limits (key text PRIMARY KEY, count integer NOT NULL, expires_at timestamptz NOT NULL);
CREATE TABLE entities (
 library_id uuid NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
 id uuid NOT NULL, type text NOT NULL CHECK(type IN ('task','folder','checklistItem','attachment')),
 fields jsonb NOT NULL, versions jsonb NOT NULL, deleted boolean NOT NULL DEFAULT false,
 revision bigint NOT NULL, updated_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(library_id,id)
);
CREATE INDEX entities_task ON entities(library_id,(fields->>'taskId'));
CREATE TABLE changes (
 library_id uuid NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
 revision bigint NOT NULL, entity jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
 PRIMARY KEY(library_id,revision)
);
CREATE TABLE operations (
 library_id uuid NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
 id uuid NOT NULL, request_hash text NOT NULL, result jsonb NOT NULL,
 created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(library_id,id)
);
CREATE TABLE imports (
 id uuid PRIMARY KEY, library_id uuid NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
 session_id uuid NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
 committed_at timestamptz, expires_at timestamptz NOT NULL DEFAULT now()+interval '1 day',
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE import_operations (
 import_id uuid NOT NULL REFERENCES imports(id) ON DELETE CASCADE,
 operation_id uuid NOT NULL, body jsonb NOT NULL, request_hash text NOT NULL,
 PRIMARY KEY(import_id,operation_id)
);
CREATE TABLE blobs (
 id uuid PRIMARY KEY, library_id uuid NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
 sha256 text NOT NULL, size bigint NOT NULL, delete_after timestamptz,
 created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(library_id,sha256,size)
);
CREATE TABLE attachment_files (
 library_id uuid NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
 attachment_id uuid NOT NULL, blob_id uuid NOT NULL REFERENCES blobs(id),
 PRIMARY KEY(library_id,attachment_id),
 FOREIGN KEY(library_id,attachment_id) REFERENCES entities(library_id,id) ON DELETE CASCADE
);
CREATE TABLE uploads (
 id uuid PRIMARY KEY, library_id uuid NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
 attachment_id uuid NOT NULL, size bigint NOT NULL, sha256 text NOT NULL,
 completed_at timestamptz, expires_at timestamptz NOT NULL DEFAULT now()+interval '1 day',
 created_at timestamptz NOT NULL DEFAULT now(),
 FOREIGN KEY(library_id,attachment_id) REFERENCES entities(library_id,id) ON DELETE CASCADE
);
CREATE TABLE upload_parts (
 upload_id uuid NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
 part integer NOT NULL, size integer NOT NULL, sha256 text NOT NULL,
 PRIMARY KEY(upload_id,part)
);
CREATE TABLE jobs (
 id uuid PRIMARY KEY, kind text NOT NULL, encrypted_payload text NOT NULL,
 attempts integer NOT NULL DEFAULT 0, available_at timestamptz NOT NULL DEFAULT now(),
 locked_until timestamptz, completed_at timestamptz, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX pending_jobs ON jobs(available_at) WHERE completed_at IS NULL;
