package dockerx

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"agentbox/internal/config"
	"agentbox/internal/store"
	"github.com/docker/docker/client"
)

func TestEnsureRunningPreservesExistingContainers(t *testing.T) {
	for _, running := range []bool{false, true} {
		t.Run(map[bool]string{false: "stopped", true: "running"}[running], func(t *testing.T) {
			var mutex sync.Mutex
			var writes []string
			server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
				writer.Header().Set("Content-Type", "application/json")
				if request.Method != http.MethodGet {
					mutex.Lock()
					writes = append(writes, request.Method+" "+request.URL.Path)
					mutex.Unlock()
					if request.Method == http.MethodPost && strings.HasSuffix(request.URL.Path, "/legacy/start") {
						writer.WriteHeader(http.StatusNoContent)
						return
					}
					writer.WriteHeader(http.StatusForbidden)
					return
				}
				if strings.HasSuffix(request.URL.Path, "/containers/legacy/json") {
					json.NewEncoder(writer).Encode(map[string]any{
						"Id": "legacy", "Image": "old-image",
						"State":  map[string]any{"Running": running},
						"Config": map[string]any{"Env": baseContainerEnv()},
						"Mounts": []map[string]any{{"Destination": WorkspaceMount}, {"Destination": SharedMount}},
					})
					return
				}
				if strings.Contains(request.URL.Path, "/images/") {
					json.NewEncoder(writer).Encode(map[string]any{"Id": "new-image", "Config": map[string]any{"Env": baseContainerEnv()}})
					return
				}
				writer.WriteHeader(http.StatusNotFound)
			}))
			defer server.Close()
			docker, err := client.NewClientWithOpts(client.WithHost(server.URL), client.WithVersion("1.45"))
			if err != nil {
				t.Fatal(err)
			}
			defer docker.Close()
			manager := &Manager{cli: docker, cfg: &config.Config{AgentImage: "new-image"}}
			id, err := manager.EnsureRunning(t.Context(), store.Session{ContainerID: "legacy"}, config.Account{}, "/data/workspace", "/data/home", "/data/shared")
			if err != nil || id != "legacy" {
				t.Fatalf("container not preserved: id=%q error=%v", id, err)
			}
			mutex.Lock()
			defer mutex.Unlock()
			if running && len(writes) != 0 || !running && (len(writes) != 1 || !strings.HasSuffix(writes[0], "/legacy/start")) {
				t.Fatalf("unexpected Docker mutation: %v", writes)
			}
		})
	}
}

func TestEnsureRunningInspectFailureDoesNotRecreate(t *testing.T) {
	var writes int
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Method != http.MethodGet {
			writes++
		}
		writer.Header().Set("Content-Type", "application/json")
		writer.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(writer).Encode(map[string]string{"message": "synthetic inspect failure"})
	}))
	defer server.Close()
	docker, err := client.NewClientWithOpts(client.WithHost(server.URL), client.WithVersion("1.45"))
	if err != nil {
		t.Fatal(err)
	}
	defer docker.Close()
	manager := &Manager{cli: docker, cfg: &config.Config{AgentImage: "new-image"}}
	if _, err := manager.EnsureRunning(t.Context(), store.Session{ContainerID: "legacy"}, config.Account{}, "/data/workspace", "/data/home", "/data/shared"); err == nil {
		t.Fatal("inspection failure was ignored")
	}
	if writes != 0 {
		t.Fatalf("inspection failure triggered %d writes", writes)
	}
}
