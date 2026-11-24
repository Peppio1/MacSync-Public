package smb

import (
	"context"
	"errors"
	"os"
	"path"
	"strings"
	"time"

	smb2 "github.com/cloudsoda/go-smb2"
	"github.com/rclone/rclone/fs/config/configmap"
	"github.com/rclone/rclone/fs/config/obscure"
)

// A disagreement in the modification timestamp can be transient immediately
// after a macOS smbfs write. This sentinel is returned ONLY by validation
// against the opened source handle, before issuing SMB SET_INFO. It must not
// be used to retry a rename after an ambiguous server/transport response.
var errMacSyncSourceMtimeNotReady = errors.New("source modification timestamp not yet confirmed")

// Report only definite pre-mutation errors separately. Any failure after
// passing the protected handle validation remains ambiguous, even if the
// server might have rejected SET_INFO.
var ErrMacSyncRenameNotAttempted = errors.New("rename not attempted")

// MacSyncRenameRequest is sent to the bundled helper over stdin.
type MacSyncRenameRequest struct {
	Host, Port, Share, User, Domain, Password string
	OldPath, NewPath string
	FileID uint64
	CreatedSeconds, CreatedNanos int64
	Size int64
	ModifiedSeconds, ModifiedNanos int64
	IsDirectory bool
	VerifyOnly bool
}

func validMacSyncRelativePath(p string) bool {
	if p == "" || strings.ContainsAny(p, "\\\x00") {
		return false
	}
	for _, component := range strings.Split(p, "/") {
		if component == "" || component == "." || component == ".." {
			return false
		}
	}
	return true
}

// MacSyncRename issues a single checked SMB rename. It never calls the
// transfer layer, which is allowed to retry with a copy and delete.
func MacSyncRename(ctx context.Context, request MacSyncRenameRequest) (result error) {
	mutationPossible := false
	defer func() {
		if result != nil && !mutationPossible {
			result = ErrMacSyncRenameNotAttempted
		}
	}()
	if request.Host == "" || request.Port == "" || request.User == "" ||
		request.FileID == 0 || request.CreatedSeconds <= 0 ||
		!validMacSyncRelativePath(request.Share) || strings.Contains(request.Share, "/") ||
		!validMacSyncRelativePath(request.OldPath) || !validMacSyncRelativePath(request.NewPath) ||
		request.OldPath == request.NewPath || path.Dir(request.OldPath) != path.Dir(request.NewPath) {
		return os.ErrInvalid
	}
	password, err := obscure.Obscure(request.Password)
	if err != nil {
		return err
	}
	remote, err := NewFs(ctx, "macsync-rename", request.Share+"/", configmap.Simple{
		"host": request.Host, "port": request.Port, "user": request.User,
		"pass": password, "domain": request.Domain,
	})
	if err != nil {
		return err
	}
	f := remote.(*Fs)
	defer f.Shutdown(ctx)
	connection, err := f.getConnection(ctx, request.Share)
	if err != nil {
		return err
	}
	// The names are already taken from the mounted directory. Avoid rclone's
	// filename encoding, which would change a literal trailing space.
	oldPath := strings.ReplaceAll(request.OldPath, "/", "\\")
	newPath := strings.ReplaceAll(request.NewPath, "/", "\\")
	// Most items complete in a single request. Only a SOURCE mtime mismatch
	// is retried, because RenameNoReplace checks the same opened SMB handle
	// before mutation. Identity, creation time and size are NEVER relaxed.
	// No retries are permitted after an actual rename attempt or an ambiguous
	// transport/server result. Each attempt starts with a fresh protected
	// source handle; the server's no-overwrite rename remains authoritative.
	validateIdentity := func(info os.FileInfo) error {
		stat, ok := info.Sys().(*smb2.FileStat)
		if !ok || stat.FileId != request.FileID ||
			info.Mode()&os.ModeSymlink != 0 || info.IsDir() != request.IsDirectory ||
			!stat.CreationTime.Equal(time.Unix(request.CreatedSeconds, request.CreatedNanos)) {
			return errors.New("source identity could not be confirmed")
		}
		if !request.IsDirectory {
			if info.Size() != request.Size {
				return errors.New("source metadata changed")
			}
			if !info.ModTime().Equal(time.Unix(request.ModifiedSeconds, request.ModifiedNanos)) {
				return errMacSyncSourceMtimeNotReady
			}
		}
		return nil
	}
	// Compare exact server-side spellings, not a lookup that may accept an
	// alias or normalize a trailing space. Only this immediate parent is read.
	parentPath := path.Dir(request.OldPath)
	if parentPath == "." {
		parentPath = ""
	}
	serverParent := strings.ReplaceAll(parentPath, "/", "\\")
	confirmNames := func(renamed bool) (os.FileInfo, error) {
		entries, err := connection.smbShare.ReadDir(serverParent)
		if err != nil { return nil, err }
		var oldEntry, newEntry os.FileInfo
		for _, entry := range entries {
			if entry.Name() == path.Base(request.OldPath) {
				if oldEntry != nil { return nil, errors.New("duplicate old server name") }
				oldEntry = entry
			}
			if entry.Name() == path.Base(request.NewPath) {
				if newEntry != nil { return nil, errors.New("duplicate new server name") }
				newEntry = entry
			}
		}
		if renamed {
			if oldEntry != nil || newEntry == nil { return nil, errors.New("exact final server name not confirmed") }
			return newEntry, nil
		}
		if oldEntry == nil || newEntry != nil { return nil, errors.New("exact original server name not confirmed") }
		return oldEntry, nil
	}
	confirmRenamed := func() error {
		info, err := confirmNames(true)
		if err != nil { return err }
		// go-smb2 Lstat returns CREATE metadata with FileId unset.
		// QUERY_DIRECTORY FileIdBothDirectoryInformation supplies both
		// the exact name and persistent file ID in the same server record.
		// Do not weaken the identity, birth time, size or mtime checks.
		return validateIdentity(info)
	}
	if request.VerifyOnly {
		err = confirmRenamed()
		f.putConnection(&connection, err)
		return err
	}
	if _, err = confirmNames(false); err != nil {
		f.putConnection(&connection, err)
		return err
	}
	verify := func(info os.FileInfo) error {
		if err := validateIdentity(info); err != nil { return err }
		mutationPossible = true
		return nil
	}
	const maxMtimeChecks = 11
	for attempt := 0; attempt < maxMtimeChecks; attempt++ {
		if err = ctx.Err(); err != nil {
			break
		}
		err = connection.smbShare.RenameNoReplace(oldPath, newPath, verify)
		if !errors.Is(err, errMacSyncSourceMtimeNotReady) || attempt+1 == maxMtimeChecks {
			break
		}
		// Bound total observation to 2.5 seconds, cancel promptly, and never
		// wait for wrong identity, a collision, an authorization error or
		// an indeterminate outcome.
		select {
		case <-ctx.Done():
			err = ctx.Err()
			break
		case <-time.After(250 * time.Millisecond):
		}
		if ctx.Err() != nil {
			err = ctx.Err()
			break
		}
	}
	if err == nil {
		// A successful SET_INFO is not enough: prove exact final spelling and
		// the same identity using independent read-only SMB queries.
		err = confirmRenamed()
	}
	f.putConnection(&connection, err)
	return err
}
