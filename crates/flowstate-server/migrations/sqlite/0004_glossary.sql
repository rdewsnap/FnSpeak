-- Team vocabulary that members' apps merge into their local vocabulary.
CREATE TABLE glossary_terms (
    id         TEXT PRIMARY KEY,
    team_id    TEXT NOT NULL REFERENCES teams (id) ON DELETE CASCADE,
    term       TEXT NOT NULL,
    -- Lowercased term, so "pgvector" and "PGVector" can't both be added.
    term_key   TEXT NOT NULL,
    added_by   TEXT REFERENCES users (id) ON DELETE SET NULL,
    created_at INTEGER NOT NULL,
    UNIQUE (team_id, term_key)
);
