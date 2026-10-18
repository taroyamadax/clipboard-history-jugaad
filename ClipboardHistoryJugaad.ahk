#Requires AutoHotkey v2.0
#Warn All, Off
; Ignore: if an instance is already running, the newly launched one silently
; exits. This prevents the "Could not close the previous instance / Keep
; waiting?" dialog that #SingleInstance Force can raise when the old instance
; is slow to close. Only one tray-resident instance ever stays alive.
#SingleInstance Ignore
; ============================================================================
;  Clipboard History Jugaad (self-made clone) - Classic Windows UI
;  AutoHotkey v2.0
;
;  Classic look:
;    - Standard title-bar window, native light theme, resizable & movable
;    - Toolbar : All / Text / Folder / File filter buttons + search box
;    - ListView with columns: Type | Length | Content | Time
;    - Status bar : Stats | Save Size ... <N> items ... Clear History
;
;  Hotkey   : Ctrl+Shift+H  (HHKB: no Win key) - configurable in CFG below
;  In list  :
;     type in search  -> filter
;     Enter / dbl-clk  -> paste selected item
;     Ctrl+C           -> copy selected item to clipboard
;     Ctrl+O           -> open selected folder / file / URL
;     Ctrl+P           -> pin / unpin selected item
;     Del              -> delete selected item
;     Esc              -> close window
;
;  History persisted to history.json next to this script.
; ============================================================================

; ---------------------------------------------------------------------------
;  Config
; ---------------------------------------------------------------------------
global CFG := {
    hotkey:      "^+h",            ; Ctrl+Shift+H opens the window
    maxItems:    200,              ; max stored items
    maxPreview:  200,              ; chars shown in the Content column
    winW:        720,              ; default window width
    winH:        420,              ; default window height
    minW:        420,              ; min width
    minH:        240,              ; min height
    rememberPos: true,             ; restore last window position too (not just size)
    pinnedFirst: true,             ; show pinned items at the top (toggle via Type header)
    expireHours: 24,               ; non-pinned items older than this are auto-deleted
    purgeOnStartup: true,          ; purge expired items at startup (and hourly thereafter)
    saveFile:    A_ScriptDir "\history.json",
    winStateFile: A_ScriptDir "\window.json"
}

; ---------------------------------------------------------------------------
;  State
; ---------------------------------------------------------------------------
global History   := []            ; [{text, time, pinned}]
global g_IgnoreClip := false      ; self-fire guard: skip OnClipboardChange while WE write the clipboard
global Filtered  := []            ; indices into History shown now
global ActiveTab := "All"         ; All | Text | Folder | File
global MainGui, SearchEdit, ItemLV, StatusText
global BtnAll, BtnText, BtnFolder, BtnFile, BtnStats, BtnSettings, BtnClear

; ---------------------------------------------------------------------------
;  Startup
; ---------------------------------------------------------------------------
LoadHistory()
PurgeExpired()                    ; drop non-pinned items older than CFG.expireHours
BuildGui()
OnClipboardChange(ClipChanged, 1)
Hotkey CFG.hotkey, (*) => ShowWindow()
SetTimer(PurgeExpired, 3600000)   ; re-purge hourly (positive interval = repeating)
TraySetIcon("shell32.dll", 135)
BuildTrayMenu()
return

; ---------------------------------------------------------------------------
;  Tray menu (classic, explicit Open / Exit)
; ---------------------------------------------------------------------------
BuildTrayMenu() {
    global CFG
    ; Build once at startup. Delete() with no arg removes ALL items (incl.
    ; the standard Open/Help/Window Spy/Reload/Edit/Suspend/Pause/Exit set).
    RebuildTrayMenu()
    ; Also rebuild on every right-click, so the menu can never regress to the
    ; AHK default set regardless of timing/order of icon creation.
    A_TrayMenu.ClickCount := 1                       ; single-click selects Default (Open)
    OnMessage(0x404, TrayIconMsg)                    ; WM_TRAYICON: catch tray clicks
    A_IconTip := "Clipboard History Jugaad"
}

; Rebuilds the tray menu from scratch: Open / --- / Exit only.
RebuildTrayMenu() {
    global CFG
    tray := A_TrayMenu
    tray.Delete()                                   ; remove every item (standard + custom)
    openLabel := "Open`t" HotkeyToText(CFG.hotkey)
    tray.Add(openLabel, (*) => ShowWindow())
    tray.Default := openLabel                       ; must match the item name exactly
    tray.Add()                                      ; separator
    tray.Add("Run at startup", (*) => ToggleStartup())
    if (IsStartupEnabled())                         ; reflect current state as a check mark
        tray.Check("Run at startup")
    else
        tray.Uncheck("Run at startup")
    tray.Add()                                      ; separator
    tray.Add("Exit", (*) => ExitApp())
}

