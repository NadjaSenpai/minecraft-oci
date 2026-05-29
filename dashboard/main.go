// Command minecraft-dashboard is a thin web layer over the existing
// systemd + tmux + mc-* control plane. It runs as the `minecraft` user and is
// meant to sit behind Cloudflare Tunnel + Access (bind 127.0.0.1 only).
//
// It shells out to: tmux (console, owned by the minecraft user — no sudo),
// `sudo systemctl {start,stop,restart} minecraft` (the only privileged action),
// and /usr/local/bin/mc-backup. It edits server.properties / whitelist.json
// directly (the minecraft user owns them). Logic for config/whitelist is
// intentionally inlined here (repo policy = self-contained; the CLI mc-* stay
// root-only for terminal use).
package main

import (
	"bytes"
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

//go:embed web
var webFS embed.FS

type Config struct {
	Listen      string
	MCDir       string
	MCUser      string
	MCVersion   string
	Service     string
	TmuxSocket  string
	TmuxSession string
}

var cfg Config

var httpClient = &http.Client{Timeout: 10 * time.Second}

var gameplayKeys = []string{
	"motd", "difficulty", "gamemode", "max-players",
	"pvp", "view-distance", "simulation-distance", "hardcore",
}

var backupRe = regexp.MustCompile(`^world-[0-9]{8}-[0-9]{6}\.tar\.gz$`)

func main() {
	env := loadEnvFile("/etc/default/minecraft")
	cfg = Config{
		Listen:      getenv("DASHBOARD_LISTEN", "127.0.0.1:8765"),
		MCDir:       firstNonEmpty(os.Getenv("MC_DIR"), env["MC_DIR"], "/opt/minecraft"),
		MCUser:      firstNonEmpty(os.Getenv("MC_USER"), env["MC_USER"], "minecraft"),
		MCVersion:   firstNonEmpty(os.Getenv("MC_VERSION"), env["MC_VERSION"], ""),
		Service:     "minecraft",
		TmuxSocket:  "minecraft",
		TmuxSession: "minecraft",
	}

	sub, err := fs.Sub(webFS, "web")
	if err != nil {
		fatal(err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/status", handleStatus)
	mux.HandleFunc("GET /api/players", handlePlayers)
	mux.HandleFunc("POST /api/power/{action}", handlePower)
	mux.HandleFunc("GET /api/console/stream", handleConsoleStream)
	mux.HandleFunc("POST /api/console", handleConsoleSend)
	mux.HandleFunc("GET /api/config", handleConfigGet)
	mux.HandleFunc("POST /api/config", handleConfigSet)
	mux.HandleFunc("GET /api/whitelist", handleWhitelistGet)
	mux.HandleFunc("POST /api/whitelist", handleWhitelistAdd)
	mux.HandleFunc("POST /api/backup", handleBackupRun)
	mux.HandleFunc("GET /api/backups", handleBackupList)
	mux.HandleFunc("GET /api/backups/{file}", handleBackupDownload)
	mux.Handle("GET /", http.FileServer(http.FS(sub)))

	fmt.Printf("minecraft-dashboard listening on %s (MC_DIR=%s user=%s version=%s)\n",
		cfg.Listen, cfg.MCDir, cfg.MCUser, cfg.MCVersion)
	if err := (&http.Server{Addr: cfg.Listen, Handler: mux}).ListenAndServe(); err != nil {
		fatal(err)
	}
}

// --- server control ----------------------------------------------------------

func tmuxSend(command string) error {
	// daemon runs as MCUser which owns the tmux session — no sudo needed.
	return exec.Command("tmux", "-L", cfg.TmuxSocket, "send-keys", "-t", cfg.TmuxSession, command, "Enter").Run()
}

func serverRunning() bool {
	return exec.Command("tmux", "-L", cfg.TmuxSocket, "has-session", "-t", cfg.TmuxSession).Run() == nil
}

func handleStatus(w http.ResponseWriter, r *http.Request) {
	out, _ := exec.Command("systemctl", "is-active", cfg.Service).Output()
	state := strings.TrimSpace(string(out))
	writeJSON(w, 200, map[string]any{"running": state == "active", "state": state})
}

func handlePlayers(w http.ResponseWriter, r *http.Request) {
	port := 25565
	if p, err := strconv.Atoi(readProps()["server-port"]); err == nil && p > 0 {
		port = p
	}
	online, max, names, err := slpPlayers("127.0.0.1", port)
	if err != nil {
		// サーバー停止中など。UI 側で「—」表示にできるよう available:false で返す。
		writeJSON(w, 200, map[string]any{"available": false, "online": 0, "max": 0, "players": []string{}})
		return
	}
	if names == nil {
		names = []string{}
	}
	writeJSON(w, 200, map[string]any{"available": true, "online": online, "max": max, "players": names})
}

func handlePower(w http.ResponseWriter, r *http.Request) {
	action := r.PathValue("action")
	if !inSet(action, "start", "stop", "restart") {
		httpErr(w, 400, "invalid action")
		return
	}
	out, err := exec.Command("sudo", "/usr/bin/systemctl", action, cfg.Service).CombinedOutput()
	if err != nil {
		httpErr(w, 500, fmt.Sprintf("%v: %s", err, strings.TrimSpace(string(out))))
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "action": action})
}

// --- console: SSE tail of latest.log + send via tmux --------------------------

func handleConsoleSend(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Command string `json:"command"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || strings.TrimSpace(body.Command) == "" {
		httpErr(w, 400, "command required")
		return
	}
	if err := tmuxSend(body.Command); err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true})
}

func handleConsoleStream(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		httpErr(w, 500, "streaming unsupported")
		return
	}
	h := w.Header()
	h.Set("Content-Type", "text/event-stream")
	h.Set("Cache-Control", "no-cache")
	h.Set("X-Accel-Buffering", "no")

	ctx := r.Context()
	logPath := filepath.Join(cfg.MCDir, "logs", "latest.log")

	send := func(line string) bool {
		if _, err := fmt.Fprintf(w, "data: %s\n\n", line); err != nil {
			return false
		}
		flusher.Flush()
		return true
	}

	// Backlog: last 200 lines.
	var offset int64
	if data, err := os.ReadFile(logPath); err == nil {
		offset = int64(len(data))
		lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
		from := 0
		if len(lines) > 200 {
			from = len(lines) - 200
		}
		for _, l := range lines[from:] {
			if l == "" {
				continue
			}
			if !send(l) {
				return
			}
		}
	}

	ticker := time.NewTicker(700 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			fi, err := os.Stat(logPath)
			if err != nil {
				continue
			}
			if fi.Size() < offset {
				offset = 0 // rotated / truncated → restart from the top
			}
			if fi.Size() == offset {
				if _, err := fmt.Fprint(w, ": ping\n\n"); err != nil {
					return
				}
				flusher.Flush()
				continue
			}
			f, err := os.Open(logPath)
			if err != nil {
				continue
			}
			if _, err := f.Seek(offset, io.SeekStart); err != nil {
				f.Close()
				continue
			}
			data, _ := io.ReadAll(f)
			f.Close()
			idx := bytes.LastIndexByte(data, '\n')
			if idx < 0 {
				continue // wait for a complete line
			}
			chunk := data[:idx+1]
			offset += int64(len(chunk))
			for _, l := range strings.Split(strings.TrimRight(string(chunk), "\n"), "\n") {
				if !send(l) {
					return
				}
			}
		}
	}
}

// --- config (server.properties, 8 gameplay keys) ------------------------------

func handleConfigGet(w http.ResponseWriter, r *http.Request) {
	props := readProps()
	out := map[string]string{}
	for _, k := range gameplayKeys {
		out[k] = props[k]
	}
	writeJSON(w, 200, map[string]any{
		"version": cfg.MCVersion,
		"modern":  modernMC(cfg.MCVersion),
		"config":  out,
	})
}

func handleConfigSet(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Key   string `json:"key"`
		Value string `json:"value"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil {
		httpErr(w, 400, "bad request")
		return
	}
	if !contains(gameplayKeys, b.Key) {
		httpErr(w, 400, "unknown or protected key")
		return
	}
	if err := validateValue(b.Key, b.Value); err != nil {
		httpErr(w, 400, err.Error())
		return
	}

	note := "restart required"
	switch b.Key {
	case "difficulty":
		if err := setProp(b.Key, b.Value); err != nil {
			httpErr(w, 500, err.Error())
			return
		}
		if serverRunning() {
			tmuxSend("difficulty " + b.Value)
			note = "applied live"
		}
	case "gamemode":
		if err := setProp(b.Key, b.Value); err != nil {
			httpErr(w, 500, err.Error())
			return
		}
		if serverRunning() {
			tmuxSend("defaultgamemode " + b.Value)
			note = "applied live (new joins)"
		}
	case "pvp":
		if modernMC(cfg.MCVersion) {
			if serverRunning() {
				tmuxSend("gamerule pvp " + b.Value)
				note = "gamerule (live, world-persisted; not written to properties)"
			} else {
				note = "pvp is a gamerule on this version; start the server then retry"
			}
		} else {
			if err := setProp(b.Key, b.Value); err != nil {
				httpErr(w, 500, err.Error())
				return
			}
		}
	case "motd":
		if err := setProp(b.Key, normalizeMotd(b.Value)); err != nil {
			httpErr(w, 500, err.Error())
			return
		}
	default: // max-players, view-distance, simulation-distance, hardcore
		if err := setProp(b.Key, b.Value); err != nil {
			httpErr(w, 500, err.Error())
			return
		}
	}
	writeJSON(w, 200, map[string]any{"ok": true, "key": b.Key, "note": note})
}

// --- whitelist ----------------------------------------------------------------

type wlEntry struct {
	UUID string `json:"uuid"`
	Name string `json:"name"`
}

func handleWhitelistGet(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, readWhitelist())
}

func handleWhitelistAdd(w http.ResponseWriter, r *http.Request) {
	var b struct {
		Name    string `json:"name"`
		Bedrock bool   `json:"bedrock"`
	}
	if err := json.NewDecoder(r.Body).Decode(&b); err != nil || strings.TrimSpace(b.Name) == "" {
		httpErr(w, 400, "name required")
		return
	}
	var uuid, entryName string
	var err error
	if b.Bedrock {
		uuid, err = bedrockUUID(b.Name)
		entryName = "." + b.Name
	} else {
		uuid, err = javaUUID(b.Name)
		entryName = b.Name
	}
	if err != nil {
		httpErr(w, 400, err.Error())
		return
	}
	out := []wlEntry{}
	for _, e := range readWhitelist() {
		if e.UUID != uuid {
			out = append(out, e)
		}
	}
	out = append(out, wlEntry{UUID: uuid, Name: entryName})
	if err := writeWhitelist(out); err != nil {
		httpErr(w, 500, err.Error())
		return
	}
	reloaded := false
	if serverRunning() {
		tmuxSend("whitelist reload")
		reloaded = true
	}
	writeJSON(w, 200, map[string]any{"ok": true, "uuid": uuid, "name": entryName, "reloaded": reloaded})
}

func javaUUID(name string) (string, error) {
	var resp struct {
		ID string `json:"id"`
	}
	if err := getJSON("https://api.mojang.com/users/profiles/minecraft/"+url.PathEscape(name), &resp); err != nil {
		return "", fmt.Errorf("could not resolve Java UUID for %q: %v", name, err)
	}
	if len(resp.ID) != 32 {
		return "", fmt.Errorf("could not resolve Java UUID for %q", name)
	}
	id := resp.ID
	return fmt.Sprintf("%s-%s-%s-%s-%s", id[0:8], id[8:12], id[12:16], id[16:20], id[20:32]), nil
}

func bedrockUUID(name string) (string, error) {
	var resp struct {
		XUID json.Number `json:"xuid"`
	}
	if err := getJSON("https://api.geysermc.org/v2/xbox/xuid/"+url.PathEscape(name), &resp); err != nil {
		return "", fmt.Errorf("could not resolve XUID for %q: %v", name, err)
	}
	xi, err := strconv.ParseInt(resp.XUID.String(), 10, 64)
	if err != nil {
		return "", fmt.Errorf("could not resolve XUID for %q", name)
	}
	hex := fmt.Sprintf("%016x", xi)
	return fmt.Sprintf("00000000-0000-0000-%s-%s", hex[0:4], hex[4:16]), nil
}

// --- backups ------------------------------------------------------------------

func handleBackupRun(w http.ResponseWriter, r *http.Request) {
	out, err := exec.Command("/usr/local/bin/mc-backup").CombinedOutput()
	if err != nil {
		httpErr(w, 500, fmt.Sprintf("%v: %s", err, strings.TrimSpace(string(out))))
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "output": string(out)})
}

