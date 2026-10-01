package syncclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"
)

type Project struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Path      string    `json:"path"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type Lease struct {
	ProjectID  string    `json:"project_id"`
	LeaseID    string    `json:"lease_id"`
	DeviceID   string    `json:"device_id"`
	DeviceName string    `json:"device_name"`
	ExpiresAt  time.Time `json:"expires_at"`
	UpdatedAt  time.Time `json:"updated_at"`
}

type Client struct {
	Server *url.URL
	Token  string
	HTTP   *http.Client
}

func NewClient(server, token string) (*Client, error) {
	base, err := url.Parse(strings.TrimRight(server, "/"))
	if err != nil || base.Scheme == "" || base.Host == "" {
		return nil, fmt.Errorf("invalid server URL")
	}
	return &Client{
		Server: base,
		Token:  token,
		HTTP:   &http.Client{Timeout: 2 * time.Minute},
	}, nil
}

func (c *Client) Projects(ctx context.Context, sessionID string) ([]Project, error) {
	var out []Project
	err := c.doJSON(ctx, http.MethodGet, "/api/sessions/"+url.PathEscape(sessionID)+"/projects", nil, &out)
	return out, err
}

// Manifest fetches the server-side manifest. When ifRevision is non-empty and
// the server manifest still carries that revision, the server answers
// 204-without-body and notModified is true — the caller then reuses its cached
// manifest instead of transferring it again.
func (c *Client) Manifest(ctx context.Context, projectID, ifRevision string) (Manifest, bool, error) {
	req, err := c.request(ctx, http.MethodGet, "/api/sync/projects/"+url.PathEscape(projectID)+"/manifest", nil)
	if err != nil {
		return Manifest{}, false, err
	}
	if ifRevision != "" {
		req.Header.Set("X-Agentbox-If-Revision", ifRevision)
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return Manifest{}, false, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNoContent {
		return Manifest{}, true, nil
	}
	if err := responseError(resp); err != nil {
		return Manifest{}, false, err
	}
	var out Manifest
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return Manifest{}, false, err
	}
	return out, false, nil
}

func (c *Client) AcquireLease(
	ctx context.Context,
	projectID, deviceID, deviceName string,
	ttl time.Duration,
) (Lease, error) {
	body := map[string]any{
		"device_id":   deviceID,
		"device_name": deviceName,
		"ttl_seconds": int(ttl.Seconds()),
	}
	var out Lease
	err := c.doJSON(ctx, http.MethodPost, "/api/sync/projects/"+url.PathEscape(projectID)+"/lease", body, &out)
	return out, err
}

func (c *Client) ReleaseLease(ctx context.Context, projectID, leaseID string) error {
	req, err := c.request(ctx, http.MethodDelete, "/api/sync/projects/"+url.PathEscape(projectID)+"/lease", nil)
	if err != nil {
		return err
	}
	req.Header.Set("X-Agentbox-Lease", leaseID)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return responseError(resp)
}

func (c *Client) PutFile(
	ctx context.Context,
	projectID, leaseID, deviceID string,
	entry Entry,
	body io.Reader,
) error {
	rel := url.Values{"path": []string{entry.Path}}.Encode()
	// net/http takes ownership of a request body that is an io.ReadCloser and
	// closes it once the request is sent. The caller still owns this reader —
	// applyPlan closes the file right after this returns — so hide the
	// ReadCloser-ness and let NewRequest wrap it in a NopCloser instead.
	// Without this every upload fails with "file already closed".
	req, err := c.request(
		ctx,
		http.MethodPut,
		"/api/sync/projects/"+url.PathEscape(projectID)+"/file?"+rel,
		readerOnly(body),
	)
	if err != nil {
		return err
	}
	req.Header.Set("X-Agentbox-Lease", leaseID)
	req.Header.Set("X-Agentbox-Device", deviceID)
	req.Header.Set("X-Agentbox-File-Mode", strconv.FormatUint(uint64(entry.Mode), 8))
	if entry.Kind == "dir" {
		req.Header.Set("X-Agentbox-Kind", "dir")
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return responseError(resp)
}

func (c *Client) OpenFile(ctx context.Context, projectID, rel string) (io.ReadCloser, error) {
	query := url.Values{"path": []string{rel}}.Encode()
	req, err := c.request(ctx, http.MethodGet,
		"/api/sync/projects/"+url.PathEscape(projectID)+"/file?"+query, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	if err := responseError(resp); err != nil {
		resp.Body.Close()
		return nil, err
	}
	return resp.Body, nil
}

func (c *Client) DeleteFile(
	ctx context.Context,
	projectID, leaseID, deviceID, rel string,
) error {
	query := url.Values{"path": []string{path.Clean(rel)}}.Encode()
	req, err := c.request(ctx, http.MethodDelete,
		"/api/sync/projects/"+url.PathEscape(projectID)+"/file?"+query, nil)
	if err != nil {
		return err
	}
	req.Header.Set("X-Agentbox-Lease", leaseID)
	req.Header.Set("X-Agentbox-Device", deviceID)
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return responseError(resp)
}

func (c *Client) doJSON(
	ctx context.Context,
	method, route string,
	body any,
	out any,
) error {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(raw)
	}
	req, err := c.request(ctx, method, route, reader)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if err := responseError(resp); err != nil {
		return err
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func (c *Client) request(
	ctx context.Context,
	method, route string,
	body io.Reader,
) (*http.Request, error) {
	// Routes carry their query inline ("…/file?path=x"). Assigning that
	// straight to URL.Path escapes the '?' and sends the query as part of the
	// path, so the server's "/file" pattern never matched and every file
	// read, write and delete came back 404. Split it properly.
	rel, err := url.Parse(route)
	if err != nil {
		return nil, err
	}
	target := *c.Server
	target.Path = strings.TrimRight(target.Path, "/") + rel.Path
	target.RawQuery = rel.RawQuery
	req, err := http.NewRequestWithContext(ctx, method, target.String(), body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+c.Token)
	return req, nil
}

// readerOnly hides the ReadCloser-ness of a request body so net/http wraps it
// in an io.NopCloser instead of adopting it and closing it on the caller's
// behalf.
func readerOnly(body io.Reader) io.Reader {
	if body == nil {
		return nil
	}
	return struct{ io.Reader }{body}
}

func responseError(resp *http.Response) error {
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	var payload struct {
		Error string `json:"error"`
	}
	_ = json.NewDecoder(io.LimitReader(resp.Body, 16<<10)).Decode(&payload)
	if payload.Error == "" {
		payload.Error = resp.Status
	}
	return &HTTPError{Status: resp.StatusCode, Message: payload.Error}
}

type HTTPError struct {
	Status  int
	Message string
}

func (e *HTTPError) Error() string { return e.Message }
