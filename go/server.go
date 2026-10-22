package erupt

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// ---------------------------------------------------------------- permissions (PROTOCOL.md §6.1)

func (n *Node) require(q *request, right string) error {
	if !n.power(q, q.model)[right] {
		return reply{403}
	}
	return nil
}

// power is the declared power ANDed with the server's verdict for the session token, cached 5s. Without
// the server's verdict nothing is writable. When a signed call says the server enforced power, the
// declared power alone.
func (n *Node) power(q *request, m *Model) map[string]bool {
	if q.enforced["power"] {
		// the server checked the user's rights and restricts the build's power itself: the model's own
		// declaration is all that is left to apply here
		power := map[string]bool{}
		for k, v := range m.power {
			power[k] = v
		}
		for k, v := range unsupportedPower {
			power[k] = v
		}
		return power
	}
	token := q.r.Header.Get("token")
	key := [2]string{token, m.name}
	n.powerMu.Lock()
	cached, ok := n.powers[key]
	n.powerMu.Unlock()
	if ok && time.Now().Before(cached.until) {
		return cached.power
	}
	power := map[string]bool{}
	for k, v := range m.power {
		power[k] = v
	}
	for k, v := range unsupportedPower {
		power[k] = v
	}
	remote := map[string]any{}
	if err := n.serverGet(q.ctx, "/erupt-cloud-api/erupt-power", url.Values{"nodeName": {n.cfg.Name}, "eruptName": {m.name}}, token, &remote); err != nil {
		n.cfg.Logger.Printf("erupt-power unavailable: %v", err)
	}
	for _, right := range serverPower {
		granted, _ := remote[right].(bool)
		power[right] = power[right] && granted
	}
	n.powerMu.Lock()
	if len(n.powers) > 10000 {
		n.powers = map[[2]string]cachedPower{}
	}
	n.powers[key] = cachedPower{time.Now().Add(5 * time.Second), power}
	n.powerMu.Unlock()
	return power
}

// ---------------------------------------------------------------- server calls

func (n *Node) server() string {
	return n.cfg.Servers[int((n.next.Add(1)-1)%uint64(len(n.cfg.Servers)))]
}

func (n *Node) serverGet(ctx context.Context, path string, params url.Values, token string, out any) error {
	body, err := n.serverText(ctx, path+"?"+params.Encode(), map[string]string{"token": token})
	if err != nil {
		return err
	}
	return json.Unmarshal([]byte(body), out)
}

