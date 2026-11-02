use super::{Cell, DbResult, Row, Value};
use sqlx::postgres::{PgArguments, PgPool, PgPoolOptions, PgRow};
use sqlx::query::Query;
use sqlx::{AssertSqlSafe, Column, Postgres as Pg, Row as _, SqlSafeStr, TypeInfo};
use sqlx_core::migrate::{Migration, MigrationType, Migrator};
use std::borrow::Cow;

const MIGRATIONS: &[(i64, &str, &str)] = &[
    (1, "accounts", include_str!("../../migrations/postgres/0001_accounts.sql")),
];

pub struct Postgres {
    pool: PgPool,
}

impl Postgres {
    pub async fn connect(url: &str) -> DbResult<Self> {
        let pool = PgPoolOptions::new().max_connections(16).connect(url).await?;
        let migrations = MIGRATIONS
            .iter()
            .map(|(version, name, sql)| {
                Migration::new(*version, Cow::Borrowed(*name), MigrationType::Simple, AssertSqlSafe(*sql).into_sql_str(), false)
            })
            .collect();
        // Older databases have the retired version 5 recorded as applied.
        let mut migrator = Migrator::with_migrations(migrations);
        migrator.set_ignore_missing(true);
        migrator.run(&pool).await?;
        Ok(Postgres { pool })
    }

    pub async fn query(&self, sql: &str, args: Vec<Value>) -> DbResult<Vec<Row>> {
        let rows = bind(sqlx::query(AssertSqlSafe(sql.to_string())), args).fetch_all(&self.pool).await?;
        rows.iter().map(decode).collect()
    }

    pub async fn transaction(&self, stmts: Vec<(String, Vec<Value>)>) -> DbResult<Vec<u64>> {
        let mut tx = self.pool.begin().await?;
        let mut changed = Vec::with_capacity(stmts.len());
        for (sql, args) in stmts {
            let result = bind(sqlx::query(AssertSqlSafe(sql)), args).execute(&mut *tx).await?;
            changed.push(result.rows_affected());
        }
        tx.commit().await?;
        Ok(changed)
    }
}

fn bind(mut q: Query<'_, Pg, PgArguments>, args: Vec<Value>) -> Query<'_, Pg, PgArguments> {
    for arg in args {
        q = match arg {
            Value::Int(v) => q.bind(v),
            Value::Text(v) => q.bind(v),
        };
    }
    q
}

fn decode(row: &PgRow) -> DbResult<Row> {
    let mut cells = Vec::with_capacity(row.columns().len());
    for (i, col) in row.columns().iter().enumerate() {
        let cell = match col.type_info().name() {
            "INT8" => row.try_get::<Option<i64>, _>(i)?.map(Cell::Int),
            "INT4" => row.try_get::<Option<i32>, _>(i)?.map(|v| Cell::Int(v.into())),
            "INT2" => row.try_get::<Option<i16>, _>(i)?.map(|v| Cell::Int(v.into())),
            "BOOL" => row.try_get::<Option<bool>, _>(i)?.map(|v| Cell::Int(v.into())),
            "FLOAT4" => row.try_get::<Option<f32>, _>(i)?.map(|v| Cell::Real(v.into())),
            "FLOAT8" => row.try_get::<Option<f64>, _>(i)?.map(Cell::Real),
            _ => row.try_get::<Option<String>, _>(i)?.map(Cell::Text),
        };
        cells.push(cell.unwrap_or(Cell::Null));
    }
    Ok(Row(cells))
}
