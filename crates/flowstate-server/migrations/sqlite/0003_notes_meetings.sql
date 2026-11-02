-- Every write to a note or meeting takes the next value of this counter as
-- its `seq`, so clients can pull "everything since seq N" without relying
-- on anyone's clock. `updated_at` (client time) only decides conflicts.
CREATE TABLE sync_counter (
    id    INTEGER PRIMARY KEY CHECK (id = 1),
    value INTEGER NOT NULL
);
INSERT INTO sync_counter (id, value) VALUES (1, 0);

-- `pk` exists for the FTS index: an implicit rowid can change on VACUUM.
CREATE TABLE notes (
    pk                  INTEGER PRIMARY KEY,
    id                  TEXT NOT NULL UNIQUE,
    user_id             TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    shared_with_team_id TEXT REFERENCES teams (id) ON DELETE SET NULL,
    visibility          TEXT NOT NULL DEFAULT 'private' CHECK (visibility IN ('private', 'team')),
    created_at          INTEGER NOT NULL,
    updated_at          INTEGER NOT NULL,
    title               TEXT NOT NULL DEFAULT '',
    body_md             TEXT NOT NULL DEFAULT '',
    source              TEXT NOT NULL DEFAULT '',
    meeting_id          TEXT,
    tags_json           TEXT NOT NULL DEFAULT '[]',
    pinned              INTEGER NOT NULL DEFAULT 0,
    deleted             INTEGER NOT NULL DEFAULT 0,
    seq                 INTEGER NOT NULL
);
CREATE INDEX notes_user_seq ON notes (user_id, seq);
CREATE INDEX notes_team_seq ON notes (shared_with_team_id, seq);

CREATE TABLE meetings (
    pk                  INTEGER PRIMARY KEY,
    id                  TEXT NOT NULL UNIQUE,
    user_id             TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    shared_with_team_id TEXT REFERENCES teams (id) ON DELETE SET NULL,
    visibility          TEXT NOT NULL DEFAULT 'private' CHECK (visibility IN ('private', 'team')),
    started_at          INTEGER NOT NULL,
    ended_at            INTEGER,
    updated_at          INTEGER NOT NULL,
    title               TEXT NOT NULL DEFAULT '',
    participants_json   TEXT NOT NULL DEFAULT '[]',
    status              TEXT NOT NULL DEFAULT '',
    summary_md          TEXT NOT NULL DEFAULT '',
    action_items_json   TEXT NOT NULL DEFAULT '[]',
    raw_transcript_md   TEXT NOT NULL DEFAULT '',
    deleted             INTEGER NOT NULL DEFAULT 0,
    seq                 INTEGER NOT NULL
);
CREATE INDEX meetings_user_seq ON meetings (user_id, seq);
CREATE INDEX meetings_team_seq ON meetings (shared_with_team_id, seq);

CREATE TABLE segments (
    meeting_id TEXT NOT NULL REFERENCES meetings (id) ON DELETE CASCADE,
    position   INTEGER NOT NULL,
    started_ms INTEGER NOT NULL,
    ended_ms   INTEGER NOT NULL,
    speaker    TEXT NOT NULL DEFAULT '',
    text       TEXT NOT NULL,
    PRIMARY KEY (meeting_id, position)
);

CREATE VIRTUAL TABLE notes_fts USING fts5(
    title, body_md, content = 'notes', content_rowid = 'pk', tokenize = 'unicode61 remove_diacritics 2'
);
CREATE TRIGGER notes_fts_insert AFTER INSERT ON notes BEGIN
    INSERT INTO notes_fts (rowid, title, body_md) VALUES (new.pk, new.title, new.body_md);
END;
CREATE TRIGGER notes_fts_delete AFTER DELETE ON notes BEGIN
    INSERT INTO notes_fts (notes_fts, rowid, title, body_md) VALUES ('delete', old.pk, old.title, old.body_md);
END;
CREATE TRIGGER notes_fts_update AFTER UPDATE ON notes BEGIN
    INSERT INTO notes_fts (notes_fts, rowid, title, body_md) VALUES ('delete', old.pk, old.title, old.body_md);
    INSERT INTO notes_fts (rowid, title, body_md) VALUES (new.pk, new.title, new.body_md);
END;

CREATE VIRTUAL TABLE meetings_fts USING fts5(
    title, summary_md, raw_transcript_md, content = 'meetings', content_rowid = 'pk',
    tokenize = 'unicode61 remove_diacritics 2'
);
CREATE TRIGGER meetings_fts_insert AFTER INSERT ON meetings BEGIN
    INSERT INTO meetings_fts (rowid, title, summary_md, raw_transcript_md)
    VALUES (new.pk, new.title, new.summary_md, new.raw_transcript_md);
END;
CREATE TRIGGER meetings_fts_delete AFTER DELETE ON meetings BEGIN
    INSERT INTO meetings_fts (meetings_fts, rowid, title, summary_md, raw_transcript_md)
    VALUES ('delete', old.pk, old.title, old.summary_md, old.raw_transcript_md);
END;
CREATE TRIGGER meetings_fts_update AFTER UPDATE ON meetings BEGIN
    INSERT INTO meetings_fts (meetings_fts, rowid, title, summary_md, raw_transcript_md)
    VALUES ('delete', old.pk, old.title, old.summary_md, old.raw_transcript_md);
    INSERT INTO meetings_fts (rowid, title, summary_md, raw_transcript_md)
    VALUES (new.pk, new.title, new.summary_md, new.raw_transcript_md);
END;