func (n *Node) serverText(ctx context.Context, path string, headers map[string]string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", n.server()+path, nil)
	if err != nil {
		return "", err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := n.client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode/100 != 2 {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return string(body), nil
}

// NodeConfig is the config text set for this node on the erupt server (Node Config).
func (n *Node) NodeConfig(ctx context.Context) (string, error) {
	return n.serverText(ctx, "/erupt-cloud-api/node-config/"+url.PathEscape(n.cfg.Name), map[string]string{"Access-Token": n.cfg.AccessToken})
}

// GroupConfig is the config text of this node's group on the erupt server.
func (n *Node) GroupConfig(ctx context.Context) (string, error) {
	return n.serverText(ctx, "/erupt-cloud-api/node-group-config/"+url.PathEscape(n.cfg.Name), map[string]string{"Access-Token": n.cfg.AccessToken})
}

// UserInfo is the acting user's full info from the erupt server (roles, org, post...), for the request ctx
// serves; nil when the server answers nothing.
func (n *Node) UserInfo(ctx context.Context) (M, error) {
	token, _ := ctx.Value(tokenKey{}).(string)
	text, err := n.serverText(ctx, "/erupt-cloud-api/userinfo/"+url.PathEscape(n.cfg.Name),
		map[string]string{"Access-Token": n.cfg.AccessToken, "token": token})
	if err != nil || strings.TrimSpace(text) == "" {
		return nil, err
	}
	var info M
	return info, json.Unmarshal([]byte(text), &info)
}

func (n *Node) post(path, contentType string, body string) error {
	resp, err := n.client.Post(n.server()+path, contentType, strings.NewReader(body))
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

// register announces the node once; Heartbeat repeats it.
func (n *Node) register(instanceID string) error {
	n.mu.RLock()
	erupts := append([]string{}, n.names...)
	n.mu.RUnlock()
	info, err := json.Marshal(M{"instanceId": instanceID, "nodeName": n.cfg.Name, "accessToken": n.cfg.AccessToken,
		"version": "go-" + Version, "nodeAddress": []string{n.cfg.Address}, "eruptModules": []string{},
		"erupts": erupts, "resources": M{}, "capabilities": []string{"invoke"}})
	if err != nil {
		return err
	}
	return n.post("/erupt-cloud-api/register-node", "application/json", string(info))
}

// Heartbeat registers the node every Config.Heartbeat until ctx is done. Use it when the node is mounted
// in your own server (Config.Address must then be set); ListenAndServe runs it for you.
func (n *Node) Heartbeat(ctx context.Context) {
	id := make([]byte, 3)
	_, _ = rand.Read(id)
	instanceID := hex.EncodeToString(id)
	failing := false
	for {
		wait := n.cfg.Heartbeat
		if err := n.register(instanceID); err != nil {
			failing = true
			n.cfg.Logger.Printf("erupt: register failed: %v", err)
			wait /= 2
		} else if failing {
			failing = false
			n.cfg.Logger.Printf("erupt: connection success")
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		}
	}
}

// Deregister tells the server to stop routing to this instance at once.
func (n *Node) Deregister() error {
	form := url.Values{"nodeName": {n.cfg.Name}, "accessToken": {n.cfg.AccessToken}, "locations": {n.cfg.Address}}
	return n.post("/erupt-cloud-api/remove-instance-node", "application/x-www-form-urlencoded", form.Encode())
}

// ListenAndServe serves the node on addr (e.g. ":9090"), registers it once the listener is up (the server
// probes /node-health while registering) and, on SIGINT or SIGTERM, deregisters and drains in-flight
// requests before returning.
func (n *Node) ListenAndServe(addr string) error {
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	if n.cfg.Address == "" {
		port := listener.Addr().(*net.TCPAddr).Port
		// JoinHostPort brackets an IPv6 address, which a URL requires
		n.cfg.Address = "http://" + net.JoinHostPort(localIP(n.cfg.Servers[0]), strconv.Itoa(port))
	}
	n.cfg.Address = strings.TrimRight(n.cfg.Address, "/")
	srv := &http.Server{Handler: n, ReadHeaderTimeout: 10 * time.Second}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	served := make(chan error, 1)
	go func() { served <- srv.Serve(listener) }()
	beat, stopBeat := context.WithCancel(ctx)
	defer stopBeat()
	go n.Heartbeat(beat)
	n.cfg.Logger.Printf("erupt node '%s' at %s -> %s", n.cfg.Name, n.cfg.Address, strings.Join(n.cfg.Servers, ", "))
	select {
	case err := <-served:
		return err
	case <-ctx.Done():
	}
	stopBeat()
	if err := n.Deregister(); err != nil {
		n.cfg.Logger.Printf("erupt: deregister failed: %v", err)
	}
	drain, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return srv.Shutdown(drain)
}

// localIP is the interface address the server would see us on.
func localIP(server string) string {
	host := "127.0.0.1"
	if u, err := url.Parse(server); err == nil && u.Hostname() != "" {
		host = u.Hostname()
	}
	// prefer IPv4: "localhost" may resolve to ::1 first, and IPv4 is what servers usually reach nodes on
	conn, err := net.Dial("udp4", net.JoinHostPort(host, "80"))
	if err != nil {
		if conn, err = net.Dial("udp", net.JoinHostPort(host, "80")); err != nil {
			return "127.0.0.1"
		}
	}
	defer conn.Close()
	return conn.LocalAddr().(*net.UDPAddr).IP.String()
}
