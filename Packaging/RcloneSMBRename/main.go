package main

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"time"

	"github.com/rclone/rclone/backend/smb"
)

func main() {
	if len(os.Args) != 1 {
		os.Exit(2)
	}
	const maxRequestSize = 65536
	data, err := io.ReadAll(io.LimitReader(os.Stdin, maxRequestSize+1))
	if err != nil || len(data) > maxRequestSize {
		os.Exit(2)
	}
	var request smb.MacSyncRenameRequest
	if json.Unmarshal(data, &request) != nil {
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	err = smb.MacSyncRename(ctx, request)
	cancel()
	if err != nil {
		// The parent handles this exit status without logging any input data.
		os.Exit(1)
	}
}
