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

// MacSyncRenameRequest is sent to the bundled helper over stdin.
type MacSyncRenameRequest struct {
	Host, Port, Share, User, Domain, Password string
	OldPath, NewPath string
	FileID uint64
	CreatedSeconds, CreatedNanos int64
	Size int64
	ModifiedSeconds, ModifiedNanos int64
	IsDirectory bool
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
func MacSyncRename(ctx context.Context, request MacSyncRenameRequest) error {
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
	err = connection.smbShare.RenameNoReplace(oldPath, newPath, func(info os.FileInfo) error {
		stat, ok := info.Sys().(*smb2.FileStat)
		if !ok || stat.FileId != request.FileID ||
			info.Mode()&os.ModeSymlink != 0 || info.IsDir() != request.IsDirectory ||
			!stat.CreationTime.Equal(time.Unix(request.CreatedSeconds, request.CreatedNanos)) {
			return errors.New("source identity could not be confirmed")
		}
		if !request.IsDirectory && (info.Size() != request.Size ||
			!info.ModTime().Equal(time.Unix(request.ModifiedSeconds, request.ModifiedNanos))) {
			return errors.New("source metadata changed")
		}
		return nil
	})
	f.putConnection(&connection, err)
	return err
}
