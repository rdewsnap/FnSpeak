use super::{Cell, DbError, DbResult, Row, Value};
use rusqlite::types::ValueRef;
use rusqlite::Connection;
use std::sync::{Arc, Mutex};

/// Embedded migrations, applied in order and tracked with `PRAGMA user_version`.
const MIGRATIONS: &[&str] = &[
    include_str!("../../migrations/sqlite/0001_accounts.sql"),
    include_str!("../../migrations/sqlite/0002_invites.sql"),
    include_str!("../../migrations/sqlite/0003_notes_meetings.sql"),
];

/// One connection behind a mutex. SQLite serializes writers anyway, and a
/// self-hosted server's load fits comfortably in a single connection.
pub struct Sqlite {
    conn: Arc<Mutex<Connection>>,
}

impl Sqlite {
    pub async fn open(path: &str) -> DbResult<Self> {
        let path = path.to_string();
        let conn = tokio::task::spawn_blocking(move || -> DbResult<Connection> {
            let in_memory = path == ":memory:" || path.is_empty();
            let mut conn = if in_memory { Connection::open_in_memory()? } else { Connection::open(&path)? };
            if !in_memory {
                conn.pragma_update(None, "journal_mode", "WAL")?;
            }
            conn.pragma_update(None, "foreign_keys", "ON")?;
            conn.busy_timeout(std::time::Duration::from_secs(5))?;
            migrate(&mut conn)?;
            Ok(conn)
        })
        .await
        .map_err(|e| DbError::Other(e.to_string()))??;
        Ok(Sqlite { conn: Arc::new(Mutex::new(conn)) })
    }

    pub async fn query(&self, sql: &str, args: Vec<Value>) -> DbResult<Vec<Row>> {
        let sql = numbered_params(sql);
        self.with_conn(move |conn| {
            let mut stmt = conn.prepare_cached(&sql)?;
            let columns = stmt.column_count();
            bind(&mut stmt, &args)?;
            let mut rows = stmt.raw_query();
            let mut out = Vec::new();
            while let Some(row) = rows.next()? {
                let mut cells = Vec::with_capacity(columns);
                for i in 0..columns {
                    cells.push(match row.get_ref(i)? {
                        ValueRef::Null => Cell::Null,
                        ValueRef::Integer(v) => Cell::Int(v),
                        ValueRef::Real(v) => Cell::Real(v),
                        ValueRef::Text(t) => Cell::Text(String::from_utf8_lossy(t).into_owned()),
                        ValueRef::Blob(b) => Cell::Text(String::from_utf8_lossy(b).into_owned()),
                    });
                }
                out.push(Row(cells));
            }
            Ok(out)
        })
        .await
    }

    pub async fn transaction(&self, stmts: Vec<(String, Vec<Value>)>) -> DbResult<Vec<u64>> {
        self.with_conn(move |conn| {
            let tx = conn.transaction()?;
            let mut changed = Vec::with_capacity(stmts.len());
            for (sql, args) in &stmts {
                let mut stmt = tx.prepare_cached(&numbered_params(sql))?;
                bind(&mut stmt, args)?;
                changed.push(stmt.raw_execute()? as u64);
            }
            tx.commit()?;
            Ok(changed)
        })
        .await
    }

    async fn with_conn<T: Send + 'static>(
        &self,
        f: impl FnOnce(&mut Connection) -> DbResult<T> + Send + 'static,
    ) -> DbResult<T> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.lock().unwrap_or_else(|p| p.into_inner());
            f(&mut conn)
        })
        .await
        .map_err(|e| DbError::Other(e.to_string()))?
    }
}

fn bind(stmt: &mut rusqlite::CachedStatement<'_>, args: &[Value]) -> DbResult<()> {
    for (i, arg) in args.iter().enumerate() {
        match arg {
            Value::Int(v) => stmt.raw_bind_parameter(i + 1, v)?,
            Value::Text(v) => stmt.raw_bind_parameter(i + 1, v)?,
        }
    }
    Ok(())
}

fn migrate(conn: &mut Connection) -> DbResult<()> {
    let current: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
    for (i, sql) in MIGRATIONS.iter().enumerate().skip(current as usize) {
        let tx = conn.transaction()?;
        tx.execute_batch(sql)?;
        tx.pragma_update(None, "user_version", (i + 1) as i64)?;
        tx.commit()?;
    }
    Ok(())
}

/// `$1` → `?1`. SQLite reads `$1` as a *named* parameter bound by order of
/// first appearance; `?1` binds by number, which matches Postgres.
fn numbered_params(sql: &str) -> String {
    let mut out = String::with_capacity(sql.len());
    let mut chars = sql.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '$' && chars.peek().is_some_and(|n| n.is_ascii_digit()) {
            out.push('?');
        } else {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::numbered_params;

    #[test]
    fn rewrites_placeholders() {
        assert_eq!(numbered_params("a = $2 AND b = $1 OR c = $2"), "a = ?2 AND b = ?1 OR c = ?2");
    }
}