func handleBackupList(w http.ResponseWriter, r *http.Request) {
	type item struct {
		Name     string `json:"name"`
		Size     int64  `json:"size"`
		Modified string `json:"modified"`
	}
	list := []item{}
	ents, _ := os.ReadDir(filepath.Join(cfg.MCDir, "backups"))
	for _, e := range ents {
		if e.IsDir() || !backupRe.MatchString(e.Name()) {
			continue
		}
		fi, err := e.Info()
		if err != nil {
			continue
		}
		list = append(list, item{e.Name(), fi.Size(), fi.ModTime().Format(time.RFC3339)})
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Name > list[j].Name })
	writeJSON(w, 200, list)
}

func handleBackupDownload(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("file")
	if !backupRe.MatchString(name) {
		httpErr(w, 400, "invalid backup name")
		return
	}
	http.ServeFile(w, r, filepath.Join(cfg.MCDir, "backups", name))
}

// --- file helpers (server.properties / whitelist.json) ------------------------

func readProps() map[string]string {
	m := map[string]string{}
	data, err := os.ReadFile(filepath.Join(cfg.MCDir, "server.properties"))
	if err != nil {
		return m
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if i := strings.IndexByte(line, '='); i >= 0 {
			m[line[:i]] = line[i+1:]
		}
	}
	return m
}

