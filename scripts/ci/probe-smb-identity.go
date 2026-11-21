package main

// Disposable test-only metadata reader. Reads a single synthetic object from
// localhost and compares server-side FileStat to macOS smbfs lstat. No rename,
// mutation, raw paths or credentials are written to stdout/stderr.
import (
    "context"
    "fmt"
    "os"
    "strings"
    "time"

    smb2 "github.com/cloudsoda/go-smb2"
)
func fail(phase string) {
    fmt.Fprintln(os.Stderr, "MacSync SMB metadata probe failed at "+phase)
    os.Exit(1)
}
func main() {
    objectName := os.Getenv("MACSYNC_TEST_SMB_OBJECT")
    expectedFixture := objectName == "macsync-ci-metadata-probe.bin"
    // An integration test may inspect only its own synthetic helper fixture.
    helperFixture := strings.HasPrefix(objectName, "macsync-test-helper-success-") &&
        strings.Count(objectName, "/") == 1 && !strings.Contains(objectName, "..") &&
        (strings.HasSuffix(objectName, "/settled-new.jpg") ||
            strings.HasSuffix(objectName, "/settled-old.jpg"))
    if os.Getenv("MACSYNC_TEST_SMB_HOST") != "127.0.0.1" ||
       os.Getenv("MACSYNC_TEST_SMB_SHARE") != "MacSyncCI" ||
       (!expectedFixture && !helperFixture) {
        fail("fixture-validation")
    }
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    dialer := &smb2.Dialer{Initiator: &smb2.NTLMInitiator{
        User: os.Getenv("MACSYNC_TEST_SMB_USER"),
        Password: os.Getenv("MACSYNC_TEST_SMB_PASSWORD"),
    }}
    session, err := dialer.Dial(ctx, "127.0.0.1:445")
    if err != nil { fail("authentication") }
    defer session.Logoff()
    share, err := session.Mount("MacSyncCI")
    if err != nil { fail("share") }
    defer share.Umount()
    object, err := share.Open(objectName)
    if err != nil { fail("open") }
    defer object.Close()
    info, err := object.Stat()
    if err != nil { fail("stat") }
    server, ok := info.Sys().(*smb2.FileStat)
    if !ok { fail("file-stat-type") }
    // Nanosecond precision is essential: the production helper compares
    // time.Time.Equal, while audit fingerprints also track ctime.
    fmt.Printf("%d %d %d %d %d\n",
        server.FileId, server.CreationTime.UnixNano(), info.ModTime().UnixNano(),
        server.ChangeTime.UnixNano(), info.Size())
}
