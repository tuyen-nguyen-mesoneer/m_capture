// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import Foundation

/// Code-level localization, matching the app's "no assets" convention (no
/// `.strings` files or bundles). The key IS the English string; `L(_:)` returns
/// the translation for the user's primary system language (German or Vietnamese)
/// and the key itself otherwise — so untranslated strings degrade to English
/// instead of to a raw identifier. Strings with runtime values stay `%@`
/// templates, filled with `String(format: L("…"), value)` at the call site.
func L(_ key: String) -> String {
    guard let table = L10n.table else { return key }
    return table[key] ?? key
}

enum L10n {
    /// Resolved once per launch — the whole UI is built with `L(_:)` at
    /// construction time, so a language change applies on relaunch (Settings
    /// offers a restart). The in-app choice (Settings → General → Language)
    /// wins; "system" follows the primary system language. `nil` means English
    /// (keys pass through untranslated).
    static let table: [String: String]? = {
        let lang: String
        switch Settings.shared.appLanguage {
        case .system: lang = Locale.preferredLanguages.first ?? "en"
        case .english: lang = "en"
        case .german: lang = "de"
        case .vietnamese: lang = "vi"
        }
        if lang.hasPrefix("de") { return german }
        if lang.hasPrefix("vi") { return vietnamese }
        return nil
    }()

