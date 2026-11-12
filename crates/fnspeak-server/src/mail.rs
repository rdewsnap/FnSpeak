//! Outgoing email: SMTP when configured, otherwise the message is logged so
//! a local server works without a mail provider.

use crate::config::SmtpConfig;
use anyhow::Context;
use lettre::message::header::ContentType;
use lettre::message::MultiPart;
use lettre::transport::smtp::authentication::Credentials;
use lettre::{AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor};
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug)]
pub struct Mail {
    pub to: String,
    pub subject: String,
    /// The plain-text version. Every mail has one.
    pub body: String,
    /// The same message laid out with [`html`], for clients that show it.
    pub html: Option<String>,
}

/// What one of the server's emails says, for [`html`].
pub struct Layout<'a> {
    pub heading: &'a str,
    pub intro: &'a str,
    /// A button that opens a page, as `(label, url)`.
    pub button: Option<(&'a str, &'a str)>,
    /// A link to copy rather than open, with the line that says what to do with it.
    pub copy: Option<(&'a str, &'a str)>,
    pub note: &'a str,
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// One of the server's emails as HTML: a single card with the FnSpeak mark,
/// built from tables and inline styles because that is what mail clients
/// render. Everything passed in is escaped.
pub fn html(l: &Layout<'_>) -> String {
    const SANS: &str = "-apple-system,BlinkMacSystemFont,'Helvetica Neue',Helvetica,Arial,sans-serif";
    const MONO: &str = "ui-monospace,Menlo,Consolas,monospace";
    let button = l.button.map_or(String::new(), |(label, url)| {
        format!(
            r##"<table role="presentation" cellpadding="0" cellspacing="0" style="margin:26px 0 6px"><tr><td class="btn" bgcolor="#c4532a" style="border-radius:9px"><a href="{url}" style="display:inline-block;padding:13px 24px;font:600 16px {SANS};color:#ffffff;text-decoration:none">{label}</a></td></tr></table>"##,
            url = esc(url),
            label = esc(label),
        )
    });
    let copy = l.copy.map_or(String::new(), |(lead, url)| {
        format!(
            r##"<p class="soft" style="margin:22px 0 8px;font:14px/1.5 {SANS};color:#6b6a65">{lead}</p><p class="well" style="margin:0;padding:12px 14px;border-radius:8px;background:#f1f0ec;font:13px/1.5 {MONO};color:#141311;word-break:break-all">{url}</p>"##,
            lead = esc(lead),
            url = esc(url),
        )
    });
    format!(
        r##"<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark"><meta name="supported-color-schemes" content="light dark">
<style>@media (prefers-color-scheme: dark) {{ .bg {{ background:#15161a !important }} .card {{ background:#1d1e23 !important }} .ink {{ color:#ecebe6 !important }} .soft {{ color:#b4b2aa !important }} .well {{ background:#15161a !important; color:#ecebe6 !important }} .key {{ background:#ecebe6 !important; color:#15161a !important }} .btn {{ background:#e5693d !important }} .rule {{ border-color:#2d2e34 !important }} }}</style></head>
<body class="bg" style="margin:0;padding:0;background:#f1f0ec">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="bg" style="background:#f1f0ec"><tr><td align="center" style="padding:36px 16px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" class="card" style="max-width:480px;background:#fcfcfb;border-radius:14px"><tr><td style="padding:34px 34px 30px">
<table role="presentation" cellpadding="0" cellspacing="0"><tr>
<td class="key" width="30" height="30" align="center" style="width:30px;height:30px;border-radius:8px;background:#141311;font:700 14px {SANS};color:#fcfcfb">fn</td>
<td class="ink" style="padding-left:8px;font:700 18px {SANS};color:#141311;letter-spacing:-0.01em">&ldquo;speak&rdquo;</td>
</tr></table>
<h1 class="ink" style="margin:28px 0 10px;font:500 24px/1.2 Georgia,'Times New Roman',serif;color:#141311;letter-spacing:-0.01em">{heading}</h1>
<p class="ink" style="margin:0;font:16px/1.55 {SANS};color:#141311">{intro}</p>
{button}{copy}
<p class="soft rule" style="margin:26px 0 0;padding-top:18px;border-top:1px solid #dcdcd8;font:13px/1.5 {SANS};color:#6b6a65">{note}</p>
</td></tr></table>
</td></tr></table>
</body></html>
"##,
        heading = esc(l.heading),
        intro = esc(l.intro),
        note = esc(l.note),
    )
}

/// What a caller is told when an email couldn't be sent. The provider's own
/// words go to the log: they can name the mail host or how the account is
/// set up, which is nobody else's business.
pub fn send_failed(e: anyhow::Error) -> crate::error::ApiError {
    tracing::warn!(error = %e, "couldn't send email");
    crate::error::ApiError::Unavailable("couldn't send the email; try again in a few minutes".into())
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
                let builder = Message::builder()
                    .from(from.parse().context("FNSPEAK_SMTP_FROM is not a valid address")?)
                    .to(mail.to.parse().context("invalid recipient")?)
                    .subject(mail.subject);
                let message = match mail.html {
                    Some(html) => builder.multipart(MultiPart::alternative_plain_html(mail.body, html))?,
                    None => builder.header(ContentType::TEXT_PLAIN).body(mail.body)?,
                };
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

#[cfg(test)]
mod tests {
    use super::{html, send_failed, Layout};

    #[test]
    fn html_escapes_what_people_typed() {
        let page = html(&Layout {
            heading: "x@example.com invited you to <script>alert(1)</script>",
            intro: "Tom & Jerry's team",
            button: Some(("Open", "https://example.com/?a=1&b=\"2\"")),
            copy: Some(("Paste this:", "https://example.com/v1/invites/fsi_abc")),
            note: "Expires in 7 days.",
        });
        assert!(page.contains("&lt;script&gt;alert(1)&lt;/script&gt;"));
        assert!(!page.contains("<script>"));
        assert!(page.contains("Tom &amp; Jerry's team"));
        assert!(page.contains(r#"href="https://example.com/?a=1&amp;b=&quot;2&quot;""#));
        assert!(page.contains("https://example.com/v1/invites/fsi_abc"));
    }

    #[test]
    fn a_failed_send_doesnt_repeat_the_providers_words() {
        let e = anyhow::anyhow!("permanent error (550): The example.com domain is not verified. See https://mail-host.example/domains");
        let shown = send_failed(e).to_string();
        assert_eq!(shown, "couldn't send the email; try again in a few minutes");
        assert!(!shown.contains("550") && !shown.contains("mail-host"));
    }
}
