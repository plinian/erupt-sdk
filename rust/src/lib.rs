//! Serve Rust models as erupt admin pages. A node owns models and data; an erupt cloud server renders the
//! UI, logs users in, checks menus and forwards requests here. Wire contract: `erupt-cloud/PROTOCOL.md` in
//! the erupt repository.
//!
//! ```no_run
//! use erupt::{Field, MemoryRepository, Model, Node};
//!
//! let article = Model::new("Article", "Article")
//!     .field("id", Field::pk())
//!     .field("title", Field::input("Title").search().not_null())
//!     .build()
//!     .unwrap();
//! let mut node = Node::new("blog", "<access token>", ["http://erupt-server:8080"]);
//! node.register(&article, MemoryRepository::new()).unwrap();
//! node.serve("0.0.0.0", 9090).unwrap();
//! ```
use std::fmt;

pub mod http;
mod model;
mod node;
mod repo;
pub mod schema;
pub mod signature;
mod sql;
#[rustfmt::skip]
pub mod types;
pub mod values;

pub use model::{DataProxy, Field, Model, ModelBuilder, OpContext, Operation};
pub use node::{current_user, Node, VERSION};
pub use repo::{Cond, Filter, MemoryRepository, Query, Repository};
#[cfg(feature = "mysql")]
pub use sql::MysqlExecutor;
#[cfg(feature = "postgres")]
pub use sql::PostgresExecutor;
#[cfg(feature = "sqlite")]
pub use sql::SqliteExecutor;
pub use sql::{Dialect, SqlExecutor, SqlRepository};

/// A record exchanged with repositories, keyed by field name.
pub type Record = serde_json::Map<String, serde_json::Value>;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug)]
pub enum Error {
    /// Shown to the user as the message of a failed result.
    Fail(String),
    /// A model, field or node declared wrong; raised before anything is served.
    Declaration(String),
    /// Anything else; answered with HTTP 500.
    Other(String),
}

impl Error {
    /// A user-visible failure, e.g. from an operation handler or a repository.
    pub fn fail(message: impl Into<String>) -> Self {
        Error::Fail(message.into())
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Fail(m) | Error::Declaration(m) | Error::Other(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::Other(e.to_string())
    }
}