; ---------------------------------------------------------------------------
;  Startup (run-at-login) toggle via a .lnk in the user's Startup folder.
;  Uses the Startup folder (not the registry) so it needs no admin rights
;  and is trivially reversible by deleting the shortcut.
; ---------------------------------------------------------------------------

; Full path to our shortcut in the current user's Startup folder.
StartupLnkPath() {
    return A_Startup "\ClipboardHistoryJugaad.lnk"
}

; True if the startup shortcut currently exists.
IsStartupEnabled() {
    return FileExist(StartupLnkPath()) != ""
}

; Create or remove the startup shortcut (toggle).
ToggleStartup() {
    lnk := StartupLnkPath()
    if (IsStartupEnabled()) {
        try FileDelete(lnk)
        TrayTip("Clipboard History Jugaad", "Removed from startup.", 1)
    } else {
        try {
            ; AHK v2's own exe (A_AhkPath) launches this script at login.
            ; Args: Target, LinkFile, WorkingDir, Args, Description
            FileCreateShortcut(
                A_AhkPath,                           ; target  : AutoHotkey64.exe
                lnk,                                 ; .lnk path
                A_ScriptDir,                         ; working dir
                '"' A_ScriptFullPath '"',            ; args    : the script, quoted
                "Clipboard History Jugaad",            ; description
            )
            TrayTip("Clipboard History Jugaad", "Added to startup.", 1)
        } catch as e {
            TrayTip("Clipboard History Jugaad", "Startup change failed: " e.Message, 3)
        }
    }
    SetTimer(() => TrayTip(), -2500)                 ; auto-clear the balloon
}

; WM_TRAYICON handler: on right mouse button up (0x205), rebuild then let AHK show it.
TrayIconMsg(wParam, lParam, msg, hwnd) {
    if (lParam = 0x205)                             ; WM_RBUTTONUP over the tray icon
        RebuildTrayMenu()
    ; return "" so AHK proceeds with its normal tray handling (shows the menu)
}

; Make a hotkey string like "^+h" human-readable, e.g. "Ctrl+Shift+H".
HotkeyToText(hk) {
    out := ""
    while (hk != "") {
        c := SubStr(hk, 1, 1)
        if (c = "^")
            out .= "Ctrl+", hk := SubStr(hk, 2)
        else if (c = "+")
            out .= "Shift+", hk := SubStr(hk, 2)
        else if (c = "!")
            out .= "Alt+", hk := SubStr(hk, 2)
        else if (c = "#")
            out .= "Win+", hk := SubStr(hk, 2)
        else {
            out .= StrUpper(hk)
            break
        }
    }
    return out
}

; ===========================================================================
;  Clipboard watching
; ===========================================================================
ClipChanged(dataType) {
    global g_IgnoreClip
    if (g_IgnoreClip)              ; our own paste/copy -> ignore, prevents self-fire loop
        return
    if (dataType != 1)             ; 1 = text
        return
    text := A_Clipboard
    if (text = "" || StrLen(Trim(text)) = 0)
        return
    AddItem(text)
}

AddItem(text) {
    global History, CFG
    for i, it in History {
        if (it.text = text) {       ; de-dup -> move to top
            it.time := A_NowUTC
            History.RemoveAt(i)
            History.InsertAt(1, it)
            SaveHistory()
            RefreshIfVisible()
            return
        }
    }
    History.InsertAt(1, { text: text, time: A_NowUTC, pinned: false })
    while (History.Length > CFG.maxItems) {
        removed := false
        loop History.Length {
            idx := History.Length - A_Index + 1
            if (!History[idx].pinned) {
                History.RemoveAt(idx)
                removed := true
                break
            }
        }
        if (!removed)
            break
    }
    SaveHistory()
    RefreshIfVisible()
}

RefreshIfVisible() {
    global MainGui
    try {
        if (WinExist("ahk_id " MainGui.Hwnd) && DllCall("IsWindowVisible", "ptr", MainGui.Hwnd))
            RefreshList()
    }
}

