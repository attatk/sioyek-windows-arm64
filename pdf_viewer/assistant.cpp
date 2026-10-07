#include "assistant.h"

#include <algorithm>
#include <memory>

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcessEnvironment>
#include <QUrl>

#ifdef Q_OS_WIN
#include <windows.h>
#endif

#include "book.h"
#include "document.h"

extern std::wstring AI_PROVIDER;
extern std::wstring AI_API_URL;
extern std::wstring AI_API_KEY;
extern std::wstring AI_MODEL;
extern float AI_TEMPERATURE;

#ifdef Q_OS_MACOS
bool macos_is_on_battery();
#endif

QString get_page_plain_text(Document* doc, int page) {
    if (doc == nullptr || page < 0 || page >= doc->num_pages()) return "";

    fz_stext_page* stext_page = doc->get_stext_with_page_number(page);
    if (stext_page == nullptr) return "";

    QString res;
    for (fz_stext_block* block = stext_page->first_block; block != nullptr; block = block->next) {
        if (block->type != FZ_STEXT_BLOCK_TEXT) continue;

        for (fz_stext_line* line = block->u.t.first_line; line != nullptr; line = line->next) {
            bool is_hyphenated = false;
            for (fz_stext_char* chr = line->first_char; chr != nullptr; chr = chr->next) {
                // join words that were hyphenated at the end of a line
                if (chr->next == nullptr && chr->c == '-' && line->next != nullptr) {
                    is_hyphenated = true;
                    continue;
                }
                char32_t c = static_cast<char32_t>(chr->c);
                res.append(QString::fromUcs4(&c, 1));
            }
            if (line->next != nullptr && !is_hyphenated) {
                res.append(' ');
            }
        }
        res.append("\n\n");
    }
    return res.trimmed();
}

QString get_document_display_name(Document* doc) {
    if (doc == nullptr) return "";
    QString paper_name = QString::fromStdWString(doc->get_detected_paper_name_if_exists()).trimmed();
    if (paper_name.size() > 0) return paper_name;
    return QFileInfo(QString::fromStdWString(doc->get_path())).completeBaseName();
}

static QString page_reference(Document* doc, int page) {
    QString label = QString::fromStdWString(doc->get_page_label(page));
    QString res = "p. " + QString::number(page + 1);
    if (label.size() > 0 && label != QString::number(page + 1)) {
        res += " (" + label + ")";
    }
    return res;
}

static QString as_markdown_quote(QString text) {
    text = text.trimmed();
    text.replace("\r\n", "\n");
    return "> " + text.replace("\n", "\n> ");
}

QString annotations_to_markdown(Document* doc) {
    if (doc == nullptr) return "";

    QString res = "# " + get_document_display_name(doc) + "\n\n";
    res += "_Exported from sioyek on " + QDateTime::currentDateTime().toString("yyyy-MM-dd HH:mm") + "_  \n";
    res += "_Source: `" + QString::fromStdWString(doc->get_path()) + "`_\n";

    std::vector<std::pair<int, const BookMark*>> bookmarks;
    for (const BookMark& bm : doc->get_bookmarks()) {
        bookmarks.push_back({ doc->get_offset_page_number(bm.get_y_offset()), &bm });
    }
    std::stable_sort(bookmarks.begin(), bookmarks.end(), [](const auto& lhs, const auto& rhs) {
        return lhs.second->get_y_offset() < rhs.second->get_y_offset();
        });

    if (bookmarks.size() > 0) {
        res += "\n## Bookmarks\n\n";
        for (auto [page, bm] : bookmarks) {
            QString desc = QString::fromStdWString(bm->description).trimmed().replace('\n', ' ');
            res += "- **" + page_reference(doc, page) + "** " + desc + "\n";
        }
    }

    std::vector<Highlight> highlights = doc->get_highlights_sorted();
    if (highlights.size() > 0) {
        res += "\n## Highlights\n";
        int last_page = -1;
        for (const Highlight& hl : highlights) {
            int page = hl.selection_begin.to_document(doc).page;
            if (page != last_page) {
                res += "\n### " + page_reference(doc, page) + "\n";
                last_page = page;
            }
            res += "\n" + as_markdown_quote(QString::fromStdWString(hl.description)) + "\n";
            QString note = QString::fromStdWString(hl.text_annot).trimmed();
            if (note.size() > 0) {
                res += "\n**Note:** " + note + "\n";
            }
            res += "\n<sub>highlight type: " + QString(QChar::fromLatin1(hl.type)) + "</sub>\n";
        }
    }

    if (bookmarks.size() == 0 && highlights.size() == 0) {
        res += "\n_This document has no bookmarks or highlights._\n";
    }

    return res;
}

