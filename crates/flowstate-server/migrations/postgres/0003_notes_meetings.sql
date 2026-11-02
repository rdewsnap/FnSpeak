-- Every write to a note or meeting takes the next value of this counter as
-- its `seq`, so clients can pull "everything since seq N" without relying
-- on anyone's clock. `updated_at` (client time) only decides conflicts.
-- The row lock it takes also orders concurrent writers.
CREATE TABLE sync_counter (
    id    BIGINT PRIMARY KEY CHECK (id = 1),
    value BIGINT NOT NULL
);
INSERT INTO sync_counter (id, value) VALUES (1, 0);

CREATE TABLE notes (
    id                  TEXT PRIMARY KEY,
    user_id             TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    shared_with_team_id TEXT REFERENCES teams (id) ON DELETE SET NULL,
    visibility          TEXT NOT NULL DEFAULT 'private' CHECK (visibility IN ('private', 'team')),
    created_at          BIGINT NOT NULL,
    updated_at          BIGINT NOT NULL,
    title               TEXT NOT NULL DEFAULT '',
    body_md             TEXT NOT NULL DEFAULT '',
    source              TEXT NOT NULL DEFAULT '',
    meeting_id          TEXT,
    tags_json           TEXT NOT NULL DEFAULT '[]',
    pinned              BIGINT NOT NULL DEFAULT 0,
    deleted             BIGINT NOT NULL DEFAULT 0,
    seq                 BIGINT NOT NULL,
    search              TSVECTOR GENERATED ALWAYS AS (
        setweight(to_tsvector('simple', title), 'A') || setweight(to_tsvector('simple', body_md), 'B')
    ) STORED
);
CREATE INDEX notes_user_seq ON notes (user_id, seq);
CREATE INDEX notes_team_seq ON notes (shared_with_team_id, seq);
CREATE INDEX notes_search ON notes USING GIN (search);

CREATE TABLE meetings (
    id                  TEXT PRIMARY KEY,
    user_id             TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    shared_with_team_id TEXT REFERENCES teams (id) ON DELETE SET NULL,
    visibility          TEXT NOT NULL DEFAULT 'private' CHECK (visibility IN ('private', 'team')),
    started_at          BIGINT NOT NULL,
    ended_at            BIGINT,
    updated_at          BIGINT NOT NULL,
    title               TEXT NOT NULL DEFAULT '',
    participants_json   TEXT NOT NULL DEFAULT '[]',
    status              TEXT NOT NULL DEFAULT '',
    summary_md          TEXT NOT NULL DEFAULT '',
    action_items_json   TEXT NOT NULL DEFAULT '[]',
    raw_transcript_md   TEXT NOT NULL DEFAULT '',
    deleted             BIGINT NOT NULL DEFAULT 0,
    seq                 BIGINT NOT NULL,
    search              TSVECTOR GENERATED ALWAYS AS (
        setweight(to_tsvector('simple', title), 'A')
        || setweight(to_tsvector('simple', summary_md), 'B')
        || setweight(to_tsvector('simple', raw_transcript_md), 'C')
    ) STORED
);
CREATE INDEX meetings_user_seq ON meetings (user_id, seq);
CREATE INDEX meetings_team_seq ON meetings (shared_with_team_id, seq);
CREATE INDEX meetings_search ON meetings USING GIN (search);

CREATE TABLE segments (
    meeting_id TEXT NOT NULL REFERENCES meetings (id) ON DELETE CASCADE,
    position   BIGINT NOT NULL,
    started_ms BIGINT NOT NULL,
    ended_ms   BIGINT NOT NULL,
    speaker    TEXT NOT NULL DEFAULT '',
    text       TEXT NOT NULL,
    PRIMARY KEY (meeting_id, position)
);
