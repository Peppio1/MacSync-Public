package smb2

import (
    "context"
    "errors"
    "io"
    protocol "github.com/cloudsoda/go-smb2/internal/smb2"
    "fmt"
    "os"
    "path/filepath"
    "strings"
    "testing"
    "syscall"
    "time"
)

// CI-only: never accepts a production address, share, account or caller path.
// This test-only deletion primitive is not shipped.
func TestMacSyncProtectedDeletionFixture(t *testing.T) {
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

    const folder = "macsync-ci-protected-delete"
    native := filepath.Join(root, folder)
    wire := func(name string) string { return folder + "\\" + strings.ReplaceAll(name, "/", "\\") }
    // Raw enumeration is a candidate hint. Confirm exact spelling and
    // file reference again on an opened, non-reparse, exclusive handle.
    listed := func(name string) *FileStat {
        parent, leaf := filepath.Split(name)
        dir := folder
        if parent != "" { dir = wire(strings.TrimSuffix(parent, "/")) }
        rows, e := share.ReadDir(dir)
        if e != nil { t.Fatal("Parent listing failed") }
        var found *FileStat
        for _, row := range rows {
            if row.Name() != leaf { continue }
            s, ok := row.Sys().(*FileStat)
            if !ok || found != nil || s.FileId == 0 || s.Mode() & os.ModeSymlink != 0 {
                t.Fatal("Unverifiable exact listing identity")
            }
            found = s
        }
        if found == nil { t.Fatalf("Exact synthetic name missing: %q", name) }
        return found
    }
    locked := func(name string, deletion bool) (*File, error) {
        access := uint32(protocol.GENERIC_READ | protocol.FILE_READ_ATTRIBUTES)
        if deletion { access |= protocol.DELETE }
        // No share-write or share-delete; fail rather than bypass a lock.
        // No create, truncate, reparse traversal, chmod or retry fallback.
        req := &protocol.CreateRequest{
            RequestedOplockLevel: protocol.SMB2_OPLOCK_LEVEL_NONE,
            ImpersonationLevel: protocol.Impersonation,
            DesiredAccess: access,
            ShareAccess: protocol.FILE_SHARE_READ,
            CreateDisposition: protocol.FILE_OPEN,
            CreateOptions: protocol.FILE_OPEN_REPARSE_POINT,
            Mapping: share.mapping,
        }
        return share.createFile(wire(name), req, false)
    }
    matches := func(h *File, expected *FileStat) bool {
        fi, e := h.Stat()
        if e != nil { return false }
        s, ok := fi.Sys().(*FileStat)
        return ok && s.FileId != 0 && s.FileId == expected.FileId &&
            s.CreationTime.Equal(expected.CreationTime) &&
            s.Size() == expected.Size() && s.ModTime().Equal(expected.ModTime()) &&
            s.IsDir() == expected.IsDir() && s.Mode() & os.ModeSymlink == 0
    }
    // Only synthetic paths defined below, no generic user entry point.
    // The local expected bytes represent a previously verified source.
    removeDuplicate := func(old, corrected string, source []byte, wrongID bool) error {
        a, b := listed(old), listed(corrected)
        if a.FileId == b.FileId || a.IsDir() != b.IsDir() || wrongID {
            // Wrong-id case deliberately changes the expected reference
            // below rather than bypassing verification on the opened handle.
            if !wrongID { return errors.New("identity conflict") }
            aCopy := *a
            aCopy.FileId = 0
            a = &aCopy
        }
        h, e := locked(old, true)
        if e != nil { return e }
        defer h.Close()
        if !matches(h, a) { return errors.New("old identity changed") }
        n, e := locked(corrected, false)
        if e != nil { return e }
        defer n.Close()
        if !matches(n, b) { return errors.New("corrected identity changed") }
        if !a.IsDir() {
            if a.Size() != int64(len(source)) || b.Size() != a.Size() { return errors.New("size mismatch") }
            x, e := io.ReadAll(io.LimitReader(h, 4097))
            if e != nil { return e }
            y, e := io.ReadAll(io.LimitReader(n, 4097))
            if e != nil { return e }
            if string(x) != string(source) || string(y) != string(source) {
                return errors.New("different bytes")
            }
        } else {
            // Server enforces empty-directory disposition. Never recurse
            // or remove children here. A nonempty directory must fail.
            rows, e := h.Readdir(-1)
            if e != nil || len(rows) != 0 { return errors.New("nonempty or unreadable") }
        }
        if !matches(h, a) || !matches(n, b) || ctx.Err() != nil {
            return errors.New("revalidation failed")
        }
        // Same handle as the verification; bypass Share.Remove, which
        // changes permissions and retries on access-denied.
        if e := h.remove(); e != nil { return e }
        return h.Close()
    }
    checkBytes := func(name, want string) {
        data, e := os.ReadFile(filepath.Join(native, name))
        if e != nil || string(data) != want { t.Fatalf("Raw sentinel changed: %q", name) }
    }
    absent := func(name string) {
        if _, e := os.Lstat(filepath.Join(native, name)); !os.IsNotExist(e) {
            t.Fatalf("Expected raw absence: %q", name)
        }
    }

    // Diagnostic only: a same number alone cannot authorize an operation.
    // Compare the mounted inode with the direct SMB file reference for a
    // compatible control, and report rather than assume this invariant.
    mount := os.Getenv("MACSYNC_TEST_SMB_MOUNT")
    if mount != filepath.Join(fixture, "mounted") { t.Fatal("Unexpected mount") }
    for _, name := range []string{"Equal-", "Nonempty-", "Nonempty-/child.jpg"} {
        direct := listed(name)
        local, e := os.Lstat(filepath.Join(mount, folder, name))
        if e != nil { t.Fatal("Mounted control unavailable") }
        inode, ok := local.Sys().(*syscall.Stat_t)
        if !ok || inode.Ino == 0 { t.Fatal("Mounted control identity unavailable") }
        fmt.Printf("MOUNT_DIRECT_ID_COMPARISON name=%q equal=%t\n", name, uint64(inode.Ino) == direct.FileId)
    }

    // Existing open handle does not grant share-delete. A separate deletion
    // attempt must not circumvent this sharing restriction or retry blindly.
    held, e := share.Open(wire("Locked."))
    if e != nil { t.Fatal("Could not establish held file") }
    if e = removeDuplicate("Locked.", "Locked-", []byte("locked-bytes"), false); e == nil {
        held.Close()
        t.Fatal("Open file sharing restriction bypassed")
    }
    if e = held.Close(); e != nil { t.Fatal("Held file close failed") }
    checkBytes("Locked.", "locked-bytes")
    checkBytes("Locked-", "locked-bytes")
    fmt.Println("OPEN_FILE_PRESERVED")

    correctedID := listed("Equal-").FileId
    if e := removeDuplicate("Equal.", "Equal-", []byte("equal-bytes"), false); e != nil {
        t.Fatal("Exact verified file deletion failed")
    }
    absent("Equal.")
    checkBytes("Equal-", "equal-bytes")
    if listed("Equal-").FileId != correctedID { t.Fatal("Corrected identity changed") }
    fmt.Println("EXACT_DUPLICATE_REMOVED_CORRECTED_PRESERVED")

    if e := removeDuplicate("Different.", "Different-", []byte("new-bytes"), false); e == nil {
        t.Fatal("Different-content deletion accepted")
    }
    checkBytes("Different.", "old-bytes")
    checkBytes("Different-", "new-bytes")
    fmt.Println("DIFFERENT_CONTENT_PRESERVED")

    if e := removeDuplicate("Wrong.", "Wrong-", []byte("same"), true); e == nil {
        t.Fatal("Wrong identity accepted")
    }
    checkBytes("Wrong.", "same")
    checkBytes("Wrong-", "same")
    fmt.Println("WRONG_IDENTITY_REJECTED")

    if e := removeDuplicate("Nonempty.", "Nonempty-", nil, false); e == nil {
        t.Fatal("Nonempty directory accepted")
    }
    checkBytes("Nonempty./child.jpg", "keep-child")
    checkBytes("Nonempty-/child.jpg", "keep-child")
    fmt.Println("NONEMPTY_DIRECTORY_PRESERVED")

    if e := removeDuplicate("Empty.", "Empty-", nil, false); e != nil {
        t.Fatal("Verified empty directory deletion failed")
    }
    absent("Empty.")
    if fi, e := os.Stat(filepath.Join(native, "Empty-")); e != nil || !fi.IsDir() {
        t.Fatal("Corrected empty directory lost")
    }
    fmt.Println("EMPTY_OLD_DIRECTORY_REMOVED")
}