    /// English → German (Swiss-friendly: "ss" over "ß", macOS-style imperatives).
    static let german: [String: String] = [
        "Language": "Sprache",
        "System": "System",
        "Interface language. \"System\" follows the macOS language; changes apply after a restart.":
            "Sprache der Oberfläche. «System» folgt der macOS-Sprache; Änderungen gelten nach einem Neustart.",
        "Language changed": "Sprache geändert",
        "Restart m_capture to apply the new language.": "m_capture neu starten, um die neue Sprache zu übernehmen.",
        "Restart Now": "Jetzt neu starten",
        "Trim": "Schneiden",
        "History": "Verlauf",
        "HISTORY": "VERLAUF",
        "No captures yet.": "Noch keine Aufnahmen.",
        "Pin to screen": "Anpinnen",
        "Reveal in Finder": "Im Finder zeigen",
        "Move to Trash": "In den Papierkorb legen",
        "Move to Trash?": "In den Papierkorb legen?",
        "Moved to Trash": "In den Papierkorb gelegt",
        "Copied to clipboard": "In die Zwischenablage kopiert",
        "Capture failed. Please try again.": "Aufnahme fehlgeschlagen. Bitte versuchen Sie es erneut.",
        "Recording": "Aufnahme",
        "Discard Recording": "Aufnahme verwerfen",
        "Start with the recording bar minimized": "Aufnahmeleiste minimiert starten",
        "Version %@": "Version %@",
        "MIT License · © mesoneer AG": "MIT-Lizenz · © mesoneer AG",
        // ── Menu bar ─────────────────────────────────────────────────────
        "Stop Recording": "Aufnahme stoppen",
        "Stop & Save as GIF": "Stoppen & als GIF sichern",
        "Stop & Trim…": "Stoppen & schneiden…",
        "Pause Recording": "Aufnahme anhalten",
        "Resume Recording": "Aufnahme fortsetzen",
        "Show Recording Bar": "Aufnahmeleiste einblenden",
        "Screenshot": "Bildschirmfoto",
        "Record Video": "Video aufnehmen",
        "Library": "Bibliothek",
        "Settings": "Einstellungen",
        "Usage Guide": "Kurzanleitung",
        "About": "Info",
        "Check for Updates": "Nach Updates suchen",
        "Report a Bug": "Fehler melden",
        "Quit": "Beenden",
        "Paused": "Pausiert",

        // ── Updater ──────────────────────────────────────────────────────
        "Update available": "Update verfügbar",
        "m_capture %@ is available.": "m_capture %@ ist verfügbar.",
        "Install": "Installieren",
        "Later": "Später",
        "Download": "Laden",
        "Update installed": "Update installiert",
        "m_capture %@ is ready. Click OK to relaunch.": "m_capture %@ ist bereit. Mit OK neu starten.",
        "Up to date": "Alles aktuell",
        "m_capture %@ is the latest version.": "m_capture %@ ist die neueste Version.",
        "Unable to update": "Update fehlgeschlagen",
        "Check the network connection and try again.": "Netzwerkverbindung prüfen und erneut versuchen.",
        "Open Releases": "Releases öffnen",
        "Automatic update checks are failing — check network access to GitHub.": "Automatische Update-Prüfungen schlagen fehl — Netzwerkzugriff auf GitHub prüfen.",

        // ── Permissions ──────────────────────────────────────────────────
        "Screen Recording permission required": "Bildschirmaufnahme-Berechtigung erforderlich",
        "Enable it in System Settings → Privacy & Security → Screen Recording, then try again.":
            "In Systemeinstellungen → Datenschutz & Sicherheit → Bildschirmaufnahme aktivieren, dann erneut versuchen.",
        "Open System Settings": "Systemeinstellungen öffnen",
        "Cancel": "Abbrechen",

        // ── Save / capture alerts ────────────────────────────────────────
        "Unable to save the capture": "Aufnahme konnte nicht gesichert werden",
        "Unable to save the image": "Bild konnte nicht gesichert werden",
        "Saving failed. Check your save folder in Settings → Output.":
            "Sichern fehlgeschlagen. Speicherordner unter Einstellungen → Ausgabe prüfen.",
        "Saved to the Desktop": "Auf dem Schreibtisch gesichert",
        "The save folder was unavailable; the file was saved to the Desktop. Update it in Settings → Output.":
            "Der Speicherordner war nicht verfügbar; die Datei wurde auf dem Schreibtisch gesichert. Unter Einstellungen → Ausgabe anpassen.",
        "Saving failed. The capture remains open — try Save As.":
            "Sichern fehlgeschlagen. Die Aufnahme bleibt geöffnet — «Sichern unter» versuchen.",
        "Discard capture?": "Aufnahme verwerfen?",
        "The screenshot and all edits will be permanently deleted.":
            "Bildschirmfoto und alle Änderungen werden endgültig gelöscht.",
        "Keep Editing": "Weiter bearbeiten",
        "Discard": "Verwerfen",

        // ── Recording alerts ─────────────────────────────────────────────
        "Microphone access denied": "Mikrofonzugriff verweigert",
        "Recording will continue without mic audio.": "Die Aufnahme läuft ohne Mikrofonton weiter.",
        "Recording not saved": "Aufnahme nicht gesichert",
        "Check that the save folder has free space.": "Prüfen, ob im Speicherordner Platz frei ist.",
        "Unable to convert to GIF": "GIF-Umwandlung fehlgeschlagen",
        "The recording was kept as an .mp4.": "Die Aufnahme wurde als .mp4 behalten.",
        "Discard recording?": "Aufnahme verwerfen?",
        "Discard recording": "Aufnahme verwerfen",
        "Shortcut already in use": "Kurzbefehl bereits vergeben",
        "%@ is already used by \"%@\". Choose a different combination.":
            "%@ wird bereits von \"%@\" verwendet. Bitte wählen Sie eine andere Kombination.",
        "This recording will be deleted.": "Diese Aufnahme wird gelöscht.",
        "Keep Recording": "Weiter aufnehmen",
        "Recording stopped": "Aufnahme gestoppt",
        "The recording ended unexpectedly.": "Die Aufnahme wurde unerwartet beendet.",
        " The partial recording was saved.": " Die Teilaufnahme wurde gesichert.",
        "Recording failed to start": "Aufnahme konnte nicht starten",
        "If the Screen Recording permission was reset, re-approve it in System Settings and try again.":
            "Wurde die Bildschirmaufnahme-Berechtigung zurückgesetzt, in den Systemeinstellungen erneut erlauben und nochmals versuchen.",
        "Unable to trim the recording": "Schneiden fehlgeschlagen",
        "The full recording was kept unchanged.": "Die vollständige Aufnahme blieb unverändert.",

        // ── Trim panel ───────────────────────────────────────────────────
        "TRIM RECORDING": "AUFNAHME SCHNEIDEN",
        "Keep Full Recording": "Ganze Aufnahme behalten",
        "Save": "Sichern",
        "Saving…": "Sichern…",
        "(%@ kept)": "(%@ behalten)",
        "Trim range": "Schnittbereich",

        // ── Record bar ───────────────────────────────────────────────────
        "Pause": "Pause",
        "Resume": "Weiter",
        "Stop": "Stopp",
        "Minimize": "Minimieren",

        // ── Pin window menu ──────────────────────────────────────────────
        "Copy": "Kopieren",
        "Reset size": "Grösse zurücksetzen",
        "Close": "Schliessen",

        // ── Selection overlay ────────────────────────────────────────────
        "Region": "Bereich",
        "Window": "Fenster",
        "Screen": "Bildschirm",
        "Space to cycle": "Leertaste wechselt",
        "⏎ last region": "⏎ letzter Bereich",

        // ── Settings window ──────────────────────────────────────────────
        "General": "Allgemein",
        "Shortcuts": "Kurzbefehle",
        "Capture": "Aufnahme",
        "Output": "Ausgabe",
        "Video": "Video",
        "Capture delay": "Auslöseverzögerung",
        "After capture": "Nach der Aufnahme",
        "Save to": "Sichern unter",
        "Filename prefix": "Dateinamen-Präfix",
        "Format": "Format",
        "Background": "Hintergrund",
        "Padding": "Randabstand",
        "Corner radius": "Eckenradius",
        "Quality": "Qualität",
        "Audio": "Audio",
        "Frame rate": "Bildrate",
        "Countdown": "Countdown",
        "Launch m_capture at login": "m_capture beim Anmelden starten",
        "Hide the Dock icon": "Dock-Symbol ausblenden",
        "Include the mouse cursor in captures": "Mauszeiger in Aufnahmen zeigen",
        "Play the shutter sound when capturing": "Auslöserton abspielen",
        "Ask before discarding a capture": "Vor dem Verwerfen nachfragen",
        "Also copy to clipboard when saving": "Beim Sichern auch kopieren",
        "Show mouse clicks in recordings": "Mausklicks in Aufnahmen zeigen",
        "Choose…": "Auswählen…",
        "Choose": "Auswählen",
        "Filename prefix saved": "Dateinamen-Präfix gesichert",
        "Delay before the selection overlay appears — time to open menus or prepare the screen.":
            "Verzögerung, bis die Auswahl erscheint — Zeit, um Menüs zu öffnen oder die Szene vorzubereiten.",
        "Action performed immediately after capture: open the editor, save to a file, or copy to the clipboard.":
            "Aktion direkt nach der Aufnahme: Editor öffnen, als Datei sichern oder in die Zwischenablage kopieren.",
        "Space around the screenshot inside a background frame. Applies only when a background is selected.":
            "Rand um das Bildschirmfoto im Hintergrund-Rahmen. Gilt nur mit gewähltem Hintergrund.",
        "Corner rounding when a background frame is applied (Square = none). Applies only when a background is selected.":
            "Eckenrundung bei gewähltem Hintergrund (Eckig = keine). Gilt nur mit Hintergrund.",
        "Background frame preselected when the editor opens; adjustable per capture.":
            "Beim Öffnen des Editors vorgewählter Hintergrund; pro Aufnahme änderbar.",
        "60 fps captures motion more smoothly at roughly twice the file size.":
            "60 fps zeichnet Bewegung flüssiger auf, bei etwa doppelter Dateigrösse.",
        "Countdown shown over the selected region before recording starts.":
            "Countdown über dem gewählten Bereich, bevor die Aufnahme startet.",
        "Drag to select a region, or press Space to capture a window or screen.":
            "Bereich aufziehen oder Leertaste für Fenster / Bildschirm.",
        "Drag to select a region, or press Space to record a window or screen.":
            "Bereich aufziehen oder Leertaste für Fenster / Bildschirm — zum Aufnehmen.",
        "Captures the screen under the pointer immediately, with no overlay or delay — useful for transient menus and tooltips.":
            "Nimmt den Bildschirm unter dem Zeiger sofort auf — ohne Auswahl, ohne Verzögerung — ideal für flüchtige Menüs und Tooltips.",
        "Force-quits m_capture and any duplicate instances — use if the menu bar icon is stuck or duplicated.":
            "Beendet m_capture und doppelte Instanzen sofort — falls das Menüleisten-Symbol hängt oder doppelt erscheint.",

        // ── Settings enum labels ─────────────────────────────────────────
        "None": "Ohne",
        // ── Color / background names ─────────────────────────────────────
        "Red": "Rot",
        "Orange": "Orange",
        "Yellow": "Gelb",
        "Green": "Grün",
        "Blue": "Blau",
        "Purple": "Violett",
        "Pink": "Pink",
        "White": "Weiss",
        "Black": "Schwarz",
        "Light": "Hell",
        "Dark": "Dunkel",
        "Lavender": "Lavendel",
        "Sunset": "Sonnenuntergang",
        "Ocean": "Ozean",
        "Forest": "Wald",
        "Candy": "Candy",
        "Midnight": "Mitternacht",
        "Custom": "Eigene",
        "Open editor": "Editor öffnen",
        "Save to file": "In Datei sichern",
        "Copy to clipboard": "In Zwischenablage kopieren",
        "Record": "Aufnehmen",
        "Force Quit": "Sofort beenden",
        "Small": "Klein",
        "Medium": "Mittel",
        "Large": "Gross",
        "Square": "Eckig",
        "High (8 Mbps)": "Hoch (8 Mbit/s)",
        "Medium (4 Mbps)": "Mittel (4 Mbit/s)",
        "Low (2 Mbps)": "Niedrig (2 Mbit/s)",
        "System Audio": "Systemaudio",
        "Microphone": "Mikrofon",
        "System + Mic": "System + Mikrofon",

        // ── Editor cluster captions ──────────────────────────────────────
        "Markup": "Markieren",
        "Shape": "Form",
        "Style": "Stil",
        "Action": "Aktion",

        // ── Editor tooltips ──────────────────────────────────────────────
        "Overlay image — paste (⌘V), drop a file, or click to choose":
            "Bild einblenden — einsetzen (⌘V), Datei fallen lassen oder klicken zum Auswählen",
        "Counter — place numbered badges (click again to change format)  (C)":
            "Zähler — nummerierte Marken setzen (erneut klicken fürs Format)  (C)",
        "Emoji — stamp an emoji (click to choose)": "Emoji — ein Emoji stempeln (klicken zum Auswählen)",
        "Pencil — freehand draw  (P)": "Stift — freihand zeichnen  (P)",
        "Highlighter — translucent highlight  (H)": "Textmarker — transparente Hervorhebung  (H)",
        "Eraser — click a mark to remove it  (E)": "Radierer — Markierung anklicken zum Entfernen  (E)",
        "Text — click and type a label  (T)": "Text — klicken und Beschriftung tippen  (T)",
        "Blur — obscure sensitive content  (B)":
            "Weichzeichnen — sensible Inhalte unkenntlich machen  (B)",
        "Spotlight — dim everything around an area  (S)":
            "Spotlight — alles um einen Bereich abdunkeln  (S)",
        "Zoom — magnify a region into a callout  (Z)": "Lupe — Bereich vergrössert hervorheben  (Z)",
        "Ruler — drag to measure  (hold ⇧ to snap horizontal/vertical)":
            "Lineal — ziehen zum Messen  (⇧ rastet horizontal/vertikal ein)",
        "Copy text / QR (OCR) — drag over text or a QR code  (⌘T)":
            "Text / QR kopieren (OCR) — über Text oder QR-Code ziehen  (⌘T)",
        "Arrow — point to an area  (A)": "Pfeil — auf einen Bereich zeigen  (A)",
        "Line — straight line  (L)": "Linie — gerade Linie  (L)",
        "Rectangle — box outline  (R)": "Rechteck — Rahmen  (R)",
        "Ellipse — oval outline  (O)": "Ellipse — ovaler Rahmen  (O)",
        "Rounded rectangle — rounded box  (U)": "Abgerundetes Rechteck  (U)",
        "Triangle — triangle outline  (G)": "Dreieck  (G)",
        "Diamond — diamond outline  (D)": "Raute  (D)",
        "Star — 5-point star outline  (Y)": "Stern — 5-zackiger Stern  (Y)",
        "Checkmark — check mark  (K)": "Häkchen  (K)",
        "Pentagon — 5-sided outline  (5)": "Fünfeck  (5)",
        "Hexagon — 6-sided outline  (6)": "Sechseck  (6)",
        "Octagon — 8-sided outline  (8)": "Achteck  (8)",
        "Eyedropper — pick a color from the image  (I)": "Pipette — Farbe aus dem Bild aufnehmen  (I)",
        "%@ color": "Farbe %@",
        "Custom color — pick any hue": "Eigene Farbe — beliebigen Ton wählen",
        "Stroke width: %@ — click to cycle": "Strichstärke: %@ — klicken zum Wechseln",
        "Move — drag an object to reposition, drag its corner to resize, ⌫ to delete  (V)":
            "Verschieben — Objekt ziehen, an der Ecke skalieren, ⌫ löscht  (V)",
        "Crop — drag a region, then ↵ or ✓": "Zuschneiden — Bereich aufziehen, dann ↵ oder ✓",
        "Rotate right 90°": "90° nach rechts drehen",
        "Flip horizontal": "Horizontal spiegeln",
        "Undo  (⌘Z)": "Widerrufen  (⌘Z)",
        "Redo  (⇧⌘Z)": "Wiederholen  (⇧⌘Z)",
        "Pin to screen — keep on top  (⌘P)": "Anpinnen — immer im Vordergrund  (⌘P)",
        "Before/After GIF — animate overlays on/off": "Vorher/Nachher-GIF — Markierungen ein-/ausblenden",
        "Copy & close  (⌘C)": "Kopieren & schliessen  (⌘C)",
        "Save & close  (⌘S)": "Sichern & schliessen  (⌘S)",
        "Save As… — choose location  (⇧⌘S)": "Sichern unter… — Ort wählen  (⇧⌘S)",
        "Cancel  (Esc)": "Abbrechen  (Esc)",
        "Custom color": "Eigene Farbe",
    ]

