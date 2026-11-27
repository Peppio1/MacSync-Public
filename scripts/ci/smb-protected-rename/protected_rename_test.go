package smb2

import (
    "context"
    "errors"
    "fmt"
    "os"
    "path/filepath"
    "strings"
    "testing"
    "time"
)

// CI-only: never accepts a production address, share, account or caller path.
// The historical MacSync no-replace patch is tested here, not shipped.
func TestMacSyncProtectedRenameFixture(t *testing.T) {
    if os.Getenv("MACSYNC_TEST_SMB_HOST") != "127.0.0.1" ||
        os.Getenv("MACSYNC_TEST_SMB_SHARE") != "MacSyncCI" {
        t.Fatal("Disposable SMB fixture required")
    }
    fixture := os.Getenv("MACSYNC_TEST_SMB_ROOT")
    if fixture != filepath.Join(os.Getenv("RUNNER_TEMP"), "macsync-smb-fixture") {
        t.Fatal("Unexpected fixture")
    }
    raw, err := os.ReadFile(filepath.Join(fixture, "share-path"))
    if err != nil { t.Fatal("Fixture root unavailable") }
    root := strings.TrimSpace(string(raw))
    if filepath.Dir(root) != "/private/tmp" ||
        !strings.HasPrefix(filepath.Base(root), "macsync-ci-share.") {
        t.Fatal("Unexpected server root")
    }
    auth, err := os.ReadFile(filepath.Join(fixture, "smbclient-auth"))
    if err != nil { t.Fatal("Fixture credential unavailable") }
    creds := map[string]string{}
    for _, line := range strings.Split(string(auth), "\n") {
        if key, val, ok := strings.Cut(line, " = "); ok { creds[key] = val }
    }
    if creds["username"] == "" || creds["password"] == "" {
        t.Fatal("Incomplete fixture credential")
    }
    ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
    defer cancel()
    d := Dialer{Initiator: &NTLMInitiator{User: creds["username"], Password: creds["password"], Domain: "WORKGROUP"}}
    sess, err := d.Dial(ctx, "127.0.0.1:445")
    if err != nil { t.Fatal("Fixture authentication failed") }
    sess = sess.WithContext(ctx)
    defer sess.Logoff()
    share, err := sess.Mount("MacSyncCI")
    if err != nil { t.Fatal("Fixture share unavailable") }
    share = share.WithContext(ctx)
    defer share.Umount()

    const folder = "macsync-ci-protected"
    native := filepath.Join(root, folder)
    wire := func(name string) string { return folder + "\\" + strings.ReplaceAll(name, "/", "\\") }
    list := func() map[string]bool {
        entries, e := share.ReadDir(folder)
        if e != nil { t.Fatal("Exact parent listing failed") }
        names := map[string]bool{}
        for _, entry := range entries {
            if names[entry.Name()] { t.Fatal("Duplicate exact name") }
            names[entry.Name()] = true
        }
        return names
    }
    stat := func(name string) *FileStat {
        h, e := share.Open(wire(name))
        if e != nil { t.Fatalf("Open failed for synthetic name %q", name) }
        fi, e := h.Stat()
        ce := h.Close()
        if e != nil || ce != nil { t.Fatal("Open-handle stat failed") }
        s, ok := fi.Sys().(*FileStat)
        if !ok || s.FileId == 0 || s.CreationTime.IsZero() ||
            fi.Mode() & os.ModeSymlink != 0 { t.Fatal("Unverifiable object identity") }
        return s
    }
    verify := func(expected *FileStat, wrongID bool) func(os.FileInfo) error {
        return func(fi os.FileInfo) error {
            actual, ok := fi.Sys().(*FileStat)
            if !ok || actual.FileId == 0 || wrongID ||
                actual.FileId != expected.FileId ||
                !actual.CreationTime.Equal(expected.CreationTime) ||
                fi.Mode() & os.ModeSymlink != 0 ||
                fi.IsDir() != expected.IsDir() ||
                fi.Size() != expected.Size() ||
                !fi.ModTime().Equal(expected.ModTime()) {
                return errors.New("identity mismatch")
            }
            return nil
        }
    }
    checkBytes := func(name, want string) {
        b, e := os.ReadFile(filepath.Join(native, name))
        if e != nil || string(b) != want { t.Fatalf("Raw sentinel changed: %q", name) }
    }
    absent := func(name string) {
        if _, e := os.Lstat(filepath.Join(native, name)); !os.IsNotExist(e) {
            t.Fatalf("Unexpected raw name: %q", name)
        }
    }
    sameID := func(name string, expected *FileStat) {
        after := stat(name)
        if after.FileId != expected.FileId || !after.CreationTime.Equal(expected.CreationTime) {
            t.Fatalf("Object identity changed: %q", name)
        }
    }

    initial := list()
    for _, name := range []string{"File.", "Collision.", "Collision-", "Directory.", "Wrong."} {
        if !initial[name] { t.Fatalf("Expected exact name missing: %q", name) }
    }
    old := stat("File.")
    collision := stat("Collision.")
    occupied := stat("Collision-")
    wrong := stat("Wrong.")
    dir := stat("Directory.")
    child := stat("Directory./child.jpg")
    if collision.FileId == occupied.FileId { t.Fatal("Fixture aliases not distinct") }

    // Reject a wrong fingerprint, even when the destination is free.
    if e := share.RenameNoReplace(wire("Wrong."), wire("Wrong-"), verify(wrong, true)); e == nil {
        t.Fatal("Wrong identity accepted")
    }
    checkBytes("Wrong.", "wrong-source")
    absent("Wrong-")
    sameID("Wrong.", wrong)
    fmt.Println("WRONG_IDENTITY_REJECTED")

    // A destination can appear after a preflight: the server itself must refuse.
    if e := share.RenameNoReplace(wire("Collision."), wire("Collision-"), verify(collision, false)); e == nil {
        t.Fatal("Occupied destination accepted")
    }
    checkBytes("Collision.", "collision-old")
    checkBytes("Collision-", "collision-new")
    sameID("Collision.", collision)
    sameID("Collision-", occupied)
    fmt.Println("OCCUPIED_DESTINATION_PRESERVED")

    // Single server-side operation; no copy/delete fallback.
    if e := share.RenameNoReplace(wire("File."), wire("File-"), verify(old, false)); e != nil {
        t.Fatal("Protected file rename failed")
    }
    absent("File.")
    checkBytes("File-", "file-source")
    sameID("File-", old)
    fmt.Println("FILE_RENAME_IDENTITY_PRESERVED")

    if e := share.RenameNoReplace(wire("Directory."), wire("Directory-"), verify(dir, false)); e != nil {
        t.Fatal("Protected directory rename failed")
    }
    absent("Directory.")
    checkBytes("Directory-/child.jpg", "directory-child")
    sameID("Directory-", dir)
    sameID("Directory-/child.jpg", child)
    final := list()
    if final["File."] || final["Directory."] || !final["File-"] || !final["Directory-"] {
        t.Fatal("Unexpected final enumeration")
    }
    fmt.Println("DIRECTORY_RENAME_AND_CHILD_IDENTITY_PRESERVED")
}
