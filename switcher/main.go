// Command vpn-switcher serves a tiny web UI (exposed over the tailnet via
// `tailscale serve`) to change the Gluetun/ProtonVPN exit country without SSH.
//
// On selection it rewrites SERVER_COUNTRIES in the project's .env file and
// recreates the gluetun container via `docker compose up -d gluetun`.
package main

import (
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"time"
)

// allowedCountries is the server-side allow-list. User input must match one of
// these exactly before it is ever written to .env or passed to compose, so a
// malicious value can't be injected. Names are ProtonVPN country names as
// understood by Gluetun's SERVER_COUNTRIES.
var allowedCountries = []string{
	"Switzerland", "Ireland",
}

func isAllowed(c string) bool {
	for _, a := range allowedCountries {
		if a == c {
			return true
		}
	}
	return false
}

type config struct {
	envFile     string
	composeFile string
	project     string
	gluetunURL  string
	listen      string
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	sort.Strings(allowedCountries) // sort once; handlers read it concurrently
	cfg := config{
		envFile:     env("ENV_FILE", "/project/.env"),
		composeFile: env("COMPOSE_FILE", "/project/docker-compose.yml"),
		project:     env("COMPOSE_PROJECT_NAME", "vpn-ts"),
		gluetunURL:  env("GLUETUN_URL", "http://172.28.0.2:8000"),
		listen:      env("LISTEN", ":8080"),
	}

	http.HandleFunc("/", cfg.handleIndex)
	http.HandleFunc("/set", cfg.handleSet)

	log.Printf("vpn-switcher listening on %s (project=%s)", cfg.listen, cfg.project)
	log.Fatal(http.ListenAndServe(cfg.listen, nil))
}

var serverCountriesRe = regexp.MustCompile(`(?m)^SERVER_COUNTRIES=(.*)$`)

// configuredCountry reads the current SERVER_COUNTRIES value from .env.
func (c config) configuredCountry() string {
	data, err := os.ReadFile(c.envFile)
	if err != nil {
		return ""
	}
	if m := serverCountriesRe.FindSubmatch(data); m != nil {
		return strings.TrimSpace(string(m[1]))
	}
	return ""
}

// egress queries Gluetun's control server for the live public IP + country.
func (c config) egress() string {
	client := http.Client{Timeout: 4 * time.Second}
	resp, err := client.Get(c.gluetunURL + "/v1/publicip/ip")
	if err != nil {
		return "unknown (gluetun unreachable)"
	}
	defer resp.Body.Close()
	var v struct {
		PublicIP string `json:"public_ip"`
		Country  string `json:"country"`
		City     string `json:"city"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&v); err != nil {
		return "unknown"
	}
	parts := []string{}
	if v.Country != "" {
		parts = append(parts, v.Country)
	}
	if v.City != "" {
		parts = append(parts, v.City)
	}
	if v.PublicIP != "" {
		parts = append(parts, "("+v.PublicIP+")")
	}
	if len(parts) == 0 {
		return "unknown"
	}
	return strings.Join(parts, " ")
}

// setCountry rewrites SERVER_COUNTRIES in .env (creating the line if missing).
func (c config) setCountry(country string) error {
	data, err := os.ReadFile(c.envFile)
	if err != nil {
		return fmt.Errorf("read env: %w", err)
	}
	line := "SERVER_COUNTRIES=" + country
	var out string
	if serverCountriesRe.Match(data) {
		out = serverCountriesRe.ReplaceAllString(string(data), line)
	} else {
		out = strings.TrimRight(string(data), "\n") + "\n" + line + "\n"
	}
	return os.WriteFile(c.envFile, []byte(out), 0o600)
}

// recreateGluetun applies the new env by recreating just the gluetun service.
func (c config) recreateGluetun() (string, error) {
	cmd := exec.Command("docker", "compose",
		"-f", c.composeFile, "-p", c.project,
		"up", "-d", "--force-recreate", "gluetun")
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func (c config) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	data := pageData{
		Countries: allowedCountries,
		Current:   c.configuredCountry(),
		Egress:    c.egress(),
	}
	render(w, data)
}

func (c config) handleSet(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	country := strings.TrimSpace(r.FormValue("country"))
	if !isAllowed(country) {
		http.Error(w, "unknown country", http.StatusBadRequest)
		return
	}
	if err := c.setCountry(country); err != nil {
		http.Error(w, "failed to update config: "+err.Error(), http.StatusInternalServerError)
		return
	}
	log.Printf("switching to %s; recreating gluetun...", country)
	out, err := c.recreateGluetun()
	data := pageData{
		Countries: allowedCountries,
		Current:   c.configuredCountry(),
		Egress:    "reconnecting...",
		Message:   fmt.Sprintf("Switched to %s. Gluetun is reconnecting (give it ~15-30s).", country),
		Log:       out,
	}
	if err != nil {
		data.Message = "Updated .env but failed to recreate gluetun: " + err.Error()
		data.Error = true
	}
	render(w, data)
}

type pageData struct {
	Countries []string
	Current   string
	Egress    string
	Message   string
	Log       string
	Error     bool
}

func render(w http.ResponseWriter, d pageData) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := tmpl.Execute(w, d); err != nil {
		log.Printf("template: %v", err)
	}
}

var tmpl = template.Must(template.New("page").Parse(`<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>VPN exit country</title>
<style>
  body{font-family:system-ui,sans-serif;max-width:640px;margin:2rem auto;padding:0 1rem;color:#222}
  h1{font-size:1.4rem}
  .card{border:1px solid #ddd;border-radius:8px;padding:1rem;margin:1rem 0}
  .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:.5rem}
  button{padding:.6rem;border:1px solid #bbb;border-radius:6px;background:#f7f7f7;cursor:pointer;font-size:.95rem}
  button:hover{background:#eee}
  button.cur{border-color:#2a7;background:#e8f8ef;font-weight:600}
  .msg{padding:.75rem;border-radius:6px;background:#eef6ff;border:1px solid #bcd}
  .err{background:#fdecec;border-color:#e0a6a6}
  pre{background:#f4f4f4;padding:.5rem;border-radius:6px;overflow:auto;font-size:.8rem}
  .muted{color:#777;font-size:.9rem}
</style></head><body>
<h1>VPN exit country</h1>
{{if .Message}}<div class="msg {{if .Error}}err{{end}}">{{.Message}}</div>{{end}}
<div class="card">
  <div>Configured: <strong>{{if .Current}}{{.Current}}{{else}}(unset){{end}}</strong></div>
  <div class="muted">Live egress: {{.Egress}}</div>
</div>
<form method="post" action="/set">
  <div class="grid">
  {{range .Countries}}
    <button name="country" value="{{.}}" class="{{if eq . $.Current}}cur{{end}}">{{.}}</button>
  {{end}}
  </div>
</form>
{{if .Log}}<details><summary>compose output</summary><pre>{{.Log}}</pre></details>{{end}}
</body></html>`))
