CREATE TABLE support_requests (
  number bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  submission_id uuid NOT NULL,
  content_digest text NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, submission_id)
);

CREATE INDEX support_requests_user_received_idx ON support_requests (user_id, received_at);
