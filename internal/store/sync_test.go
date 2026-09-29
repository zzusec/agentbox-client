package store

import (
	"path/filepath"
	"testing"
	"time"
)

func TestReconcileSyncProjectsKeepsStableIDs(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	first, err := st.ReconcileSyncProjects("s1", []string{"alpha", "beta"})
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != 2 {
		t.Fatalf("projects = %+v", first)
	}
	ids := map[string]string{}
	for _, p := range first {
		ids[p.Name] = p.ID
	}

	second, err := st.ReconcileSyncProjects("s1", []string{"alpha", "gamma"})
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, p := range second {
		got[p.Name] = p.ID
	}
	if got["alpha"] != ids["alpha"] {
		t.Fatalf("alpha id changed: %q -> %q", ids["alpha"], got["alpha"])
	}
	if _, ok := got["beta"]; ok {
		t.Fatal("removed project kept registry row")
	}
	if got["gamma"] == "" || got["gamma"] == ids["alpha"] {
		t.Fatalf("gamma got invalid id %q", got["gamma"])
	}
}

func TestSyncLeaseRejectsOtherDeviceUntilExpiry(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	projects, err := st.ReconcileSyncProjects("s1", []string{"alpha"})
	if err != nil {
		t.Fatal(err)
	}
	project := projects[0]
	now := time.Now()

	first, ok, err := st.AcquireSyncLease(project.ID, "mac-a", "Mac A", time.Minute, now)
	if err != nil || !ok {
		t.Fatalf("first lease = %+v ok=%v err=%v", first, ok, err)
	}
	second, ok, err := st.AcquireSyncLease(project.ID, "mac-b", "Mac B", time.Minute, now.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if ok || second.DeviceID != "mac-a" {
		t.Fatalf("other device acquired lease: %+v ok=%v", second, ok)
	}

	taken, ok, err := st.AcquireSyncLease(project.ID, "mac-b", "Mac B", time.Minute, now.Add(2*time.Minute))
	if err != nil || !ok || taken.DeviceID != "mac-b" {
		t.Fatalf("expired lease not taken: %+v ok=%v err=%v", taken, ok, err)
	}
	if _, valid := st.ValidateSyncLease(project.ID, first.LeaseID, now.Add(2*time.Minute)); valid {
		t.Fatal("superseded lease remained valid")
	}
	if _, valid := st.ValidateSyncLease(project.ID, taken.LeaseID, now.Add(2*time.Minute)); !valid {
		t.Fatal("new lease was not valid")
	}
}