; Delete non-pinned items older than CFG.expireHours. Runs once at startup
; and then hourly via SetTimer, so a long-lived tray instance keeps itself
; tidy even when the PC is never restarted. Pinned items are never touched;
; items with no/blank timestamp are kept (can't judge their age).
PurgeExpired() {
    global History, CFG
    if (!CFG.purgeOnStartup)
        return
    changed := false
    ; Walk back-to-front so RemoveAt() doesn't shift indices we still visit
    ; (same approach as the maxItems eviction in AddItem).
    i := History.Length
    while (i >= 1) {
        it := History[i]
        if (!it.pinned && it.time != "") {
            ageSec := DateDiff(A_NowUTC, it.time, "Seconds")
            if (ageSec >= CFG.expireHours * 3600) {
                History.RemoveAt(i)
                changed := true
            }
        }
        i--
    }
    if (changed) {
        SaveHistory()
        RefreshIfVisible()        ; keep an open window in sync (closed = no-op)
    }
}

; ===========================================================================
;  GUI  (classic native Windows look)
; ===========================================================================
BuildGui() {
    global MainGui, SearchEdit, ItemLV, StatusText, CFG
    global BtnAll, BtnText, BtnFolder, BtnFile, BtnStats, BtnSettings, BtnClear

    ; Standard resizable window with title bar (classic look).
    MainGui := Gui("+Resize", "Clipboard History Jugaad")
    MainGui.SetFont("s9", "Segoe UI")

    ; --- Toolbar: filter buttons (left) ---
    BtnAll    := MainGui.Add("Button", "x8 y8 w50 h26", "All")
    BtnText   := MainGui.Add("Button", "x+4 yp w50 h26", "Text")
    BtnFolder := MainGui.Add("Button", "x+4 yp w60 h26", "Folder")
    BtnFile   := MainGui.Add("Button", "x+4 yp w50 h26", "File")
    BtnAll.OnEvent("Click",    (*) => SetTab("All"))
    BtnText.OnEvent("Click",   (*) => SetTab("Text"))
    BtnFolder.OnEvent("Click", (*) => SetTab("Folder"))
    BtnFile.OnEvent("Click",   (*) => SetTab("File"))

    ; --- Search box (right of toolbar) ---
    SearchEdit := MainGui.Add("Edit", "x+8 yp w300 h26 +0x200", "")
    SearchEdit.OnEvent("Change", (*) => RefreshList())
    ; cue banner (placeholder text) via EM_SETCUEBANNER
    DllCall("SendMessage", "ptr", SearchEdit.Hwnd, "uint", 0x1501, "ptr", 1
        , "wstr", "Search clipboard history...")

    ; --- Main ListView (classic columns) ---
    ItemLV := MainGui.Add("ListView"
        , "x8 y40 w" (CFG.winW - 16) " h" (CFG.winH - 80) " Grid +Report"
        , ["Type", "Length", "Content", "Time"])
    ItemLV.OnEvent("DoubleClick", (*) => PasteSelected())
    ItemLV.OnEvent("ContextMenu", ShowItemMenu)
    ItemLV.OnEvent("ColClick", LVHeaderClick)
    ItemLV.ModifyCol(1, 70)       ; Type
    ItemLV.ModifyCol(2, 70)       ; Length (character count)
    ItemLV.ModifyCol(3, 420)      ; Content
    ItemLV.ModifyCol(4, 70)       ; Time

    ; --- Status bar (bottom) ---
    BtnStats    := MainGui.Add("Button", "x8 y" (CFG.winH - 34) " w60 h24", "Stats")
    BtnSettings := MainGui.Add("Button", "x+4 yp w80 h24", "Save Size")
    StatusText  := MainGui.Add("Text", "x+10 yp+4 w200 h18 Center", "0 items")
    BtnClear    := MainGui.Add("Button", "x" (CFG.winW - 108) " y" (CFG.winH - 34) " w100 h24", "Clear History")
    BtnStats.OnEvent("Click",    (*) => ShowStats())
    BtnSettings.OnEvent("Click", (*) => SaveCurrentSize())
    BtnClear.OnEvent("Click",    (*) => ClearHistory())

    MainGui.OnEvent("Escape", (*) => HideWindow())
    MainGui.OnEvent("Close",  (*) => HideWindow())
    MainGui.OnEvent("Size",   GuiResized)

    SetActiveButton()
}

; Save window position, then hide (called on Esc / close box).
HideWindow() {
    global MainGui
    SaveWindowState()
    MainGui.Hide()
}

; Persist current window position to winStateFile (size is NOT saved to avoid
; the growing-window bug caused by DPI/rounding issues on repeated open/close).
SaveWindowState() {
    global MainGui, CFG
    try {
        if (!DllCall("IsWindowVisible", "ptr", MainGui.Hwnd))
            return
        MainGui.GetPos(&x, &y, &w, &h)
        ; Save position only; size uses saved value or CFG defaults
        ; Preserve existing saved size if any
        saved := LoadWindowStateRaw()
        sw := (saved && saved.w) ? saved.w : CFG.winW
        sh := (saved && saved.h) ? saved.h : CFG.winH
        json := '{"x":' x ',"y":' y ',"w":' sw ',"h":' sh '}'
        try FileDelete(CFG.winStateFile)
        FileAppend(json, CFG.winStateFile, "UTF-8")
    }
}

; Save current size explicitly (called by Save Size button).
SaveCurrentSize() {
    global MainGui, CFG
    try {
        MainGui.GetPos(&x, &y, &w, &h)
        if (w < CFG.minW || h < CFG.minH)
            return
        json := '{"x":' x ',"y":' y ',"w":' w ',"h":' h '}'
        try FileDelete(CFG.winStateFile)
        FileAppend(json, CFG.winStateFile, "UTF-8")
        ToolTip("Size saved: " w "x" h)
        SetTimer(() => ToolTip(), -1500)
    }
}

; Raw loader (returns object with whatever fields exist, or 0).
LoadWindowStateRaw() {
    global CFG
    if !FileExist(CFG.winStateFile)
        return 0
    try raw := FileRead(CFG.winStateFile, "UTF-8")
    catch
        return 0
    x := ReadNum(raw, "x"), y := ReadNum(raw, "y")
    w := ReadNum(raw, "w"), h := ReadNum(raw, "h")
    return { x: x, y: y, w: w, h: h }
}

; Load saved window position and size.
LoadWindowState() {
    global CFG
    saved := LoadWindowStateRaw()
    if (!saved)
        return 0
    w := (saved.w != "" && saved.w >= CFG.minW) ? saved.w : CFG.winW
    h := (saved.h != "" && saved.h >= CFG.minH) ? saved.h : CFG.winH
    if (saved.x = "" || saved.y = "")
        return 0
    return { x: saved.x, y: saved.y, w: w, h: h }
}

ReadNum(raw, key) {
    if !RegExMatch(raw, '"' key '"\s*:\s*(-?\d+)', &m)
        return ""
    return m[1] + 0
}

; Re-flow controls when the window is resized.
GuiResized(thisGui, minMax, w, h) {
    global SearchEdit, ItemLV, StatusText, BtnStats, BtnSettings, BtnClear
    if (minMax = -1)
        return
    ; search box stretches to the right edge of the toolbar
    SearchEdit.GetPos(&sx, &sy, &sw, &sh)
    SearchEdit.Move(, , w - sx - 8)
    ; list fills the middle
    ItemLV.Move(8, 40, w - 16, h - 80)
    ; content column takes the remaining width (Content is now the 4th column)
    FitContentCol(w)
    ; bottom bar follows the bottom edge
    by := h - 34
    BtnStats.Move(8, by)
    BtnSettings.Move(74, by)
    StatusText.Move(150, by + 4, w - 150 - 116)
    BtnClear.Move(w - 108, by)
}

; Stretch the Content (4th) column to fill the remaining list width. Shared by
; GuiResized and RefreshList so the Content column spans to the right edge on
; startup and after every refresh — not only after a manual window resize.
; `w` is the client width; if omitted it's read from the current window.
FitContentCol(w := 0) {
    global ItemLV, MainGui
    if (!w) {
        MainGui.GetClientPos(, , &cw)
        w := cw
    }
    other := 70 + 70 + 70 + 20   ; Type + Length + Time + padding (scrollbar ~17px)
    cw := w - 16 - other
    if (cw < 120)
        cw := 120
    ItemLV.ModifyCol(3, cw)
}

; ===========================================================================
;  Tabs / filtering
; ===========================================================================
SetTab(tab) {
    global ActiveTab
    ActiveTab := tab
    SetActiveButton()
    RefreshList()
}

; Visually mark the active filter button (classic "pressed" look).
SetActiveButton() {
    global ActiveTab, BtnAll, BtnText, BtnFolder, BtnFile
    for name, btn in Map("All", BtnAll, "Text", BtnText, "Folder", BtnFolder, "File", BtnFile) {
        ; default button text; prefix active with a marker for a classic cue
        btn.Text := (name = ActiveTab) ? "[" name "]" : name
    }
}

; ===========================================================================
;  Show / render
; ===========================================================================
ShowWindow() {
    global MainGui, CFG, SearchEdit, ActiveTab
    ActiveTab := "All"
    SetActiveButton()
    SearchEdit.Value := ""
    RefreshList()

    saved := LoadWindowState()
    if (saved && CFG.rememberPos) {
        ; --- restore last size AND position, clamped to a visible monitor ---
        w := saved.w, h := saved.h
        px := saved.x, py := saved.y
        mon := MonitorFromPoint(px + w // 2, py + h // 2)
        MonitorGetWorkArea(mon, &waL, &waT, &waR, &waB)
        if (px + w > waR)
            px := waR - w
        if (py + h > waB)
            py := waB - h
        if (px < waL)
            px := waL
        if (py < waT)
            py := waT
    } else if (saved) {
        ; --- restore last size only, open at the mouse cursor ---
        w := saved.w, h := saved.h
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        px := mx, py := my
        mon := MonitorFromPoint(mx, my)
        MonitorGetWorkArea(mon, &waL, &waT, &waR, &waB)
        if (px + w > waR)
            px := waR - w
        if (py + h > waB)
            py := waB - h
        if (px < waL)
            px := waL
        if (py < waT)
            py := waT
    } else {
        ; --- first run: default size at the mouse cursor ---
        w := CFG.winW, h := CFG.winH
        CoordMode("Mouse", "Screen")
        MouseGetPos(&mx, &my)
        px := mx, py := my
        mon := MonitorFromPoint(mx, my)
        MonitorGetWorkArea(mon, &waL, &waT, &waR, &waB)
        if (px + w > waR)
            px := waR - w
        if (py + h > waB)
            py := waB - h
        if (px < waL)
            px := waL
        if (py < waT)
            py := waT
    }

    MainGui.Show(Format("x{1} y{2} w{3} h{4}", px, py, w, h))
    SearchEdit.Focus()
}

MonitorFromPoint(x, y) {
    loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        if (x >= l && x < r && y >= t && y < b)
            return A_Index
    }
    return MonitorGetPrimary()
}

RefreshList() {
    global History, Filtered, ItemLV, ActiveTab, SearchEdit, StatusText, CFG
    q := StrLower(Trim(SearchEdit.Value))
    matched := []
    for i, it in History {
        kind := ItemKind(it.text)
        if (ActiveTab = "Folder" && kind != "Folder")
            continue
        if (ActiveTab = "File" && kind != "File")
            continue
        if (ActiveTab = "Text" && (kind = "Folder" || kind = "File"))
            continue
        if (q != "" && !InStr(StrLower(it.text), q))
            continue
        matched.Push(i)
    }
    if (CFG.pinnedFirst) {
        pinned := [], others := []
        for idx in matched
            (History[idx].pinned ? pinned : others).Push(idx)
        matched := []
        for idx in pinned
            matched.Push(idx)
        for idx in others
            matched.Push(idx)
    }
    Filtered := matched
    ItemLV.Opt("-Redraw")
    ItemLV.Delete()
    pinnedCount := 0
    for idx in Filtered {
        it := History[idx]
        if (it.pinned)
            pinnedCount++
        kind := ItemKind(it.text)
        type := (it.pinned ? "* " : "") kind
        ItemLV.Add(, type, FormatSize(StrLen(it.text)), MakePreview(it.text), FormatWhen(it.time))
    }
    ItemLV.Opt("+Redraw")
    if (Filtered.Length > 0)
        ItemLV.Modify(1, "Select Focus")
    StatusText.Value := Filtered.Length " items (" pinnedCount " pinned)"
    FitContentCol()   ; keep Content spanning to the right edge (incl. first show)
}

; ===========================================================================
;  Persistence (minimal JSON writer/reader for our own flat format)
; ===========================================================================
SaveHistory() {
    global History, CFG
    parts := []
    for it in History {
        parts.Push(Format('{{"text":{1},"time":"{2}","pinned":{3}}}'
            , JsonStr(it.text), it.time, it.pinned ? "true" : "false"))
    }
    json := "[" JoinArr(parts, ",") "]"
    try FileDelete(CFG.saveFile)
    FileAppend(json, CFG.saveFile, "UTF-8")
}

LoadHistory() {
    global History, CFG
    History := []
    if !FileExist(CFG.saveFile)
        return
    try raw := FileRead(CFG.saveFile, "UTF-8")
    catch
        return
    ParseHistory(raw)
}

ParseHistory(raw) {
    global History
    pos := 1
    while (true) {
        ; find the next record start; stop when none remain
        start := InStr(raw, '{"text":"', , pos)
        if (!start)
            break
        ; --- read the (escaped) text value ---
        i := start + StrLen('{"text":"')
        text := ""
        done := false
        while (i <= StrLen(raw)) {
            c := SubStr(raw, i, 1)
            if (c = "\") {                         ; escape sequence
                nxt := SubStr(raw, i + 1, 1)
                text .= (nxt = "n") ? "`n"
                     : (nxt = "r") ? "`r"
                     : (nxt = "t") ? "`t"
                     : nxt                          ; \" -> "  and  \\ -> \
                i += 2
                continue
            }
            if (c = '"') {                          ; closing quote of text
                done := true
                i++
                break
            }
            text .= c
            i++
        }
        if (!done)                                  ; malformed tail -> stop safely
            break
        ; --- read "time":"...." ---
        time := ""
        tkey := InStr(raw, '"time":"', , i)
        if (tkey) {
            tstart := tkey + StrLen('"time":"')
            tend := InStr(raw, '"', , tstart)
            if (tend)
                time := SubStr(raw, tstart, tend - tstart)
        }
        ; --- read "pinned":true/false ---
        ; Read the value that immediately follows this record's "pinned":
        ; key. Anchoring on the literal true/false right after the colon
        ; avoids the old fixed-length (16-char) scan that could spill into
        ; the next record and misread the flag.
        pinned := false
        pkey := InStr(raw, '"pinned":', , i)
        if (pkey) {
            vstart := pkey + StrLen('"pinned":')
            pinned := (SubStr(raw, vstart, 4) = "true")
        }
        History.Push({ text: text, time: time, pinned: pinned })
        ; CRITICAL: always advance past this record so the loop terminates
        pos := i
    }
}

JsonStr(s) {
    s := StrReplace(s, "\", "\\")      ; backslash first
    s := StrReplace(s, '"', '\"')      ; then double-quote
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    return '"' s '"'
}

JoinArr(arr, sep) {
    out := ""
    for i, v in arr
        out .= (i = 1 ? "" : sep) v
    return out
}

; ===========================================================================
;  Persistence (minimal JSON writer/reader for our own flat format)
; ===========================================================================

; ===========================================================================
;  Item classification (text / folder / file / url) - derived, not stored
; ===========================================================================

; Return "Folder" | "File" | "URL" | "Text" for a stored text value.
; Classification is computed on the fly so history.json stays backward
; compatible (no new field is written).
ItemKind(text) {
    s := Trim(text)
    ; Explorer's "Copy as path" wraps the path in double quotes; strip a
    ; single matching pair so FileExist can resolve it.
    if (SubStr(s, 1, 1) = '"' && SubStr(s, -1) = '"')
        s := Trim(SubStr(s, 2, StrLen(s) - 2))
    if (s = "")
        return "Text"
    ; URL: http(s) / ftp / file scheme
    if (RegExMatch(s, "i)^(https?|ftp|file)://\S+$"))
        return "URL"
    ; single-line path only (reject multi-line blobs that merely contain a path)
    if (InStr(s, "`n") || InStr(s, "`r"))
        return "Text"
    ; local or UNC path that actually exists on disk
    if (RegExMatch(s, "^([A-Za-z]:\\|\\\\)")) {
        attr := FileExist(s)
        if (attr != "") {
            return InStr(attr, "D") ? "Folder" : "File"
        }
    }
    return "Text"
}

; True if the item can be opened (folder, file or url).
IsOpenable(text) {
    k := ItemKind(text)
    return (k = "Folder" || k = "File" || k = "URL")
}

; Open the item with the shell: folder in Explorer, file in its default app,
; url in the default browser.
OpenItem(text) {
    s := Trim(text)
    ; strip a matching pair of surrounding quotes ("Copy as path" format)
    if (SubStr(s, 1, 1) = '"' && SubStr(s, -1) = '"')
        s := Trim(SubStr(s, 2, StrLen(s) - 2))
    k := ItemKind(s)
    if (k = "Text") {
        ToolTip("Not a folder / file / URL")
        SetTimer(() => ToolTip(), -1000)
        return
    }
    try {
        if (k = "Folder")
            Run('explorer.exe "' s '"')          ; open the folder window
        else
            Run(s)                                ; file -> default app, url -> browser
    } catch as e {
        ToolTip("Open failed: " e.Message)
        SetTimer(() => ToolTip(), -1500)
    }
}

; ===========================================================================
;  Row rendering helpers
; ===========================================================================

; One-line preview: strip CR/LF/TAB, collapse spaces, cap to CFG.maxPreview.
; For Folder/File/URL, show emoji + short name instead of full path.
MakePreview(text) {
    global CFG
    kind := ItemKind(text)
    
    ; --- Folder: 📁 + folder name only ---
    if (kind = "Folder") {
        s := Trim(text)
        if (SubStr(s, 1, 1) = '"' && SubStr(s, -1) = '"')
            s := Trim(SubStr(s, 2, StrLen(s) - 2))
        ; strip trailing backslash, then extract last segment
        s := RTrim(s, "\")
        pos := InStr(s, "\",, -1)   ; last backslash
        name := pos ? SubStr(s, pos + 1) : s
        return "📁 " name
    }
    
    ; --- File: emoji by extension + filename only ---
    if (kind = "File") {
        s := Trim(text)
        if (SubStr(s, 1, 1) = '"' && SubStr(s, -1) = '"')
            s := Trim(SubStr(s, 2, StrLen(s) - 2))
        pos := InStr(s, "\",, -1)
        name := pos ? SubStr(s, pos + 1) : s
        emoji := FileEmoji(name)
        return emoji " " name
    }
    
    ; --- URL: 🔗 + domain/path (strip scheme) ---
    if (kind = "URL") {
        s := Trim(text)
        s := RegExReplace(s, "i)^https?://", "")
        s := RegExReplace(s, "i)^ftp://", "")
        s := RegExReplace(s, "i)^file://", "")
        if (StrLen(s) > CFG.maxPreview)
            s := SubStr(s, 1, CFG.maxPreview) "..."
        return "🔗 " s
    }
    
    ; --- Text: original behavior ---
    s := StrReplace(text, "`r`n", " ")
    s := StrReplace(s, "`r", " ")
    s := StrReplace(s, "`n", " ")
    s := StrReplace(s, "`t", " ")
    while InStr(s, "  ")
        s := StrReplace(s, "  ", " ")
    s := Trim(s)
    if (StrLen(s) > CFG.maxPreview)
        s := SubStr(s, 1, CFG.maxPreview) " ..."
    return s
}

; Return emoji for a filename based on extension.
FileEmoji(name) {
    ext := ""
    dotPos := InStr(name, ".",, -1)
    if (dotPos)
        ext := StrLower(SubStr(name, dotPos + 1))
    
    ; Excel
    if (ext = "xlsx" || ext = "xls" || ext = "xlsm" || ext = "xlsb" || ext = "csv")
        return "📊"
    ; Word
    if (ext = "docx" || ext = "doc" || ext = "docm")
        return "📝"
    ; PowerPoint
    if (ext = "pptx" || ext = "ppt" || ext = "pptm")
        return "📽️"
    ; PDF
    if (ext = "pdf")
        return "📕"
    ; Image
    if (ext = "png" || ext = "jpg" || ext = "jpeg" || ext = "gif" || ext = "bmp" || ext = "webp" || ext = "svg" || ext = "ico")
        return "🖼️"
    ; Video
    if (ext = "mp4" || ext = "avi" || ext = "mkv" || ext = "mov" || ext = "wmv" || ext = "webm")
        return "🎬"
    ; Audio
    if (ext = "mp3" || ext = "wav" || ext = "flac" || ext = "aac" || ext = "ogg" || ext = "m4a")
        return "🎵"
    ; Archive
    if (ext = "zip" || ext = "rar" || ext = "7z" || ext = "tar" || ext = "gz")
        return "📦"
    ; Code/Script
    if (ext = "js" || ext = "ts" || ext = "py" || ext = "java" || ext = "c" || ext = "cpp" || ext = "cs" || ext = "go" || ext = "rs" || ext = "rb" || ext = "php" || ext = "ahk")
        return "💻"
    ; Text/Config
    if (ext = "txt" || ext = "md" || ext = "json" || ext = "xml" || ext = "yaml" || ext = "yml" || ext = "ini" || ext = "log")
        return "📄"
    ; Executable
    if (ext = "exe" || ext = "msi" || ext = "bat" || ext = "cmd" || ext = "ps1" || ext = "sh")
        return "⚙️"
    ; Default
    return "📄"
}

; Human-readable size for a text item measured in characters.
FormatSize(chars) {
    if (chars < 1000)
        return chars " ch"
    return Round(chars / 1000, 1) " Kch"
}

; Relative time from a stored A_NowUTC timestamp (YYYYMMDDHHMISS).
FormatWhen(ts) {
    if (ts = "")
        return ""
    diff := DateDiff(A_NowUTC, ts, "Seconds")   ; seconds elapsed since ts
    if (diff < 0)
        diff := 0
    if (diff < 60)
        return "just now"
    if (diff < 3600)
        return (diff // 60) " min ago"
    if (diff < 86400)
        return (diff // 3600) " h ago"
    return (diff // 86400) " d ago"
}

; ===========================================================================
;  Selection helpers
; ===========================================================================

; Return the History index of the currently selected row, or 0 if none.
SelectedHistoryIndex() {
    global ItemLV, Filtered
    row := ItemLV.GetNext(0, "F")        ; first focused row
    if (!row)
        row := ItemLV.GetNext(0)         ; else first selected row
    if (!row || row > Filtered.Length)
        return 0
    return Filtered[row]
}

; ===========================================================================
;  Clipboard actions (guarded against self-fire)
; ===========================================================================

; Put text on the clipboard WITHOUT re-triggering our own watcher.
SetClipboardGuarded(text) {
    global g_IgnoreClip
    g_IgnoreClip := true
    A_Clipboard := text
    if !ClipWait(2)                      ; wait up to 2s for the clipboard to settle
        g_IgnoreClip := false            ; failed -> release guard anyway
    ; release the guard shortly after, so the (async) OnClipboardChange from
    ; our own write is swallowed, but future real changes are caught again.
    SetTimer(ReleaseClipGuard, -250)
}

ReleaseClipGuard() {
    global g_IgnoreClip
    g_IgnoreClip := false
}

; Copy selected item to clipboard only (no paste).
CopySelected() {
    idx := SelectedHistoryIndex()
    if (!idx)
        return
    global History
    SetClipboardGuarded(History[idx].text)
    ToolTip("Copied")
    SetTimer(() => ToolTip(), -800)
}

; Paste selected item into the previously focused window.
PasteSelected() {
    idx := SelectedHistoryIndex()
    if (!idx)
        return
    global History
    HideWindow()                         ; get our window out of the way first
    ; give focus a moment to return to the target app
    SetClipboardGuarded(History[idx].text)
    Sleep(80)
    Send("^v")
}

; Open the selected item (folder / file / url) via the shell.
OpenSelected() {
    idx := SelectedHistoryIndex()
    if (!idx)
        return
    global History
    OpenItem(History[idx].text)
}

; Pin / unpin the selected item.
TogglePinSelected() {
    idx := SelectedHistoryIndex()
    if (!idx)
        return
    global History
    History[idx].pinned := !History[idx].pinned
    SaveHistory()
    RefreshList()
}

; Delete the selected item.
DeleteSelected() {
    idx := SelectedHistoryIndex()
    if (!idx)
        return
    global History
    History.RemoveAt(idx)
    SaveHistory()
    RefreshList()
}

; ===========================================================================
;  Context menu + list hotkeys
; ===========================================================================

ShowItemMenu(lv, item, isRightClick, x, y) {
    if (!item)
        return
    idx := SelectedHistoryIndex()
    global History
    m := Menu()
    ; "Open" first, only when the item is a folder / file / URL
    if (idx && IsOpenable(History[idx].text)) {
        m.Add("Open", (*) => OpenItem(History[idx].text))
        m.Default := "Open"                     ; double/enter-friendly default
        m.Add()
    }
    m.Add("Paste`tEnter",      (*) => PasteSelected())
    m.Add("Copy`tCtrl+C",      (*) => CopySelected())
    m.Add()
    pinLabel := (idx && History[idx].pinned) ? "Unpin`tCtrl+P" : "Pin`tCtrl+P"
    m.Add(pinLabel,            (*) => TogglePinSelected())
    m.Add("Delete`tDel",       (*) => DeleteSelected())
    m.Show()
}

; Click the "Type" column header to toggle pinned-first ordering.
LVHeaderClick(lv, col) {
    global CFG
    if (col = 1) {
        CFG.pinnedFirst := !CFG.pinnedFirst
        RefreshList()
    }
}

; List-scoped hotkeys, active only while the main window is the active window
; AND the search box does NOT have focus. Excluding the search box lets IME
; composition (and its confirming Enter) pass through untouched, so finishing
; a kanji conversion with Enter no longer triggers a paste.
#HotIf WinActive("Clipboard History Jugaad ahk_class AutoHotkeyGUI") && !SearchHasFocus()
Enter::PasteSelected()
^c::CopySelected()
^o::OpenSelected()
^p::TogglePinSelected()
Del::DeleteSelected()
#HotIf

; When the search box has focus, Enter just moves focus to the list (so the
; user can then press Enter again to paste). It never pastes directly, which
; avoids clashing with the IME's conversion-confirm Enter.
#HotIf WinActive("Clipboard History Jugaad ahk_class AutoHotkeyGUI") && SearchHasFocus()
Enter::FocusListFromSearch()
#HotIf

; True when the search Edit control currently has keyboard focus.
SearchHasFocus() {
    global SearchEdit
    try return (ControlGetFocus("A") = SearchEdit.Hwnd)
    catch
        return false
}

; Move focus from the search box into the list, selecting the first row.
FocusListFromSearch() {
    global ItemLV, Filtered
    if (Filtered.Length < 1)
        return
    ItemLV.Focus()
    ItemLV.Modify(1, "Select Focus")
}

; ===========================================================================
;  Stats / Settings / Clear
; ===========================================================================

ShowStats() {
    global History
    total := History.Length
    pinned := 0, chars := 0
    for it in History {
        chars += StrLen(it.text)
        if (it.pinned)
            pinned++
    }
    MsgBox(Format("Items : {1}`nPinned: {2}`nChars : {3}", total, pinned, chars)
        , "Clipboard History - Stats", 0x40)
}

ClearHistory() {
    global History
    ; keep pinned items; drop the rest
    kept := []
    for it in History {
        if (it.pinned)
            kept.Push(it)
    }
    if (History.Length = kept.Length) {
        if (MsgBox("Clear all history?", "Confirm", 0x4) = "No")
            return
        kept := []
    }
    History := kept
    SaveHistory()
    RefreshList()
}
