import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { defineSecret } from "firebase-functions/params";

const feedbackEmailTo = defineSecret("FEEDBACK_EMAIL_TO");
const feedbackSmtpUrl = defineSecret("FEEDBACK_SMTP_URL");

interface FeedbackDoc {
  feedbackId: string;
  sessionId: string;
  userId: string;
  name: string;
  email: string;
  text: string;
  terminalLogURL?: string;
  mediaURLs?: string[];
  mediaTypes?: string[];
  appVersion?: string;
  platform?: string;
}

export const onFeedbackCreated = onDocumentCreated(
  {
    document: "feedback/{feedbackId}",
    region: "us-west1",
    secrets: [feedbackEmailTo, feedbackSmtpUrl],
  },
  async (event) => {
    const data = event.data?.data() as FeedbackDoc | undefined;
    if (!data) return;

    const toEmail = feedbackEmailTo.value();
    const smtpUrl = feedbackSmtpUrl.value();
    if (!toEmail || !smtpUrl) {
      console.warn("FEEDBACK_EMAIL_TO or FEEDBACK_SMTP_URL not configured, skipping email");
      return;
    }

    // Lazy-import nodemailer so the module only loads when this function runs
    const nodemailer = await import("nodemailer");
    const transport = nodemailer.createTransport(smtpUrl);

    const mediaCount = data.mediaURLs?.length ?? 0;
    const hasTerminalLog = !!data.terminalLogURL;

    const html = `
      <h2>New GoVibe Feedback</h2>
      <table style="border-collapse:collapse;">
        <tr><td style="padding:4px 12px 4px 0;font-weight:bold;">From</td><td>${escapeHtml(data.name)} (${escapeHtml(data.email)})</td></tr>
        <tr><td style="padding:4px 12px 4px 0;font-weight:bold;">Session</td><td><code>${escapeHtml(data.sessionId)}</code></td></tr>
        <tr><td style="padding:4px 12px 4px 0;font-weight:bold;">App Version</td><td>${escapeHtml(data.appVersion ?? "unknown")} (${escapeHtml(data.platform ?? "unknown")})</td></tr>
        <tr><td style="padding:4px 12px 4px 0;font-weight:bold;">Attachments</td><td>${mediaCount} media file(s)${hasTerminalLog ? " + terminal log" : ""}</td></tr>
      </table>
      <hr style="margin:16px 0;" />
      <p style="white-space:pre-wrap;">${escapeHtml(data.text)}</p>
      ${data.terminalLogURL ? `<p><a href="${escapeHtml(data.terminalLogURL)}">View Terminal Log</a></p>` : ""}
      ${(data.mediaURLs ?? []).map((url, i) => `<p><a href="${escapeHtml(url)}">Attachment ${i + 1} (${escapeHtml(data.mediaTypes?.[i] ?? "file")})</a></p>`).join("")}
      <hr style="margin:16px 0;" />
      <p style="font-size:12px;color:#888;">Feedback ID: ${escapeHtml(data.feedbackId)}</p>
    `;

    await transport.sendMail({
      from: `"GoVibe Feedback" <${toEmail}>`,
      to: toEmail,
      subject: `GoVibe Feedback from ${data.name}`,
      html,
    });

    console.log(`Feedback email sent for ${data.feedbackId}`);
  }
);

function escapeHtml(str: string): string {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
