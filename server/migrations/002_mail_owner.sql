ALTER TABLE jobs ADD COLUMN user_id uuid REFERENCES users(id) ON DELETE CASCADE;
CREATE INDEX jobs_user ON jobs(user_id);