QString format_duration(qint64 seconds) {
    qint64 hours = seconds / 3600;
    qint64 minutes = (seconds % 3600) / 60;
    if (hours > 0) {
        return QString("%1h %2m").arg(hours).arg(minutes);
    }
    if (minutes > 0) {
        return QString("%1m").arg(minutes);
    }
    return QString("%1s").arg(seconds);
}

bool is_running_on_battery() {
#if defined(Q_OS_WIN)
    SYSTEM_POWER_STATUS status;
    if (GetSystemPowerStatus(&status)) {
        // ACLineStatus is 0 when offline, 1 when online and 255 when unknown
        return status.ACLineStatus == 0;
    }
    return false;
#elif defined(Q_OS_MACOS)
    return macos_is_on_battery();
#elif defined(Q_OS_LINUX) && !defined(SIOYEK_ANDROID)
    QDir power_supply_dir("/sys/class/power_supply");
    bool has_discharging_battery = false;
    for (const QString& name : power_supply_dir.entryList(QDir::Dirs | QDir::NoDotAndDotDot)) {
        auto read_value = [&](const QString& file_name) {
            QFile file(power_supply_dir.filePath(name + "/" + file_name));
            if (!file.open(QIODevice::ReadOnly)) return QString();
            return QString::fromUtf8(file.readAll()).trimmed();
        };
        QString type = read_value("type");
        if (type == "Mains" && read_value("online") == "1") {
            return false;
        }
        if (type == "Battery" && read_value("status") == "Discharging") {
            has_discharging_battery = true;
        }
    }
    return has_discharging_battery;
#else
    return false;
#endif
}

// `ai_api_key` can name an environment variable (e.g. `$OPENAI_API_KEY`) so the key doesn't have to be stored in the config file
static QString resolve_ai_api_key() {
    QString key = QString::fromStdWString(AI_API_KEY).trimmed();
    if (key.startsWith('$')) {
        return QProcessEnvironment::systemEnvironment().value(key.mid(1));
    }
    return key;
}

static bool is_ollama_provider() {
    return QString::fromStdWString(AI_PROVIDER).trimmed().toLower() == "ollama";
}

static QUrl get_ai_chat_url() {
    QString url = QString::fromStdWString(AI_API_URL).trimmed();
    while (url.endsWith('/')) url.chop(1);

    if (is_ollama_provider()) {
        if (!url.endsWith("/api/chat")) url += "/api/chat";
    }
    else {
        if (!url.endsWith("/chat/completions")) url += "/chat/completions";
    }
    return QUrl(url);
}

// extracts the text of a (possibly partial) response object of either API flavor
static QString get_response_text(const QJsonObject& obj) {
    if (obj.contains("choices")) {
        QJsonObject choice = obj["choices"].toArray().at(0).toObject();
        if (choice.contains("delta")) return choice["delta"].toObject()["content"].toString();
        return choice["message"].toObject()["content"].toString();
    }
    return obj["message"].toObject()["content"].toString();
}

static QString get_response_error(const QJsonObject& obj) {
    if (!obj.contains("error")) return "";
    QJsonValue error = obj["error"];
    if (error.isObject()) return error.toObject()["message"].toString();
    return error.toString();
}