func setProp(key, value string) error {
	path := filepath.Join(cfg.MCDir, "server.properties")
	data, _ := os.ReadFile(path)
	lines := strings.Split(string(data), "\n")
	found := false
	for i, line := range lines {
		if strings.HasPrefix(line, key+"=") {
			lines[i] = key + "=" + value
			found = true
			break
		}
	}
	if !found {
		if n := len(lines); n > 0 && lines[n-1] == "" {
			lines[n-1] = key + "=" + value
			lines = append(lines, "")
		} else {
			lines = append(lines, key+"="+value)
		}
	}
	return os.WriteFile(path, []byte(strings.Join(lines, "\n")), 0o644)
}

func readWhitelist() []wlEntry {
	entries := []wlEntry{}
	data, err := os.ReadFile(filepath.Join(cfg.MCDir, "whitelist.json"))
	if err != nil {
		return entries
	}
	_ = json.Unmarshal(data, &entries)
	return entries
}

func writeWhitelist(entries []wlEntry) error {
	data, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(cfg.MCDir, "whitelist.json"), data, 0o644)
}

// --- validation ---------------------------------------------------------------

func validateValue(key, value string) error {
	switch key {
	case "difficulty":
		if !inSet(value, "peaceful", "easy", "normal", "hard") {
			return fmt.Errorf("difficulty must be peaceful/easy/normal/hard")
		}
	case "gamemode":
		if !inSet(value, "survival", "creative", "adventure", "spectator") {
			return fmt.Errorf("gamemode must be survival/creative/adventure/spectator")
		}
	case "max-players":
		if n, err := strconv.Atoi(value); err != nil || n < 0 {
			return fmt.Errorf("max-players must be an integer >= 0")
		}
	case "view-distance", "simulation-distance":
		if n, err := strconv.Atoi(value); err != nil || n < 3 || n > 32 {
			return fmt.Errorf("%s must be an integer 3..32", key)
		}
	case "pvp", "hardcore":
		if value != "true" && value != "false" {
			return fmt.Errorf("%s must be true or false", key)
		}
	case "motd":
		// any string
	default:
		return fmt.Errorf("unknown key")
	}
	return nil
}

