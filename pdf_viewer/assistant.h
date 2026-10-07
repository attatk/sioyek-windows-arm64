#pragma once

// Helpers for working with LLMs and other external tools: extracting plain text,
// exporting annotations as Markdown and talking to OpenAI-compatible or Ollama chat endpoints.

#include <functional>

#include <QString>

class Document;
class QNetworkAccessManager;
class QNetworkReply;

QString get_page_plain_text(Document* doc, int page);
QString get_document_display_name(Document* doc);
QString annotations_to_markdown(Document* doc);
QString format_duration(qint64 seconds);

// true when the computer is running on battery power (always false when this can not be determined)
bool is_running_on_battery();

// Sends a chat request to the endpoint configured with `ai_provider`, `ai_api_url`, `ai_api_key` and `ai_model`.
// `on_text` is called with the full response text received so far (responses are streamed) and
// `on_finished` is called once with an empty string on success or an error message on failure.
QNetworkReply* send_ai_chat_request(QNetworkAccessManager* manager,
    const QString& system_prompt,
    const QString& user_prompt,
    std::function<void(const QString&)> on_text,
    std::function<void(const QString&)> on_finished);
