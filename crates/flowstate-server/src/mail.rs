//! Outgoing email: SMTP when configured, otherwise the message is logged so
//! a local server works without a mail provider.

use crate::config::SmtpConfig;
use anyhow::Context;
use lettre::message::header::ContentType;
use lettre::transport::smtp::authentication::Credentials;
use lettre::{AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor};
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug)]
pub struct Mail {
    pub to: String,
    pub subject: String,
    pub body: String,
}

#[derive(Clone)]
pub enum Mailer {
    Smtp { transport: AsyncSmtpTransport<Tokio1Executor>, from: String },
    Log,
    /// Keeps messages in memory; used by tests to read magic links.
    Memory(Arc<Mutex<Vec<Mail>>>),
}

impl Mailer {
    pub fn from_config(smtp: Option<&SmtpConfig>) -> anyhow::Result<Mailer> {
        let Some(smtp) = smtp else { return Ok(Mailer::Log) };
        let builder = match smtp.security.as_str() {
            "tls" => AsyncSmtpTransport::<Tokio1Executor>::relay(&smtp.host)?,
            "none" => AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(&smtp.host),
            _ => AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(&smtp.host)?,
        };
        let mut builder = builder.port(smtp.port);
        if let (Some(user), Some(pass)) = (&smtp.username, &smtp.password) {
            builder = builder.credentials(Credentials::new(user.clone(), pass.clone()));
        }
        Ok(Mailer::Smtp { transport: builder.build(), from: smtp.from.clone() })
    }

    pub fn memory() -> (Mailer, Arc<Mutex<Vec<Mail>>>) {
        let outbox = Arc::new(Mutex::new(Vec::new()));
        (Mailer::Memory(outbox.clone()), outbox)
    }

    pub async fn send(&self, mail: Mail) -> anyhow::Result<()> {
        match self {
            Mailer::Smtp { transport, from } => {
                let message = Message::builder()
                    .from(from.parse().context("FLOWSTATE_SMTP_FROM is not a valid address")?)
                    .to(mail.to.parse().context("invalid recipient")?)
                    .subject(mail.subject)
                    .header(ContentType::TEXT_PLAIN)
                    .body(mail.body)?;
                transport.send(message).await?;
            }
            Mailer::Log => {
                tracing::info!(to = %mail.to, subject = %mail.subject, "email not sent (no SMTP configured):\n{}", mail.body);
            }
            Mailer::Memory(outbox) => outbox.lock().unwrap_or_else(|p| p.into_inner()).push(mail),
        }
        Ok(())
    }
}