QNetworkReply* send_ai_chat_request(QNetworkAccessManager* manager,
    const QString& system_prompt,
    const QString& user_prompt,
    std::function<void(const QString&)> on_text,
    std::function<void(const QString&)> on_finished) {

    QJsonArray messages;
    if (system_prompt.trimmed().size() > 0) {
        messages.append(QJsonObject{ {"role", "system"}, {"content", system_prompt} });
    }
    messages.append(QJsonObject{ {"role", "user"}, {"content", user_prompt} });

    QJsonObject request_body;
    request_body["model"] = QString::fromStdWString(AI_MODEL);
    request_body["messages"] = messages;
    request_body["stream"] = true;
    if (AI_TEMPERATURE >= 0) {
        if (is_ollama_provider()) {
            request_body["options"] = QJsonObject{ {"temperature", AI_TEMPERATURE} };
        }
        else {
            request_body["temperature"] = AI_TEMPERATURE;
        }
    }

    QNetworkRequest req(get_ai_chat_url());
    req.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
    QString api_key = resolve_ai_api_key();
    if (api_key.size() > 0) {
        req.setRawHeader("Authorization", ("Bearer " + api_key).toUtf8());
    }
    // local models can take a long time to load before the first token arrives
    req.setTransferTimeout(5 * 60 * 1000);

    QNetworkReply* reply = manager->post(req, QJsonDocument(request_body).toJson(QJsonDocument::Compact));
    // prevents MainWidget's generic network handler from treating this as a paper download
    reply->setProperty("sioyek_network_request_type", QString("ai_chat"));

    struct StreamState {
        QByteArray pending_line;
        QByteArray full_body;
        QString text;
        QString error;
    };
    auto state = std::make_shared<StreamState>();

    // OpenAI-compatible servers stream server-sent events ("data: {...}" lines),
    // Ollama streams one JSON object per line
    auto handle_line = [state, on_text](QByteArray line) {
        line = line.trimmed();
        if (line.startsWith("data:")) line = line.mid(5).trimmed();
        if (line.size() == 0 || line == "[DONE]" || line.startsWith(':')) return;

        QJsonDocument json = QJsonDocument::fromJson(line);
        if (!json.isObject()) return;

        QJsonObject obj = json.object();
        QString error = get_response_error(obj);
        if (error.size() > 0) {
            state->error = error;
            return;
        }
        QString delta = get_response_text(obj);
        if (delta.size() > 0) {
            state->text += delta;
            on_text(state->text);
        }
    };

    QObject::connect(reply, &QNetworkReply::readyRead, reply, [reply, state, handle_line]() {
        QByteArray data = reply->readAll();
        state->full_body += data;
        state->pending_line += data;
        int newline_index;
        while ((newline_index = state->pending_line.indexOf('\n')) != -1) {
            QByteArray line = state->pending_line.left(newline_index);
            state->pending_line.remove(0, newline_index + 1);
            handle_line(line);
        }
    });

    QObject::connect(reply, &QNetworkReply::finished, reply, [reply, state, handle_line, on_text, on_finished]() {
        state->full_body += reply->readAll();
        handle_line(state->pending_line);
        state->pending_line.clear();

        // some servers ignore `stream` and send a single JSON response
        if (state->text.size() == 0 && state->error.size() == 0) {
            QJsonDocument json = QJsonDocument::fromJson(state->full_body);
            if (json.isObject()) {
                state->error = get_response_error(json.object());
                QString text = get_response_text(json.object());
                if (text.size() > 0) {
                    state->text = text;
                    on_text(text);
                }
            }
        }

        if (reply->error() == QNetworkReply::OperationCanceledError) {
            // the request was aborted (e.g. the response panel was closed)
        }
        else if (reply->error() != QNetworkReply::NoError) {
            QString message = reply->errorString();
            if (state->error.size() > 0) {
                message += "\n\n" + state->error;
            }
            else if (state->full_body.size() > 0) {
                message += "\n\n" + QString::fromUtf8(state->full_body.left(2000));
            }
            on_finished(message);
        }
        else if (state->error.size() > 0) {
            on_finished(state->error);
        }
        else if (state->text.size() == 0) {
            on_finished("The server returned an empty response.");
        }
        else {
            on_finished("");
        }
        reply->deleteLater();
    });

    return reply;
}
