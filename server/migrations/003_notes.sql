CREATE TABLE notes (
 library_id uuid NOT NULL REFERENCES libraries(id) ON DELETE CASCADE,
 id uuid NOT NULL,
 revision text NOT NULL,
 data bytea NOT NULL,
 PRIMARY KEY (library_id, id)
);
