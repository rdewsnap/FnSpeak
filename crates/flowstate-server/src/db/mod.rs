//! A thin database layer over SQLite (rusqlite) and, with the `postgres`
//! feature, Postgres (sqlx).
//!
//! Queries are written once in the subset of SQL both engines share, with
//! `$1`-style placeholders. sqlx's own SQLite driver isn't used because it
//! pins a different libsqlite3-sys than flowstate-core, and Cargo only
//! allows one per workspace.

mod sqlite;
#[cfg(feature = "postgres")]
mod postgres;

use std::sync::Arc;

#[derive(Debug, thiserror::Error)]
pub enum DbError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[cfg(feature = "postgres")]
    #[error("postgres: {0}")]
    Postgres(#[from] sqlx::Error),
    #[cfg(feature = "postgres")]
    #[error("migration: {0}")]
    Migrate(#[from] sqlx_core::migrate::MigrateError),
    #[error("{0}")]
    Other(String),
}

impl DbError {
    /// True when a write failed on a UNIQUE or PRIMARY KEY constraint.
    pub fn is_unique_violation(&self) -> bool {
        match self {
            DbError::Sqlite(rusqlite::Error::SqliteFailure(e, _)) => {
                e.extended_code == rusqlite::ffi::SQLITE_CONSTRAINT_UNIQUE
                    || e.extended_code == rusqlite::ffi::SQLITE_CONSTRAINT_PRIMARYKEY
            }
            #[cfg(feature = "postgres")]
            DbError::Postgres(sqlx::Error::Database(e)) => e.code().as_deref() == Some("23505"),
            _ => false,
        }
    }
}

pub type DbResult<T> = Result<T, DbError>;

/// A bound parameter. Nulls are typed so Postgres can infer the column type.
#[derive(Clone, Debug)]
pub enum Value {
    Int(Option<i64>),
    Text(Option<String>),
}

impl From<i64> for Value {
    fn from(v: i64) -> Self {
        Value::Int(Some(v))
    }
}
impl From<Option<i64>> for Value {
    fn from(v: Option<i64>) -> Self {
        Value::Int(v)
    }
}
impl From<bool> for Value {
    fn from(v: bool) -> Self {
        Value::Int(Some(v as i64))
    }
}
impl From<&str> for Value {
    fn from(v: &str) -> Self {
        Value::Text(Some(v.to_string()))
    }
}
impl From<String> for Value {
    fn from(v: String) -> Self {
        Value::Text(Some(v))
    }
}
impl From<&String> for Value {
    fn from(v: &String) -> Self {
        Value::Text(Some(v.clone()))
    }
}
impl From<Option<String>> for Value {
    fn from(v: Option<String>) -> Self {
        Value::Text(v)
    }
}
impl From<Option<&str>> for Value {
    fn from(v: Option<&str>) -> Self {
        Value::Text(v.map(str::to_string))
    }
}
impl From<&Option<String>> for Value {
    fn from(v: &Option<String>) -> Self {
        Value::Text(v.clone())
    }
}

#[macro_export]
macro_rules! args {
    () => { Vec::<$crate::db::Value>::new() };
    ($($v:expr),+ $(,)?) => { vec![$($crate::db::Value::from($v)),+] };
}

#[derive(Clone, Debug, PartialEq)]
pub enum Cell {
    Null,
    Int(i64),
    Real(f64),
    Text(String),
}

#[derive(Clone, Debug)]
pub struct Row(pub Vec<Cell>);

impl Row {
    pub fn int(&self, i: usize) -> i64 {
        self.opt_int(i).unwrap_or(0)
    }

    pub fn opt_int(&self, i: usize) -> Option<i64> {
        match self.0.get(i) {
            Some(Cell::Int(v)) => Some(*v),
            Some(Cell::Real(v)) => Some(*v as i64),
            Some(Cell::Text(s)) => s.parse().ok(),
            _ => None,
        }
    }

    pub fn bool(&self, i: usize) -> bool {
        self.int(i) != 0
    }

    pub fn text(&self, i: usize) -> String {
        self.opt_text(i).unwrap_or_default()
    }

    pub fn opt_text(&self, i: usize) -> Option<String> {
        match self.0.get(i) {
            Some(Cell::Text(s)) => Some(s.clone()),
            Some(Cell::Int(v)) => Some(v.to_string()),
            _ => None,
        }
    }

    pub fn real(&self, i: usize) -> f64 {
        match self.0.get(i) {
            Some(Cell::Real(v)) => *v,
            Some(Cell::Int(v)) => *v as f64,
            _ => 0.0,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    Sqlite,
    #[cfg(feature = "postgres")]
    Postgres,
}

#[derive(Clone)]
pub struct Db {
    inner: Arc<Inner>,
}

enum Inner {
    Sqlite(sqlite::Sqlite),
    #[cfg(feature = "postgres")]
    Postgres(postgres::Postgres),
}

impl Db {
    /// Open the database named by `url` and apply pending migrations.
    /// `sqlite://path`, `sqlite::memory:` or `postgres://…`.
    pub async fn connect(url: &str) -> DbResult<Db> {
        let inner = if url.starts_with("postgres://") || url.starts_with("postgresql://") {
            #[cfg(feature = "postgres")]
            {
                Inner::Postgres(postgres::Postgres::connect(url).await?)
            }
            #[cfg(not(feature = "postgres"))]
            {
                return Err(DbError::Other(
                    "this build has no Postgres support; rebuild with --features postgres".into(),
                ));
            }
        } else if let Some(path) = url.strip_prefix("sqlite://").or_else(|| url.strip_prefix("sqlite:")) {
            Inner::Sqlite(sqlite::Sqlite::open(path).await?)
        } else {
            return Err(DbError::Other(format!("unsupported database URL scheme: {url}")));
        };
        Ok(Db { inner: Arc::new(inner) })
    }

    pub fn backend(&self) -> Backend {
        match &*self.inner {
            Inner::Sqlite(_) => Backend::Sqlite,
            #[cfg(feature = "postgres")]
            Inner::Postgres(_) => Backend::Postgres,
        }
    }

    /// Run one statement; returns the number of rows changed.
    pub async fn execute(&self, sql: &str, args: Vec<Value>) -> DbResult<u64> {
        Ok(self.transaction(vec![(sql.to_string(), args)]).await?[0])
    }

    pub async fn query(&self, sql: &str, args: Vec<Value>) -> DbResult<Vec<Row>> {
        match &*self.inner {
            Inner::Sqlite(db) => db.query(sql, args).await,
            #[cfg(feature = "postgres")]
            Inner::Postgres(db) => db.query(sql, args).await,
        }
    }

    pub async fn query_opt(&self, sql: &str, args: Vec<Value>) -> DbResult<Option<Row>> {
        Ok(self.query(sql, args).await?.into_iter().next())
    }

    pub async fn query_one(&self, sql: &str, args: Vec<Value>) -> DbResult<Row> {
        self.query_opt(sql, args)
            .await?
            .ok_or_else(|| DbError::Other("query returned no rows".into()))
    }

    /// Run statements in one transaction; returns rows changed per statement.
    pub async fn transaction(&self, stmts: Vec<(String, Vec<Value>)>) -> DbResult<Vec<u64>> {
        match &*self.inner {
            Inner::Sqlite(db) => db.transaction(stmts).await,
            #[cfg(feature = "postgres")]
            Inner::Postgres(db) => db.transaction(stmts).await,
        }
    }
}

/// Builds a list of statements for [`Db::transaction`].
#[derive(Default)]
pub struct Batch(pub Vec<(String, Vec<Value>)>);

impl Batch {
    pub fn push(&mut self, sql: impl Into<String>, args: Vec<Value>) -> &mut Self {
        self.0.push((sql.into(), args));
        self
    }
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn new_id() -> String {
    uuid::Uuid::now_v7().to_string()
}