    /// English → Vietnamese (concise, macOS-style imperatives). Same key set as
    /// `german` — the key-set parity is what keeps the three languages honest.
    static let vietnamese: [String: String] = [
        "Language": "Ngôn ngữ",
        "System": "Hệ thống",
        "Interface language. \"System\" follows the macOS language; changes apply after a restart.":
            "Ngôn ngữ giao diện. \"Hệ thống\" theo ngôn ngữ macOS; thay đổi có hiệu lực sau khi khởi động lại.",
        "Language changed": "Đã đổi ngôn ngữ",
        "Restart m_capture to apply the new language.": "Khởi động lại m_capture để áp dụng ngôn ngữ mới.",
        "Restart Now": "Khởi động lại ngay",
        "Trim": "Cắt",
        "History": "Lịch sử",
        "HISTORY": "LỊCH SỬ",
        "No captures yet.": "Chưa có ảnh chụp nào.",
        "Pin to screen": "Ghim lên màn hình",
        "Reveal in Finder": "Hiện trong Finder",
        "Move to Trash": "Chuyển vào Thùng rác",
        "Move to Trash?": "Chuyển vào Thùng rác?",
        "Moved to Trash": "Đã chuyển vào Thùng rác",
        "Copied to clipboard": "Đã sao chép vào bảng nhớ tạm",
        "Capture failed. Please try again.": "Chụp màn hình không thành công. Vui lòng thử lại.",
        "Recording": "Bản ghi hình",
        "Discard Recording": "Huỷ bản ghi",
        "Start with the recording bar minimized": "Bắt đầu với thanh ghi hình thu nhỏ",
        "Version %@": "Phiên bản %@",
        "MIT License · © mesoneer AG": "Giấy phép MIT · © mesoneer AG",
        // ── Menu bar ─────────────────────────────────────────────────────
        "Stop Recording": "Dừng ghi hình",
        "Stop & Save as GIF": "Dừng & lưu thành GIF",
        "Stop & Trim…": "Dừng & cắt…",
        "Pause Recording": "Tạm dừng ghi hình",
        "Resume Recording": "Tiếp tục ghi hình",
        "Show Recording Bar": "Hiện thanh ghi hình",
        "Screenshot": "Chụp màn hình",
        "Record Video": "Quay video",
        "Library": "Thư viện",
        "Settings": "Cài đặt",
        "Usage Guide": "Hướng dẫn sử dụng",
        "About": "Giới thiệu",
        "Check for Updates": "Kiểm tra bản cập nhật",
        "Report a Bug": "Báo lỗi",
        "Quit": "Thoát",
        "Paused": "Đang tạm dừng",

        // ── Updater ──────────────────────────────────────────────────────
        "Update available": "Có bản cập nhật",
        "m_capture %@ is available.": "Đã có m_capture %@.",
        "Install": "Cài đặt",
        "Later": "Để sau",
        "Download": "Tải về",
        "Update installed": "Đã cài bản cập nhật",
        "m_capture %@ is ready. Click OK to relaunch.": "m_capture %@ đã sẵn sàng. Bấm OK để khởi động lại.",
        "Up to date": "Đang dùng phiên bản mới nhất",
        "m_capture %@ is the latest version.": "m_capture %@ là phiên bản mới nhất.",
        "Unable to update": "Không thể cập nhật",
        "Check the network connection and try again.": "Kiểm tra kết nối mạng rồi thử lại.",
        "Automatic update checks are failing — check network access to GitHub.": "Kiểm tra cập nhật tự động đang thất bại — hãy kiểm tra kết nối mạng tới GitHub.",
        "Open Releases": "Mở trang Releases",

        // ── Permissions ──────────────────────────────────────────────────
        "Screen Recording permission required": "Cần quyền Ghi màn hình",
        "Enable it in System Settings → Privacy & Security → Screen Recording, then try again.":
            "Bật trong Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Ghi màn hình, rồi thử lại.",
        "Open System Settings": "Mở Cài đặt hệ thống",
        "Cancel": "Huỷ",

        // ── Save / capture alerts ────────────────────────────────────────
        "Unable to save the capture": "Không thể lưu ảnh chụp",
        "Unable to save the image": "Không thể lưu hình ảnh",
        "Saving failed. Check your save folder in Settings → Output.":
            "Lưu thất bại. Kiểm tra thư mục lưu trong Cài đặt → Xuất.",
        "Saved to the Desktop": "Đã lưu vào Desktop",
        "The save folder was unavailable; the file was saved to the Desktop. Update it in Settings → Output.":
            "Thư mục lưu không khả dụng; tệp đã được lưu vào Desktop. Cập nhật trong Cài đặt → Xuất.",
        "Saving failed. The capture remains open — try Save As.":
            "Lưu thất bại. Ảnh chụp vẫn đang mở — hãy thử «Lưu thành».",
        "Discard capture?": "Huỷ ảnh chụp?",
        "The screenshot and all edits will be permanently deleted.":
            "Ảnh chụp và mọi chỉnh sửa sẽ bị xoá vĩnh viễn.",
        "Keep Editing": "Tiếp tục chỉnh sửa",
        "Discard": "Huỷ bỏ",

        // ── Recording alerts ─────────────────────────────────────────────
        "Microphone access denied": "Bị từ chối truy cập micrô",
        "Recording will continue without mic audio.": "Bản ghi sẽ tiếp tục mà không có âm thanh micrô.",
        "Recording not saved": "Bản ghi chưa được lưu",
        "Check that the save folder has free space.": "Kiểm tra thư mục lưu còn dung lượng trống.",
        "Unable to convert to GIF": "Không thể chuyển thành GIF",
        "The recording was kept as an .mp4.": "Bản ghi được giữ dưới dạng .mp4.",
        "Discard recording?": "Huỷ bản ghi?",
        "Discard recording": "Huỷ bản ghi",
        "Shortcut already in use": "Phím tắt đã được sử dụng",
        "%@ is already used by \"%@\". Choose a different combination.":
            "%@ đã được dùng cho \"%@\". Vui lòng chọn tổ hợp khác.",
        "This recording will be deleted.": "Bản ghi này sẽ bị xoá.",
        "Keep Recording": "Tiếp tục ghi",
        "Recording stopped": "Đã dừng ghi hình",
        "The recording ended unexpectedly.": "Bản ghi kết thúc ngoài dự kiến.",
        " The partial recording was saved.": " Phần đã ghi được lưu lại.",
        "Recording failed to start": "Không thể bắt đầu ghi hình",
        "If the Screen Recording permission was reset, re-approve it in System Settings and try again.":
            "Nếu quyền Ghi màn hình vừa bị đặt lại, hãy cấp lại trong Cài đặt hệ thống rồi thử lại.",
        "Unable to trim the recording": "Không thể cắt bản ghi",
        "The full recording was kept unchanged.": "Bản ghi đầy đủ được giữ nguyên.",

        // ── Trim panel ───────────────────────────────────────────────────
        "TRIM RECORDING": "CẮT BẢN GHI",
        "Keep Full Recording": "Giữ toàn bộ bản ghi",
        "Save": "Lưu",
        "Saving…": "Đang lưu…",
        "(%@ kept)": "(giữ %@)",
        "Trim range": "Vùng cắt",

        // ── Record bar ───────────────────────────────────────────────────
        "Pause": "Tạm dừng",
        "Resume": "Tiếp tục",
        "Stop": "Dừng",
        "Minimize": "Thu nhỏ",

        // ── Pin window menu ──────────────────────────────────────────────
        "Copy": "Sao chép",
        "Reset size": "Đặt lại kích thước",
        "Close": "Đóng",

        // ── Selection overlay ────────────────────────────────────────────
        "Region": "Vùng chọn",
        "Window": "Cửa sổ",
        "Screen": "Màn hình",
        "Space to cycle": "Space để đổi chế độ",
        "⏎ last region": "⏎ vùng chọn trước",

        // ── Settings window ──────────────────────────────────────────────
        "General": "Chung",
        "Shortcuts": "Phím tắt",
        "Capture": "Chụp",
        "Output": "Xuất",
        "Video": "Video",
        "Capture delay": "Trễ khi chụp",
        "After capture": "Sau khi chụp",
        "Save to": "Lưu vào",
        "Filename prefix": "Tiền tố tên tệp",
        "Format": "Định dạng",
        "Background": "Nền",
        "Padding": "Khoảng đệm",
        "Corner radius": "Bo góc",
        "Quality": "Chất lượng",
        "Audio": "Âm thanh",
        "Frame rate": "Tốc độ khung hình",
        "Countdown": "Đếm ngược",
        "Launch m_capture at login": "Khởi động m_capture khi đăng nhập",
        "Hide the Dock icon": "Ẩn biểu tượng Dock",
        "Include the mouse cursor in captures": "Hiện con trỏ chuột trong ảnh chụp",
        "Play the shutter sound when capturing": "Phát âm thanh màn trập khi chụp",
        "Ask before discarding a capture": "Hỏi trước khi huỷ ảnh chụp",
        "Also copy to clipboard when saving": "Sao chép vào bảng nhớ tạm khi lưu",
        "Show mouse clicks in recordings": "Hiện cú bấm chuột trong bản ghi",
        "Choose…": "Chọn…",
        "Choose": "Chọn",
        "Filename prefix saved": "Đã lưu tiền tố tên tệp",
        "Delay before the selection overlay appears — time to open menus or prepare the screen.":
            "Độ trễ trước khi lớp chọn vùng hiện ra — thời gian để mở menu hoặc dàn cảnh.",
        "Action performed immediately after capture: open the editor, save to a file, or copy to the clipboard.":
            "Thao tác ngay sau khi chụp: mở trình chỉnh sửa, lưu thành tệp, hoặc sao chép vào bảng nhớ tạm.",
        "Space around the screenshot inside a background frame. Applies only when a background is selected.":
            "Khoảng trống quanh ảnh chụp trong khung nền. Chỉ áp dụng khi đã chọn nền.",
        "Corner rounding when a background frame is applied (Square = none). Applies only when a background is selected.":
            "Độ bo góc khi dùng khung nền (Vuông = không bo). Chỉ áp dụng khi đã chọn nền.",
        "Background frame preselected when the editor opens; adjustable per capture.":
            "Nền được chọn sẵn khi mở trình chỉnh sửa; có thể đổi cho từng ảnh.",
        "60 fps captures motion more smoothly at roughly twice the file size.":
            "60 fps ghi chuyển động mượt hơn, dung lượng tệp khoảng gấp đôi.",
        "Countdown shown over the selected region before recording starts.":
            "Đếm ngược trên vùng đã chọn trước khi bắt đầu ghi.",
        "Drag to select a region, or press Space to capture a window or screen.":
            "Kéo chọn vùng, hoặc bấm Space để chụp cửa sổ / màn hình.",
        "Drag to select a region, or press Space to record a window or screen.":
            "Kéo chọn vùng, hoặc bấm Space để quay cửa sổ / màn hình.",
        "Captures the screen under the pointer immediately, with no overlay or delay — useful for transient menus and tooltips.":
            "Chụp ngay màn hình dưới con trỏ — không lớp chọn, không trễ — hữu ích với menu và tooltip dễ biến mất.",
        "Force-quits m_capture and any duplicate instances — use if the menu bar icon is stuck or duplicated.":
            "Buộc thoát m_capture và các bản trùng lặp — dùng khi biểu tượng thanh menu bị kẹt hoặc nhân đôi.",

        // ── Settings enum labels ─────────────────────────────────────────
        "None": "Không",
        // ── Color / background names ─────────────────────────────────────
        "Red": "Đỏ",
        "Orange": "Cam",
        "Yellow": "Vàng",
        "Green": "Xanh lá",
        "Blue": "Xanh dương",
        "Purple": "Tím",
        "Pink": "Hồng",
        "White": "Trắng",
        "Black": "Đen",
        "Light": "Sáng",
        "Dark": "Tối",
        "Lavender": "Oải hương",
        "Sunset": "Hoàng hôn",
        "Ocean": "Đại dương",
        "Forest": "Rừng xanh",
        "Candy": "Kẹo ngọt",
        "Midnight": "Nửa đêm",
        "Custom": "Tùy chọn",
        "Open editor": "Mở trình chỉnh sửa",
        "Save to file": "Lưu thành tệp",
        "Copy to clipboard": "Sao chép vào bảng nhớ tạm",
        "Record": "Quay",
        "Force Quit": "Buộc thoát",
        "Small": "Nhỏ",
        "Medium": "Vừa",
        "Large": "Lớn",
        "Square": "Vuông",
        "High (8 Mbps)": "Cao (8 Mbps)",
        "Medium (4 Mbps)": "Vừa (4 Mbps)",
        "Low (2 Mbps)": "Thấp (2 Mbps)",
        "System Audio": "Âm thanh hệ thống",
        "Microphone": "Micrô",
        "System + Mic": "Hệ thống + Micrô",

        // ── Editor cluster captions ──────────────────────────────────────
        "Markup": "Đánh dấu",
        "Shape": "Hình",
        "Style": "Kiểu",
        "Action": "Thao tác",

        // ── Editor tooltips ──────────────────────────────────────────────
        "Overlay image — paste (⌘V), drop a file, or click to choose":
            "Chèn hình — dán (⌘V), thả tệp vào, hoặc bấm để chọn",
        "Counter — place numbered badges (click again to change format)  (C)":
            "Bộ đếm — đặt nhãn đánh số (bấm lần nữa để đổi định dạng)  (C)",
        "Emoji — stamp an emoji (click to choose)": "Emoji — đóng dấu emoji (bấm để chọn)",
        "Pencil — freehand draw  (P)": "Bút chì — vẽ tự do  (P)",
        "Highlighter — translucent highlight  (H)": "Bút dạ quang — tô sáng trong suốt  (H)",
        "Eraser — click a mark to remove it  (E)": "Tẩy — bấm vào nét vẽ để xoá  (E)",
        "Text — click and type a label  (T)": "Văn bản — bấm và gõ nhãn  (T)",
        "Blur — obscure sensitive content  (B)":
            "Làm mờ — che nội dung nhạy cảm  (B)",
        "Spotlight — dim everything around an area  (S)":
            "Spotlight — làm tối mọi thứ quanh một vùng  (S)",
        "Zoom — magnify a region into a callout  (Z)": "Phóng to — phóng đại một vùng thành chú thích  (Z)",
        "Ruler — drag to measure  (hold ⇧ to snap horizontal/vertical)":
            "Thước — kéo để đo  (giữ ⇧ để khoá ngang/dọc)",
        "Copy text / QR (OCR) — drag over text or a QR code  (⌘T)":
            "Sao chép văn bản / QR (OCR) — kéo qua văn bản hoặc mã QR  (⌘T)",
        "Arrow — point to an area  (A)": "Mũi tên — chỉ vào một vùng  (A)",
        "Line — straight line  (L)": "Đường thẳng  (L)",
        "Rectangle — box outline  (R)": "Chữ nhật — khung viền  (R)",
        "Ellipse — oval outline  (O)": "Elip — viền bầu dục  (O)",
        "Rounded rectangle — rounded box  (U)": "Chữ nhật bo góc  (U)",
        "Triangle — triangle outline  (G)": "Tam giác  (G)",
        "Diamond — diamond outline  (D)": "Hình thoi  (D)",
        "Star — 5-point star outline  (Y)": "Ngôi sao 5 cánh  (Y)",
        "Checkmark — check mark  (K)": "Dấu tích  (K)",
        "Pentagon — 5-sided outline  (5)": "Ngũ giác  (5)",
        "Hexagon — 6-sided outline  (6)": "Lục giác  (6)",
        "Octagon — 8-sided outline  (8)": "Bát giác  (8)",
        "Eyedropper — pick a color from the image  (I)": "Ống hút màu — lấy màu từ ảnh  (I)",
        "%@ color": "Màu %@",
        "Custom color — pick any hue": "Màu tuỳ chọn — chọn tông bất kỳ",
        "Stroke width: %@ — click to cycle": "Độ dày nét: %@ — bấm để đổi",
        "Move — drag an object to reposition, drag its corner to resize, ⌫ to delete  (V)":
            "Di chuyển — kéo để dời, kéo góc để đổi cỡ, ⌫ để xoá  (V)",
        "Crop — drag a region, then ↵ or ✓": "Cắt — kéo chọn vùng, rồi ↵ hoặc ✓",
        "Rotate right 90°": "Xoay phải 90°",
        "Flip horizontal": "Lật ngang",
        "Undo  (⌘Z)": "Hoàn tác  (⌘Z)",
        "Redo  (⇧⌘Z)": "Làm lại  (⇧⌘Z)",
        "Pin to screen — keep on top  (⌘P)": "Ghim lên màn hình — luôn nổi trên cùng  (⌘P)",
        "Before/After GIF — animate overlays on/off": "GIF trước/sau — bật/tắt lớp chú thích",
        "Copy & close  (⌘C)": "Sao chép & đóng  (⌘C)",
        "Save & close  (⌘S)": "Lưu & đóng  (⌘S)",
        "Save As… — choose location  (⇧⌘S)": "Lưu thành… — chọn vị trí  (⇧⌘S)",
        "Cancel  (Esc)": "Huỷ  (Esc)",
        "Custom color": "Màu tuỳ chọn",
    ]
}
