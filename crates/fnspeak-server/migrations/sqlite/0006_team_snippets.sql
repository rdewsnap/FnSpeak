-- Trigger phrases that expand to saved text in every member's dictations.
-- The columns are phrase and body because TRIGGER is an SQL keyword.
CREATE TABLE team_snippets (
    id         TEXT PRIMARY KEY,
    team_id    TEXT NOT NULL REFERENCES teams (id) ON DELETE CASCADE,
    phrase     TEXT NOT NULL,
    -- Lowercase words joined by single spaces, as the app matches them.
    phrase_key TEXT NOT NULL,
    body       TEXT NOT NULL,
    added_by   TEXT REFERENCES users (id) ON DELETE SET NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    UNIQUE (team_id, phrase_key)
);