func normalizeMotd(v string) string { return strings.ReplaceAll(v, "&", `§`) }

// modernMC reports whether the version uses the pvp gamerule (1.21.9+, or an
// annual edition whose major component is > 21, e.g. 26.x).
func modernMC(ver string) bool {
	if ver == "" {
		return false
	}
	parts := strings.SplitN(ver, ".", 3)
	major, err := strconv.Atoi(parts[0])
	if err != nil {
		return false
	}
	if major > 21 {
		return true
	}
	if major == 1 && len(parts) >= 2 {
		minor, err := strconv.Atoi(parts[1])
		if err != nil {
			return false
		}
		if minor > 21 {
			return true
		}
		if minor == 21 && len(parts) >= 3 {
			ps := parts[2]
			j := 0
			for j < len(ps) && ps[j] >= '0' && ps[j] <= '9' {
				j++
			}
			if j > 0 {
				if patch, _ := strconv.Atoi(ps[:j]); patch >= 9 {
					return true
				}
			}
		}
	}
	return false
}

// --- small utilities ----------------------------------------------------------

func getJSON(u string, v any) error {
	resp, err := httpClient.Get(u)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("http %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func httpErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]any{"error": msg})
}

func inSet(v string, set ...string) bool {
	for _, s := range set {
		if v == s {
			return true
		}
	}
	return false
}

func contains(sl []string, v string) bool {
	for _, s := range sl {
		if s == v {
			return true
		}
	}
	return false
}

func loadEnvFile(path string) map[string]string {
	m := map[string]string{}
	data, err := os.ReadFile(path)
	if err != nil {
		return m
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if i := strings.IndexByte(line, '='); i >= 0 {
			m[strings.TrimSpace(line[:i])] = strings.TrimSpace(line[i+1:])
		}
	}
	return m
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, "fatal:", err)
	os.Exit(1)
}
