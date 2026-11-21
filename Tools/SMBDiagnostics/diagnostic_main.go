//go:build macsync_ci

// Test-only version of the helper entrypoint. It calls the identical
// production MacSyncRename function, but reports only an enumerated failure
// class. It is never included in a released MacSync bundle.
package main

import (
    "context"
    "encoding/json"
    "errors"
    "fmt"
    "io"
    "os"
    "strings"
    "time"

    "github.com/rclone/rclone/backend/smb"
)

func category(err error) string {
    message := strings.ToLower(err.Error())
    switch {
    case strings.Contains(message, "source identity could not be confirmed"):
        return "source-identity"
    case strings.Contains(message, "source metadata changed"):
        return "source-metadata"
    case errors.Is(err, os.ErrExist), strings.Contains(message, "object_name_collision"):
        return "destination-exists"
    case errors.Is(err, os.ErrPermission), strings.Contains(message, "access_denied"):
        return "access-denied"
    case errors.Is(err, os.ErrNotExist), strings.Contains(message, "object_name_not_found"):
        return "source-not-found"
    case errors.Is(err, os.ErrInvalid):
        return "request-invalid"
    case strings.Contains(message, "not_supported"):
        return "not-supported"
    case strings.Contains(message, "rename"):
        return "rename-io"
    default:
        return "other"
    }
}

func main() {
    if len(os.Args) != 1 {
        os.Exit(2)
    }
    // Accept the same size limit, parser, timeout and request as production.
    data, err := io.ReadAll(io.LimitReader(os.Stdin, 65537))
    if err != nil || len(data) > 65536 {
        os.Exit(2)
    }
    var request smb.MacSyncRenameRequest
    if json.Unmarshal(data, &request) != nil {
        os.Exit(2)
    }
    ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
    defer cancel()
    err = smb.MacSyncRename(ctx, request)
    if err != nil {
        // Never print err.Error: SMB errors may contain user-visible paths.
        fmt.Fprintln(os.Stderr, "MACSYNC_SMB_HELPER_DIAGNOSTIC category="+category(err))
        os.Exit(1)
    }
    fmt.Fprintln(os.Stderr, "MACSYNC_SMB_HELPER_DIAGNOSTIC category=success")
}
